import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Crypto

enum SFTPClientError: Error, CustomStringConvertible {
    case connectionFailed(String)
    case authenticationFailed(String)
    case subsystemOpenFailed(String)
    case requestFailed(UInt32, String)
    case notConnected
    case invalidResponse
    case channelClosed
    case timeout(String)

    var description: String {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .authenticationFailed(let msg): return "Authentication failed: \(msg)"
        case .subsystemOpenFailed(let msg): return "SFTP subsystem open failed: \(msg)"
        case .requestFailed(let code, let msg): return "Request failed (\(code)): \(msg)"
        case .notConnected: return "Not connected"
        case .invalidResponse: return "Invalid response from server"
        case .channelClosed: return "Connection closed"
        case .timeout(let msg): return "Timeout: \(msg)"
        }
    }
}

struct SFTPCredentials {
    let username: String
    let password: String?
    let privateKeyPath: String?
    let keyPassphrase: String?
}

actor SFTPClient {
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var sshChannel: Channel?
    private var sftpChannel: Channel?
    private var protocol_: SFTPProtocol
    private nonisolated(unsafe) var isConnectedFlag = false

    private(set) var currentPath: String = "/"

    private var pendingRequests: [UInt32: CheckedContinuation<SFTPResponse, Error>] = [:]
    private let requestLock = NSLock()
    
    var operationTimeout: TimeAmount = .seconds(30)

    init() {
        self.protocol_ = SFTPProtocol()
    }

    deinit {
        if let group = eventLoopGroup {
            try? group.syncShutdownGracefully()
        }
    }

    nonisolated var isConnected: Bool {
        isConnectedFlag
    }

    func connect(host: String, port: Int, credentials: SFTPCredentials) async throws {
        guard !isConnectedFlag else { return }

        print("[SFTPClient] Connecting to \(host):\(port) with user '\(credentials.username)'")

        eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)

        guard let group = eventLoopGroup else {
            throw SFTPClientError.connectionFailed("Failed to create event loop group")
        }

        let userAuthDelegate = SSHUserAuthDelegate(credentials: credentials)
        let serverAuthDelegate = AcceptAllHostKeysDelegate()

        do {
            let bootstrap = ClientBootstrap(group: group)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { [self] channel in
                    let loggingHandler = LoggingChannelHandler()
                    return channel.pipeline.addHandlers([
                        loggingHandler,
                        NIOSSHHandler(
                            role: .client(.init(
                                userAuthDelegate: userAuthDelegate,
                                serverAuthDelegate: serverAuthDelegate
                            )),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: { childChannel, _ in
                                childChannel.pipeline.addHandler(
                                    SFTPChannelHandler(client: self, protocol_: self.protocol_)
                                )
                            }
                        )
                    ])
                }
                .connectTimeout(.seconds(30))

            let connectedChannel = try await bootstrap.connect(host: host, port: port).get()
            print("[SFTPClient] TCP connection established")
            self.sshChannel = connectedChannel

            try await openSFTPSubsystem(channel: connectedChannel)
            print("[SFTPClient] SFTP subsystem opened")

            isConnectedFlag = true
            currentPath = "/"
            print("[SFTPClient] Connected successfully")
        } catch {
            print("[SFTPClient] Connection failed: \(error)")
            _ = try? await eventLoopGroup?.shutdownGracefully()
            eventLoopGroup = nil
            throw SFTPClientError.connectionFailed(error.localizedDescription)
        }
    }

    private func openSFTPSubsystem(channel: Channel) async throws {
        let sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        
        let subsystemChannel = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Channel, Error>) in
            let promise = channel.eventLoop.makePromise(of: Channel.self)
            
            sshHandler.createChannel(promise) { childChannel, channelType in
                let future = childChannel.pipeline.addHandler(SFTPChannelHandler(client: self, protocol_: self.protocol_))
                return future
            }
            
            promise.futureResult.whenComplete { result in
                switch result {
                case .success(let ch):
                    continuation.resume(returning: ch)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
        
        self.sftpChannel = subsystemChannel
    }

    func disconnect() async throws {
        guard isConnectedFlag else { return }

        if let channel = sftpChannel {
            try await channel.close().get()
        }
        
        if let channel = sshChannel {
            try await channel.close().get()
        }
        
        _ = try await eventLoopGroup?.shutdownGracefully()
        
        sshChannel = nil
        sftpChannel = nil
        eventLoopGroup = nil
        isConnectedFlag = false
        currentPath = "/"
    }

    func listDirectory(path: String, timeout: TimeAmount? = nil) async throws -> [RemoteFile] {
        guard isConnectedFlag else {
            throw SFTPClientError.notConnected
        }

        let absolutePath = resolvePath(path)
        
        let handle = try await openDirectory(path: absolutePath, timeout: timeout)
        defer { Task { try? await closeHandle(handle) } }

        var files: [RemoteFile] = []

        while true {
            let entries = try await readDirectory(handle: handle, timeout: timeout)
            if entries.isEmpty { break }

            for entry in entries {
                guard entry.filename != "." && entry.filename != ".." else { continue }

                let filePath = absolutePath.hasSuffix("/") 
                    ? absolutePath + entry.filename 
                    : absolutePath + "/" + entry.filename

                files.append(RemoteFile(
                    name: entry.filename,
                    path: filePath,
                    isDirectory: entry.isDirectory,
                    size: entry.attributes.size.map { Int64($0) } ?? 0,
                    modificationDate: entry.attributes.modifyTime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    permissions: formatPermissions(entry.attributes.permissions)
                ))
            }
        }

        return files.sorted { file1, file2 in
            if file1.isDirectory != file2.isDirectory {
                return file1.isDirectory
            }
            return file1.name.localizedCaseInsensitiveCompare(file2.name) == .orderedAscending
        }
    }

    func changeDirectory(to path: String) async throws {
        guard isConnectedFlag else {
            throw SFTPClientError.notConnected
        }

        let absolutePath = resolvePath(path)
        currentPath = absolutePath
    }

    func currentDirectory() -> String {
        currentPath
    }

    func downloadToFile(remotePath: String, localURL: URL, progress: ((UInt64, UInt64?) -> Void)? = nil) async throws {
        guard isConnectedFlag else {
            throw SFTPClientError.notConnected
        }

        let absolutePath = resolvePath(remotePath)
        
        let handle = try await openFile(path: absolutePath, flags: 0x00000001)
        defer { Task { try? await closeHandle(handle) } }

        let stat = try await fstatHandle(handle)
        let totalSize = stat.size

        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: localURL)
        defer { try? fileHandle.close() }

        var offset: UInt64 = 0
        let chunkSize: UInt32 = 32768

        while true {
            let data = try await readFromHandle(handle: handle, offset: offset, length: chunkSize)

            if data.readableBytes == 0 {
                break
            }

            if let bytes = data.getBytes(at: 0, length: data.readableBytes) {
                try fileHandle.write(contentsOf: bytes)
            }

            offset += UInt64(data.readableBytes)
            progress?(offset, totalSize)
        }
    }

    private func resolvePath(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        if path == "." { return currentPath }
        if path == ".." { 
            if currentPath == "/" { return "/" }
            return (currentPath as NSString).deletingLastPathComponent
        }
        
        if currentPath.hasSuffix("/") {
            return currentPath + path
        }
        return currentPath + "/" + path
    }

    private func sendRequest(_ request: SFTPRequest) async throws -> SFTPResponse {
        guard let channel = sftpChannel else {
            throw SFTPClientError.notConnected
        }

        print("[SFTPClient] Sending \(request.type) request (id: \(request.id))")
        
        let buffer = try protocol_.encodeRequest(request)
        print("[SFTPClient] Encoded \(buffer.readableBytes) bytes")
        
        return try await withCheckedThrowingContinuation { continuation in
            requestLock.lock()
            pendingRequests[request.id] = continuation
            requestLock.unlock()
            
            var mutableBuffer = buffer
            channel.writeAndFlush(mutableBuffer).whenFailure { error in
                self.requestLock.lock()
                self.pendingRequests.removeValue(forKey: request.id)
                self.requestLock.unlock()
                print("[SFTPClient] Write failed: \(error)")
                continuation.resume(throwing: error)
            }
        }
    }
    
    private func sendRequestWithTimeout(_ request: SFTPRequest, timeout: TimeAmount? = nil) async throws -> SFTPResponse {
        let effectiveTimeout = timeout ?? operationTimeout
        
        let requestId = request.id
        let buffer: ByteBuffer
        do {
            buffer = try protocol_.encodeRequest(request)
        } catch {
            throw SFTPClientError.requestFailed(UInt32.max, error.localizedDescription)
        }
        
        guard let channel = sftpChannel else {
            throw SFTPClientError.notConnected
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            requestLock.lock()
            pendingRequests[requestId] = continuation
            requestLock.unlock()
            
            var mutableBuffer = buffer
            channel.writeAndFlush(mutableBuffer).whenFailure { [self] error in
                self.requestLock.lock()
                self.pendingRequests.removeValue(forKey: requestId)
                self.requestLock.unlock()
                print("[SFTPClient] Write failed: \(error)")
                continuation.resume(throwing: error)
            }
        }
    }

    func handleResponse(_ response: SFTPResponse, requestId: UInt32) {
        print("[SFTPClient] Received response for request \(requestId)")
        requestLock.lock()
        let continuation = pendingRequests.removeValue(forKey: requestId)
        requestLock.unlock()
        
        continuation?.resume(returning: response)
    }

    private func openFile(path: String, flags: UInt32, timeout: TimeAmount? = nil) async throws -> SFTPHandle {
        let request = SFTPOpenRequest(
            id: protocol_.nextId(),
            path: path,
            pflags: flags,
            attrs: .empty
        )

        let response = try await sendRequestWithTimeout(request, timeout: timeout)

        switch response {
        case .handle(_, let handle):
            return handle
        case .status(_, let code, let message, _):
            throw SFTPClientError.requestFailed(code, message)
        default:
            throw SFTPClientError.invalidResponse
        }
    }

    private func openDirectory(path: String, timeout: TimeAmount? = nil) async throws -> SFTPHandle {
        let request = SFTPOpendirRequest(
            id: protocol_.nextId(),
            path: path
        )

        let response = try await sendRequestWithTimeout(request, timeout: timeout)

        switch response {
        case .handle(_, let handle):
            return handle
        case .status(_, let code, let message, _):
            throw SFTPClientError.requestFailed(code, message)
        default:
            throw SFTPClientError.invalidResponse
        }
    }

    private func closeHandle(_ handle: SFTPHandle, timeout: TimeAmount? = nil) async throws {
        let request = SFTPCloseRequest(
            id: protocol_.nextId(),
            handle: handle
        )
        _ = try await sendRequestWithTimeout(request, timeout: timeout)
    }

    private func readFromHandle(handle: SFTPHandle, offset: UInt64, length: UInt32, timeout: TimeAmount? = nil) async throws -> ByteBuffer {
        let request = SFTPReadRequest(
            id: protocol_.nextId(),
            handle: handle,
            offset: offset,
            length: length
        )

        let response = try await sendRequestWithTimeout(request, timeout: timeout)

        switch response {
        case .data(_, let data):
            return data
        case .status(_, let code, _, _) where code == 1:
            var empty = ByteBufferAllocator().buffer(capacity: 0)
            return empty
        case .status(_, let code, let message, _):
            throw SFTPClientError.requestFailed(code, message)
        default:
            throw SFTPClientError.invalidResponse
        }
    }

    private func writeToHandle(handle: SFTPHandle, offset: UInt64, data: ByteBuffer, timeout: TimeAmount? = nil) async throws {
        let request = SFTPWriteRequest(
            id: protocol_.nextId(),
            handle: handle,
            offset: offset,
            data: data
        )

        let response = try await sendRequestWithTimeout(request, timeout: timeout)

        if case .status(_, let code, let message, _) = response, code != 0 {
            throw SFTPClientError.requestFailed(code, message)
        }
    }

    private func readDirectory(handle: SFTPHandle, timeout: TimeAmount? = nil) async throws -> [SFTPDirectoryEntry] {
        let request = SFTPReaddirRequest(
            id: protocol_.nextId(),
            handle: handle
        )

        let response = try await sendRequestWithTimeout(request, timeout: timeout)

        switch response {
        case .name(_, let entries, _):
            return entries
        case .status(_, let code, _, _) where code == 1:
            return []
        case .status(_, let code, let message, _):
            throw SFTPClientError.requestFailed(code, message)
        default:
            throw SFTPClientError.invalidResponse
        }
    }

    private func fstatHandle(_ handle: SFTPHandle, timeout: TimeAmount? = nil) async throws -> SFTPFileAttributes {
        let request = SFTPFstatRequest(
            id: protocol_.nextId(),
            handle: handle
        )

        let response = try await sendRequestWithTimeout(request, timeout: timeout)

        switch response {
        case .attrs(_, let attrs):
            return attrs
        case .status(_, let code, let message, _):
            throw SFTPClientError.requestFailed(code, message)
        default:
            throw SFTPClientError.invalidResponse
        }
    }

    private func formatPermissions(_ permissions: UInt32?) -> String {
        guard let perms = permissions else { return "----------" }
        
        var result = ""
        
        result += (perms & 0o40000 != 0) ? "d" : "-"
        result += (perms & 0o100 != 0) ? "r" : "-"
        result += (perms & 0o040 != 0) ? "w" : "-"
        result += (perms & 0o020 != 0) ? "x" : "-"
        result += (perms & 0o010 != 0) ? "r" : "-"
        result += (perms & 0o004 != 0) ? "w" : "-"
        result += (perms & 0o002 != 0) ? "x" : "-"
        result += (perms & 0o001 != 0) ? "r" : "-"
        result += (perms & 0o001 != 0) ? "w" : "-"
        result += (perms & 0o001 != 0) ? "x" : "-"
        
        return result
    }
}

struct SSHUserAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    let credentials: SFTPCredentials

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if let password = credentials.password, availableMethods.contains(.password) {
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                username: credentials.username,
                serviceName: "",
                offer: .password(.init(password: password))
            ))
        } else if let privateKeyPath = credentials.privateKeyPath,
                  let privateKeyData = try? Data(contentsOf: URL(fileURLWithPath: privateKeyPath)) {
            let passphrase = credentials.keyPassphrase
            if let privateKey = try? NIOSSHPrivateKey(ed25519Key: .init()) {
                nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                    username: credentials.username,
                    serviceName: "",
                    offer: .privateKey(.init(privateKey: privateKey))
                ))
            } else {
                nextChallengePromise.succeed(nil)
            }
        } else {
            nextChallengePromise.succeed(nil)
        }
    }
}

final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        validationCompletePromise.succeed(())
    }
}

final class SFTPChannelHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    
    private weak var client: SFTPClient?
    private let sftpProtocol: SFTPProtocol
    
    init(client: SFTPClient, protocol_: SFTPProtocol) {
        self.client = client
        self.sftpProtocol = protocol_
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        print("[SFTPChannelHandler] Received \(buffer.readableBytes) bytes")
        
        guard let client = client else { return }
        
        do {
            while buffer.readableBytes > 0 {
                if let (id, response) = try sftpProtocol.decodeResponse(&buffer) {
                    print("[SFTPChannelHandler] Decoded response for request \(id)")
                    Task {
                        await client.handleResponse(response, requestId: id)
                    }
                }
            }
        } catch {
            print("[SFTPChannelHandler] Error decoding response: \(error)")
        }
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("[SFTPChannelHandler] Error: \(error)")
        context.close(promise: nil)
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        print("[SFTPChannelHandler] Channel inactive")
    }
}

final class LoggingChannelHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let bytes = buffer.readableBytes
        print("[LoggingChannelHandler] IN: \(bytes) bytes")
        context.fireChannelRead(data)
    }
    
    func channelActive(context: ChannelHandlerContext) {
        print("[LoggingChannelHandler] Channel active")
        context.fireChannelActive()
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        print("[LoggingChannelHandler] Channel inactive")
        context.fireChannelInactive()
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("[LoggingChannelHandler] Error: \(error)")
        context.fireErrorCaught(error)
    }
}

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

    var description: String {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .authenticationFailed(let msg): return "Authentication failed: \(msg)"
        case .subsystemOpenFailed(let msg): return "SFTP subsystem open failed: \(msg)"
        case .requestFailed(let code, let msg): return "Request failed (\(code)): \(msg)"
        case .notConnected: return "Not connected"
        case .invalidResponse: return "Invalid response from server"
        case .channelClosed: return "Connection closed"
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
    private var isConnectedFlag = false

    private(set) var currentPath: String = "/"

    private var pendingRequests: [UInt32: CheckedContinuation<SFTPResponse, Error>] = [:]
    private let requestLock = NSLock()

    init() {
        self.protocol_ = SFTPProtocol()
    }

    deinit {
        if let group = eventLoopGroup {
            try? group.syncShutdownGracefully()
        }
    }

    var isConnected: Bool {
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
                .channelInitializer { channel in
                    channel.pipeline.addHandlers([
                        NIOSSHHandler(
                            role: .client(.init(
                                userAuthDelegate: userAuthDelegate,
                                serverAuthDelegate: serverAuthDelegate
                            )),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
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
            try? eventLoopGroup?.syncShutdownGracefully()
            eventLoopGroup = nil
            throw SFTPClientError.connectionFailed(error.localizedDescription)
        }
    }

    private func openSFTPSubsystem(channel: Channel) async throws {
        self.sftpChannel = channel
    }

    func disconnect() async throws {
        guard isConnectedFlag else { return }

        if let channel = sftpChannel {
            try await channel.close().get()
        }
        
        if let channel = sshChannel {
            try await channel.close().get()
        }
        
        try await eventLoopGroup?.syncShutdownGracefully()
        
        sshChannel = nil
        sftpChannel = nil
        eventLoopGroup = nil
        isConnectedFlag = false
        currentPath = "/"
    }

    func listDirectory(path: String) async throws -> [RemoteFile] {
        guard isConnectedFlag else {
            throw SFTPClientError.notConnected
        }

        let absolutePath = resolvePath(path)
        
        let handle = try await openDirectory(path: absolutePath)
        defer { Task { try? await closeHandle(handle) } }

        var files: [RemoteFile] = []

        while true {
            let entries = try await readDirectory(handle: handle)
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

    func upload(localURL: URL, remotePath: String, progress: ((UInt64, UInt64) -> Void)? = nil) async throws {
        guard isConnectedFlag else {
            throw SFTPClientError.notConnected
        }

        let data = try Data(contentsOf: localURL)
        let totalSize = UInt64(data.count)
        
        let absolutePath = resolvePath(remotePath)
        let handle = try await openFile(path: absolutePath, flags: 0x00000008 | 0x00000002)
        defer { Task { try? await closeHandle(handle) } }

        var offset: UInt64 = 0
        let chunkSize = 32768

        while offset < totalSize {
            let remaining = Int(totalSize - offset)
            let thisChunk = min(chunkSize, remaining)
            let chunk = data.subdata(in: Int(offset)..<(Int(offset) + thisChunk))

            var buffer = ByteBufferAllocator().buffer(capacity: chunk.count)
            buffer.writeBytes(chunk)

            try await writeToHandle(handle: handle, offset: offset, data: buffer)
            offset += UInt64(thisChunk)
            progress?(offset, totalSize)
        }
    }

    func createDirectory(named name: String) async throws {
        guard isConnectedFlag else {
            throw SFTPClientError.notConnected
        }

        let absolutePath = resolvePath(name)
        
        let request = SFTPMkdirRequest(
            id: protocol_.nextId(),
            path: absolutePath,
            attrs: .empty
        )
        _ = try await sendRequest(request)
    }

    func deleteFile(named name: String) async throws {
        guard isConnectedFlag else {
            throw SFTPClientError.notConnected
        }

        let absolutePath = resolvePath(name)
        
        let request = SFTPRemoveRequest(
            id: protocol_.nextId(),
            path: absolutePath
        )
        _ = try await sendRequest(request)
    }

    func deleteDirectory(named name: String) async throws {
        guard isConnectedFlag else {
            throw SFTPClientError.notConnected
        }

        let absolutePath = resolvePath(name)
        
        let request = SFTPRmdirRequest(
            id: protocol_.nextId(),
            path: absolutePath
        )
        _ = try await sendRequest(request)
    }

    func rename(from oldName: String, to newName: String) async throws {
        guard isConnectedFlag else {
            throw SFTPClientError.notConnected
        }

        let oldPath = resolvePath(oldName)
        let newPath = resolvePath(newName)
        
        let request = SFTPRenameRequest(
            id: protocol_.nextId(),
            oldPath: oldPath,
            newPath: newPath
        )
        _ = try await sendRequest(request)
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

    func handleResponse(_ response: SFTPResponse, requestId: UInt32) {
        print("[SFTPClient] Received response for request \(requestId)")
        requestLock.lock()
        let continuation = pendingRequests.removeValue(forKey: requestId)
        requestLock.unlock()
        
        continuation?.resume(returning: response)
    }

    private func openFile(path: String, flags: UInt32) async throws -> SFTPHandle {
        let request = SFTPOpenRequest(
            id: protocol_.nextId(),
            path: path,
            pflags: flags,
            attrs: .empty
        )

        let response = try await sendRequest(request)

        switch response {
        case .handle(_, let handle):
            return handle
        case .status(_, let code, let message, _):
            throw SFTPClientError.requestFailed(code, message)
        default:
            throw SFTPClientError.invalidResponse
        }
    }

    private func openDirectory(path: String) async throws -> SFTPHandle {
        let request = SFTPOpendirRequest(
            id: protocol_.nextId(),
            path: path
        )

        let response = try await sendRequest(request)

        switch response {
        case .handle(_, let handle):
            return handle
        case .status(_, let code, let message, _):
            throw SFTPClientError.requestFailed(code, message)
        default:
            throw SFTPClientError.invalidResponse
        }
    }

    private func closeHandle(_ handle: SFTPHandle) async throws {
        let request = SFTPCloseRequest(
            id: protocol_.nextId(),
            handle: handle
        )
        _ = try await sendRequest(request)
    }

    private func readFromHandle(handle: SFTPHandle, offset: UInt64, length: UInt32) async throws -> ByteBuffer {
        let request = SFTPReadRequest(
            id: protocol_.nextId(),
            handle: handle,
            offset: offset,
            length: length
        )

        let response = try await sendRequest(request)

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

    private func writeToHandle(handle: SFTPHandle, offset: UInt64, data: ByteBuffer) async throws {
        let request = SFTPWriteRequest(
            id: protocol_.nextId(),
            handle: handle,
            offset: offset,
            data: data
        )

        let response = try await sendRequest(request)

        if case .status(_, let code, let message, _) = response, code != 0 {
            throw SFTPClientError.requestFailed(code, message)
        }
    }

    private func readDirectory(handle: SFTPHandle) async throws -> [SFTPDirectoryEntry] {
        let request = SFTPReaddirRequest(
            id: protocol_.nextId(),
            handle: handle
        )

        let response = try await sendRequest(request)

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

    private func fstatHandle(_ handle: SFTPHandle) async throws -> SFTPFileAttributes {
        let request = SFTPFstatRequest(
            id: protocol_.nextId(),
            handle: handle
        )

        let response = try await sendRequest(request)

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

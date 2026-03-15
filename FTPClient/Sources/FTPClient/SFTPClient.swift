import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Crypto
import Logging

private let logger = Logger(label: "com.ftpclient.sftp")

public enum SFTPClientError: Error, CustomStringConvertible, Sendable {
    case connectionFailed(String)
    case authenticationFailed(String)
    case subsystemOpenFailed(String)
    case requestFailed(UInt32, String)
    case notConnected
    case invalidResponse
    case channelClosed
    case timeout(String)

    public var description: String {
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

public struct SFTPCredentials: Sendable {
    public let username: String
    public let password: String?
    public let privateKeyPath: String?
    public let keyPassphrase: String?

    public init(username: String, password: String?, privateKeyPath: String? = nil, keyPassphrase: String? = nil) {
        self.username = username
        self.password = password
        self.privateKeyPath = privateKeyPath
        self.keyPassphrase = keyPassphrase
    }
}

public actor SFTPClient {
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var sshChannel: Channel?
    private var sftpChannel: Channel?

    // nonisolated(unsafe) so it can be read from the nonisolated `isConnected` property
    // and written from actor-isolated methods without Swift 6 isolation errors.
    nonisolated(unsafe) private var isConnectedFlag = false

    // nonisolated(unsafe) so the SFTPChannelHandler (a non-actor Sendable class) can hold a
    // direct reference captured inside the channelInitializer closure without triggering actor
    // isolation violations.
    nonisolated(unsafe) var protocol_: SFTPProtocol = SFTPProtocol()

    private(set) var currentPath: String = "/"

    private var pendingRequests: [UInt32: CheckedContinuation<SFTPResponse, Error>] = [:]

    var operationTimeout: TimeAmount = .seconds(30)

    private var timeoutTask: Task<Void, Never>?

    public init() {}

    deinit {
        if let group = eventLoopGroup {
            try? group.syncShutdownGracefully()
        }
    }

    public nonisolated var isConnected: Bool {
        isConnectedFlag
    }

    // MARK: - Connection

    public func connect(host: String, port: Int, credentials: SFTPCredentials) async throws {
        guard !isConnectedFlag else { return }

        logger.info("Connecting to \(host):\(port) with user '\(credentials.username)'")

        eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)

        guard let group = eventLoopGroup else {
            throw SFTPClientError.connectionFailed("Failed to create event loop group")
        }

        let userAuthDelegate = SSHUserAuthDelegate(credentials: credentials)
        let serverAuthDelegate = AcceptAllHostKeysDelegate()

        do {
            let bootstrap = ClientBootstrap(group: group)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let sync = channel.pipeline.syncOperations
                        try sync.addHandler(
                            NIOSSHHandler(
                                role: .client(.init(
                                    userAuthDelegate: userAuthDelegate,
                                    serverAuthDelegate: serverAuthDelegate
                                )),
                                allocator: channel.allocator,
                                inboundChildChannelInitializer: nil
                            )
                        )
                        try sync.addHandler(SSHPipelineErrorHandler())
                    }
                }
                .connectTimeout(.seconds(30))

            let connectedChannel = try await bootstrap.connect(host: host, port: port).get()
            logger.info("TCP connection established")
            self.sshChannel = connectedChannel

            try await openSFTPSubsystem(channel: connectedChannel)
            logger.info("SFTP subsystem opened")

            isConnectedFlag = true
            currentPath = "/"
            logger.info("Connected successfully")
        } catch {
            logger.error("Connection failed: \(error)")
            _ = try? await eventLoopGroup?.shutdownGracefully()
            eventLoopGroup = nil
            throw SFTPClientError.connectionFailed(error.localizedDescription)
        }
    }

    private func openSFTPSubsystem(channel: Channel) async throws {
        logger.debug("Getting NIOSSHHandler from pipeline")
        let sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        logger.debug("Got NIOSSHHandler, creating child channel")

        // Snapshot protocol_ into a local so the closure doesn't capture actor-isolated self.
        let proto = self.protocol_

        // createChannel is NOT thread-safe – it must be called on the channel's event loop.
        let subsystemChannel: Channel = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Channel, Error>) in
            channel.eventLoop.execute {
                let promise = channel.eventLoop.makePromise(of: Channel.self)

                sshHandler.createChannel(promise) { childChannel, _ in
                    logger.debug("Child channel initializer called")
                    return childChannel.pipeline.addHandler(SFTPChannelHandler(client: self, protocol_: proto))
                }

                promise.futureResult.whenComplete { result in
                    switch result {
                    case .success(let ch):
                        logger.debug("Child channel created successfully")
                        continuation.resume(returning: ch)
                    case .failure(let error):
                        logger.error("Child channel creation failed: \(error)")
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        logger.debug("Sending subsystem request for 'sftp'")
        // Send the SSH subsystem request so the server activates its SFTP subsystem.
        let subsystemRequest = SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true)
        try await subsystemChannel.triggerUserOutboundEvent(subsystemRequest).get()
        logger.debug("Subsystem request accepted")

        self.sftpChannel = subsystemChannel

        // Perform the SFTP protocol handshake (SSH_FXP_INIT / SSH_FXP_VERSION).
        let initRequest = SFTPInitRequest(id: 0)
        let buffer = try protocol_.encodeRequest(initRequest)

        let versionResponse: SFTPResponse = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SFTPResponse, Error>) in
            pendingRequests[0] = continuation

            // Wrap the ByteBuffer in SSHChannelData before writing.
            let sshData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            subsystemChannel.writeAndFlush(sshData).whenComplete { result in
                switch result {
                case .success:
                    break
                case .failure(let error):
                    // Dispatch to actor to safely mutate pendingRequests.
                    Task { [weak self] in
                        await self?.removePendingRequest(id: 0, resumingWith: .failure(error))
                    }
                }
            }
        }

        if case .version(let version, _) = versionResponse {
            guard version == 3 else {
                throw SFTPClientError.subsystemOpenFailed("Unsupported SFTP version: \(version)")
            }
            logger.info("SFTP version \(version) negotiated")
        } else {
            throw SFTPClientError.subsystemOpenFailed("Invalid version response")
        }
    }

    public func disconnect() async throws {
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

    // MARK: - Public API

    public func listDirectory(path: String, timeout: TimeAmount? = nil) async throws -> [RemoteFile] {
        guard isConnectedFlag else {
            throw SFTPClientError.notConnected
        }

        let absolutePath = resolvePath(path)

        let handle = try await openDirectory(path: absolutePath, timeout: timeout)

        var files: [RemoteFile] = []

        do {
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
        }

        try? await closeHandle(handle)

        return files.sorted { file1, file2 in
            if file1.isDirectory != file2.isDirectory {
                return file1.isDirectory
            }
            return file1.name.localizedCaseInsensitiveCompare(file2.name) == .orderedAscending
        }
    }

    public func changeDirectory(to path: String) async throws {
        guard isConnectedFlag else {
            throw SFTPClientError.notConnected
        }

        let absolutePath = resolvePath(path)

        let attrs = try await stat(path: absolutePath)
        guard attrs.isDirectory else {
            throw SFTPClientError.requestFailed(UInt32.max, "Not a directory: \(path)")
        }

        currentPath = absolutePath
    }

    public func currentDirectory() -> String {
        currentPath
    }

    public func downloadToFile(remotePath: String, localURL: URL, progress: ((UInt64, UInt64?) -> Void)? = nil) async throws {
        guard isConnectedFlag else {
            throw SFTPClientError.notConnected
        }

        let absolutePath = resolvePath(remotePath)

        let handle = try await openFile(path: absolutePath, flags: 0x00000001)

        let fileAttrs = try await fstatHandle(handle)
        let totalSize = fileAttrs.size

        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: localURL)

        do {
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

            try fileHandle.close()
        }

        try? await closeHandle(handle)
    }

    /// Read the entire contents of a remote file into `Data`.
    public func readFileData(remotePath: String) async throws -> Data {
        guard isConnectedFlag else {
            throw SFTPClientError.notConnected
        }

        let absolutePath = resolvePath(remotePath)
        let handle = try await openFile(path: absolutePath, flags: 0x00000001) // SSH_FXF_READ

        var result = Data()
        do {
            var offset: UInt64 = 0
            let chunkSize: UInt32 = 32768

            while true {
                let buffer = try await readFromHandle(handle: handle, offset: offset, length: chunkSize)
                if buffer.readableBytes == 0 { break }
                if let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes) {
                    result.append(contentsOf: bytes)
                }
                offset += UInt64(buffer.readableBytes)
            }
        }

        try? await closeHandle(handle)
        return result
    }

    // MARK: - Request dispatch

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

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SFTPResponse, Error>) in
            // Kick off a timeout that cancels the pending request if it hasn't been served.
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(effectiveTimeout.nanoseconds))
                await self?.timeoutIfPending(requestId: requestId, continuation: continuation)
            }

            self.pendingRequests[requestId] = continuation

            // Wrap the ByteBuffer in SSHChannelData for the NIO SSH layer.
            let sshData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            channel.writeAndFlush(sshData).whenComplete { result in
                switch result {
                case .success:
                    break
                case .failure(let error):
                    // Route back through the actor to safely mutate shared state.
                    Task { [weak self] in
                        await self?.cancelRequest(id: requestId, error: error)
                    }
                }
            }
        }
    }

    // MARK: - Actor-safe helpers called from non-isolated Task closures

    /// Called by the channel write failure handler to fail the pending request and tidy state.
    func cancelRequest(id: UInt32, error: Error) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        logger.error("Write failed: \(error)")
        continuation.resume(throwing: error)
    }

    /// Called by the timeout Task to fail the request if it is still outstanding.
    func timeoutIfPending(requestId: UInt32, continuation: CheckedContinuation<SFTPResponse, Error>) {
        guard pendingRequests[requestId] != nil else { return }
        pendingRequests.removeValue(forKey: requestId)
        continuation.resume(throwing: SFTPClientError.timeout("Request \(requestId) timed out"))
    }

    /// Called by the init-handshake write failure handler.
    func removePendingRequest(id: UInt32, resumingWith result: Result<SFTPResponse, Error>) {
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        switch result {
        case .success(let response): continuation.resume(returning: response)
        case .failure(let error):    continuation.resume(throwing: error)
        }
    }

    /// Called from SFTPChannelHandler (via a Task) when a complete response has been decoded.
    func handleResponse(_ response: SFTPResponse, requestId: UInt32) {
        logger.debug("Received response for request \(requestId)")
        timeoutTask?.cancel()
        timeoutTask = nil
        let continuation = pendingRequests.removeValue(forKey: requestId)
        continuation?.resume(returning: response)
    }

    // MARK: - SFTP operations

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
        // Status code 1 == SSH_FX_EOF
        case .status(_, let code, _, _) where code == 1:
            return ByteBufferAllocator().buffer(capacity: 0)
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
        // Status code 1 == SSH_FX_EOF (no more entries)
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

    private func stat(path: String, timeout: TimeAmount? = nil) async throws -> SFTPFileAttributes {
        let request = SFTPStatRequest(
            id: protocol_.nextId(),
            path: path
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

    // MARK: - Helpers

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

    private func formatPermissions(_ permissions: UInt32?) -> String {
        guard let perms = permissions else { return "----------" }

        var result = ""

        result += (perms & 0o40000 != 0) ? "d" : "-"
        result += (perms & 0o400 != 0) ? "r" : "-"
        result += (perms & 0o200 != 0) ? "w" : "-"
        result += (perms & 0o100 != 0) ? "x" : "-"
        result += (perms & 0o040 != 0) ? "r" : "-"
        result += (perms & 0o020 != 0) ? "w" : "-"
        result += (perms & 0o010 != 0) ? "x" : "-"
        result += (perms & 0o004 != 0) ? "r" : "-"
        result += (perms & 0o002 != 0) ? "w" : "-"
        result += (perms & 0o001 != 0) ? "x" : "-"

        return result
    }
}

// MARK: - SSH Authentication

struct SSHUserAuthDelegate: NIOSSHClientUserAuthenticationDelegate, Sendable {
    let credentials: SFTPCredentials

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        logger.debug("Auth callback: availableMethods=\(availableMethods), hasPassword=\(credentials.password != nil)")
        if let password = credentials.password, availableMethods.contains(.password) {
            logger.debug("Offering password auth for user '\(credentials.username)'")
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                username: credentials.username,
                serviceName: "",
                offer: .password(.init(password: password))
            ))
        } else if let privateKeyPath = credentials.privateKeyPath,
                  let privateKeyData = try? Data(contentsOf: URL(fileURLWithPath: privateKeyPath)) {
            if let privateKey = loadPrivateKey(from: privateKeyData) {
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

    private func loadPrivateKey(from data: Data) -> NIOSSHPrivateKey? {
        if let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return NIOSSHPrivateKey(ed25519Key: privateKey)
        }

        if let pemString = String(data: data, encoding: .utf8) {
            let lines = pemString.components(separatedBy: "\n")
            let base64Content = lines
                .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
                .joined()

            if let keyData = Data(base64Encoded: base64Content) {
                if let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) {
                    return NIOSSHPrivateKey(ed25519Key: privateKey)
                }
            }
        }

        return nil
    }
}

// MARK: - Host Key Verification

protocol SFTPHostKeyVerificationDelegate: AnyObject {
    func verifyHostKey(host: String, port: Int, fingerprint: String) -> Bool
}

extension NIOSSHPublicKey {
    var fingerprint: String {
        return "unknown"
    }
}

final class SFTPHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let host: String
    private let port: Int
    private weak var verificationDelegate: SFTPHostKeyVerificationDelegate?

    init(host: String, port: Int, verificationDelegate: SFTPHostKeyVerificationDelegate?) {
        self.host = host
        self.port = port
        self.verificationDelegate = verificationDelegate
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let fingerprint = hostKey.fingerprint

        let isValid: Bool
        if let delegate = verificationDelegate {
            isValid = delegate.verifyHostKey(host: host, port: port, fingerprint: fingerprint)
        } else {
            isValid = false
        }

        if isValid {
            validationCompletePromise.succeed(())
        } else {
            validationCompletePromise.fail(SFTPClientError.authenticationFailed("Host key verification failed for \(host):\(port)"))
        }
    }
}

final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate, Sendable {
    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        validationCompletePromise.succeed(())
    }
}

// MARK: - SFTP Channel Handler

/// NIO channel handler that sits in the SFTP child channel pipeline.
///
/// NIO SSH delivers inbound data as `SSHChannelData` and expects outbound data in the same form.
/// This handler unwraps/wraps the inner `ByteBuffer` so the rest of the code works with plain
/// byte buffers, and dispatches decoded SFTP responses back to the `SFTPClient` actor.
final class SFTPChannelHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    // NIO SSH child channels pass SSHChannelData, not raw ByteBuffer.
    typealias InboundIn = SSHChannelData
    // Write SSHChannelData back so NIO SSH can frame it correctly.
    typealias OutboundOut = SSHChannelData

    private weak var client: SFTPClient?
    private let sftpProtocol: SFTPProtocol

    init(client: SFTPClient, protocol_: SFTPProtocol) {
        self.client = client
        self.sftpProtocol = protocol_
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)

        // Only handle regular channel data; ignore extended data (e.g. stderr).
        guard case .byteBuffer(var buffer) = channelData.data else { return }

        logger.debug("Received \(buffer.readableBytes) bytes")

        guard let client = client else { return }

        do {
            while buffer.readableBytes > 0 {
                guard let (id, response) = try sftpProtocol.decodeResponse(&buffer) else {
                    break
                }
                logger.debug("Decoded response for request \(id)")
                Task {
                    await client.handleResponse(response, requestId: id)
                }
            }
        } catch {
            logger.error("Error decoding response: \(error)")
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Error: \(error)")
        context.close(promise: nil)
    }

    func channelActive(context: ChannelHandlerContext) {
        logger.debug("Channel active")
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        logger.debug("Channel inactive")
        context.fireChannelInactive()
    }
}

/// Logs errors from the SSH transport pipeline to help diagnose handshake failures.
final class SSHPipelineErrorHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("SSH pipeline error: \(error)")
        context.close(promise: nil)
    }
}

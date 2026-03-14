// FTPSClient.swift
//
// async/await FTPS client that uses FTPSBoringSSLHandler for both the control
// and data channels. The session extracted from the control channel TLS
// handshake is injected into the data channel handler before it connects,
// satisfying vsftpd's require_ssl_reuse=YES.

import Foundation
import NIOCore
import NIOPosix
import CNIOBoringSSL

// ---------------------------------------------------------------------------
// MARK: - Errors
// ---------------------------------------------------------------------------

public enum FTPSClientError: Error, CustomStringConvertible {
    case unexpectedResponse(code: Int, message: String)
    case pasvParseFailed(String)
    case connectionFailed(String)
    case notConnected

    public var description: String {
        switch self {
        case .unexpectedResponse(let c, let m): return "FTP \(c): \(m)"
        case .pasvParseFailed(let r):           return "PASV parse failed: \(r)"
        case .connectionFailed(let r):          return "Connection failed: \(r)"
        case .notConnected:                     return "Not connected"
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - FTP response
// ---------------------------------------------------------------------------

struct FTPResponse {
    let code: Int
    let lines: [String]

    var message: String { lines.joined(separator: "\n") }

    func expect(_ code: Int) throws {
        guard self.code == code else {
            throw FTPSClientError.unexpectedResponse(code: self.code, message: message)
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Line accumulator handler
// ---------------------------------------------------------------------------

/// Accumulates raw bytes into complete FTP response lines (terminated by \r\n)
/// and delivers them as `FTPResponse` objects up the pipeline.
final class FTPLineHandler: ChannelInboundHandler {
    typealias InboundIn  = ByteBuffer
    typealias InboundOut = FTPResponse

    private var buffer = ""

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        guard let bytes = buf.readString(length: buf.readableBytes) else { return }
        buffer += bytes

        while let range = buffer.range(of: "\r\n") {
            let line = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if let response = parseLine(line) {
                context.fireChannelRead(wrapInboundOut(response))
            }
        }
    }

    // FTP multi-line: "123-first line" ... "123 last line"
    private var pendingCode: Int?
    private var pendingLines: [String] = []

    private func parseLine(_ line: String) -> FTPResponse? {
        guard line.count >= 3,
              let code = Int(line.prefix(3)) else { return nil }

        if line.count > 3 && line[line.index(line.startIndex, offsetBy: 3)] == "-" {
            // Multi-line start
            pendingCode = code
            pendingLines = [String(line.dropFirst(4))]
            return nil
        } else {
            let text = line.count > 4 ? String(line.dropFirst(4)) : ""
            if let pc = pendingCode, pc == code {
                pendingLines.append(text)
                let resp = FTPResponse(code: pc, lines: pendingLines)
                pendingCode = nil
                pendingLines = []
                return resp
            } else {
                return FTPResponse(code: code, lines: [text])
            }
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Response awaiter handler
// ---------------------------------------------------------------------------

/// Bridges NIO's callback model to async/await by fulfilling one promise
/// per response received. The FTPSClient actor feeds promises in sequentially.
final class FTPResponseAwaiter: ChannelInboundHandler {
    typealias InboundIn = FTPResponse

    private var pending: CheckedContinuation<FTPResponse, Error>?

    func next() async throws -> FTPResponse {
        try await withCheckedThrowingContinuation { cont in
            assert(pending == nil, "Only one pending response at a time")
            pending = cont
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        let cont = pending
        pending = nil
        cont?.resume(returning: response)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let cont = pending
        pending = nil
        cont?.resume(throwing: error)
        context.fireErrorCaught(error)
    }
}

// ---------------------------------------------------------------------------
// MARK: - Data accumulator (for RETR)
// ---------------------------------------------------------------------------

/// Collects raw bytes from the data channel into a single ByteBuffer.
final class DataAccumulator: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private var continuation: CheckedContinuation<Data, Error>?
    private var accumulated = Data()

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        if let bytes = buf.readBytes(length: buf.readableBytes) {
            accumulated.append(contentsOf: bytes)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        let cont = continuation
        continuation = nil
        cont?.resume(returning: accumulated)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let cont = continuation
        continuation = nil
        cont?.resume(throwing: error)
    }
}

// ---------------------------------------------------------------------------
// MARK: - FTPSClient
// ---------------------------------------------------------------------------

public actor FTPSClient {

    private let host: String
    private let eventLoopGroup: MultiThreadedEventLoopGroup

    // Shared SSL_CTX* — using the SAME context for both channels is necessary
    // for BoringSSL's session cache to find the control session when the data
    // channel calls SSL_set_session.
    private let sslContext: OpaquePointer  // SSL_CTX*

    private var controlChannel: Channel?
    private var controlHandler: FTPSBoringSSLHandler?
    private var responseAwaiter: FTPResponseAwaiter?

    public init(host: String) throws {
        self.host = host
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.sslContext = try FTPSBoringSSLHandler.makeClientContext(hostname: host)
    }

    deinit {
        try? eventLoopGroup.syncShutdownGracefully()
        CNIOBoringSSL_SSL_CTX_free(sslContext)
    }

    // ------------------------------------------------------------------
    // MARK: Public API
    // ------------------------------------------------------------------

    /// Connect, perform AUTH TLS, log in, and set up data channel protection.
    public func connect(user: String, password: String) async throws {
        print("[FTPSClient] Connecting to \(host)...")
        
        // 1. Plain TCP connect to port 21
        print("[FTPSClient] Opening TCP connection to port 21...")
        let channel = try await makeTCPChannel(port: 21)
        controlChannel = channel
        print("[FTPSClient] TCP connection established")

        let awaiter = FTPResponseAwaiter()
        responseAwaiter = awaiter

        let lineHandler = FTPLineHandler()
        try await channel.pipeline.addHandlers([lineHandler, awaiter]).get()

        // 2. Read greeting
        print("[FTPSClient] Waiting for greeting...")
        let greeting = try await awaiter.next()
        print("[FTPSClient] Received greeting: \(greeting.code) \(greeting.message)")
        try greeting.expect(220)

        // 3. Upgrade to TLS
        print("[FTPSClient] Sending AUTH TLS...")
        let authResp = try await sendCommand("AUTH TLS")
        print("[FTPSClient] AUTH TLS response: \(authResp.code) \(authResp.message)")
        try authResp.expect(234)

        // Insert the TLS handler into the pipeline after AUTH TLS is accepted.
        // From this point all control channel traffic is encrypted.
        let tlsHandler = FTPSBoringSSLHandler(context: sslContext)
        controlHandler = tlsHandler

        let handshakePromise = channel.eventLoop.makePromise(of: Void.self)
        tlsHandler.handshakePromise = handshakePromise

        // Insert before the line handler so decrypted bytes reach it
        print("[FTPSClient] Adding TLS handler to pipeline...")
        try await channel.pipeline.addHandler(
            tlsHandler,
            position: .before(lineHandler)
        ).get()

        // Wait for TLS handshake
        print("[FTPSClient] Waiting for TLS handshake...")
        try await handshakePromise.futureResult.get()
        print("[FTPSClient] TLS handshake complete")

        // 4. FTP login sequence over TLS
        print("[FTPSClient] Sending PBSZ 0...")
        let pbszResp = try await sendCommand("PBSZ 0")
        print("[FTPSClient] PBSZ response: \(pbszResp.code)")
        try pbszResp.expect(200)

        print("[FTPSClient] Sending PROT P...")
        let protResp = try await sendCommand("PROT P")
        print("[FTPSClient] PROT response: \(protResp.code)")
        try protResp.expect(200)

        print("[FTPSClient] Sending USER...")
        let userResp = try await sendCommand("USER \(user)")
        print("[FTPSClient] USER response: \(userResp.code)")
        if userResp.code == 331 {
            print("[FTPSClient] Sending PASS...")
            let passResp = try await sendCommand("PASS \(password)")
            print("[FTPSClient] PASS response: \(passResp.code)")
            try passResp.expect(230)
        } else {
            try userResp.expect(230)
        }
        
        print("[FTPSClient] Connected and authenticated successfully!")
    }

    /// Download a remote file, optionally resuming from `offset` bytes.
    ///
    /// This is where the session reuse magic happens:
    ///   1. Extract the control channel's TLS session.
    ///   2. Open the data channel with that session injected.
    ///   3. BoringSSL presents the session_id in its ClientHello.
    ///   4. vsftpd validates it matches the control channel → satisfied.
    public func download(
        remotePath: String,
        resumeFrom offset: UInt64 = 0
    ) async throws -> Data {
        // Extract the session BEFORE opening the data channel
        guard let tlsHandler = controlHandler else {
            throw FTPSClientError.notConnected
        }
        let sessionTicket = try tlsHandler.extractSession()

        // PASV — get data channel address and port
        let pasvResp = try await sendCommand("PASV")
        try pasvResp.expect(227)
        let (dataHost, dataPort) = try parsePASV(pasvResp.message)

        // Optional REST for resume
        if offset > 0 {
            let restResp = try await sendCommand("REST \(offset)")
            try restResp.expect(350)
        }

        // Open the data channel, injecting the control channel's TLS session.
        // FTPSBoringSSLHandler will call SSL_set_session before the handshake,
        // so BoringSSL includes the session_id in ClientHello.
        let dataChannel = try await makeDataChannel(
            host: dataHost,
            port: dataPort,
            resumingSession: sessionTicket
        )

        // Kick off the transfer
        let retrResp = try await sendCommand("RETR \(remotePath)")
        guard retrResp.code == 125 || retrResp.code == 150 else {
            throw FTPSClientError.unexpectedResponse(code: retrResp.code, message: retrResp.message)
        }

        // Collect data until the data channel closes
        let accumulator = dataChannel.pipeline.handler(type: DataAccumulator.self)
        let acc = try await accumulator.get()
        let fileData = try await acc.receive()

        // Wait for 226 Transfer complete
        let completeResp = try await (responseAwaiter?.next() ?? { throw FTPSClientError.notConnected }())
        try completeResp.expect(226)

        return fileData
    }

    public func quit() async throws {
        print("[FTPSClient] Sending QUIT...")
        _ = try? await sendCommand("QUIT")
        try await controlChannel?.close().get()
        controlChannel = nil
        print("[FTPSClient] Disconnected")
    }

    public func currentDirectory() async throws -> String {
        print("[FTPSClient] Sending PWD...")
        let resp = try await sendCommand("PWD")
        print("[FTPSClient] PWD response: \(resp.code) \(resp.message)")
        try resp.expect(257)
        return resp.message
    }

    public func changeDirectory(to path: String) async throws {
        print("[FTPSClient] Sending CWD \(path)...")
        let resp = try await sendCommand("CWD \(path)")
        print("[FTPSClient] CWD response: \(resp.code)")
        try resp.expect(250)
    }

    public func list(path: String = "") async throws -> [String] {
        print("[FTPSClient] Listing directory: \(path.isEmpty ? "current" : path)")
        guard let tlsHandler = controlHandler else {
            throw FTPSClientError.notConnected
        }
        let sessionTicket = try tlsHandler.extractSession()

        print("[FTPSClient] Sending PASV...")
        let pasvResp = try await sendCommand("PASV")
        print("[FTPSClient] PASV response: \(pasvResp.code)")
        try pasvResp.expect(227)
        let (dataHost, dataPort) = try parsePASV(pasvResp.message)
        print("[FTPSClient] Data channel: \(dataHost):\(dataPort)")

        print("[FTPSClient] Opening data channel and sending LIST...")
        let dataChannel = try await makeDataChannel(
            host: dataHost,
            port: dataPort,
            resumingSession: sessionTicket
        )
        print("[FTPSClient] Data channel connected")

        print("[FTPSClient] Sending LIST command...")
        _ = try await sendCommand("LIST \(path)", expectPreliminary: true)
        print("[FTPSClient] LIST command sent, waiting for data...")

        let accumulator = dataChannel.pipeline.handler(type: DataAccumulator.self)
        let acc = try await accumulator.get()
        let fileData = try await acc.receive()
        print("[FTPSClient] Received \(fileData.count) bytes")

        let completeResp = try await (responseAwaiter?.next() ?? { throw FTPSClientError.notConnected }())
        print("[FTPSClient] Transfer complete: \(completeResp.code)")
        try completeResp.expect(226)

        let lines = (String(data: fileData, encoding: .utf8) ?? "")
            .components(separatedBy: "\r\n")
            .filter { !$0.isEmpty }
        print("[FTPSClient] Listed \(lines.count) items")
        return lines
    }

    public func createDirectory(named name: String) async throws {
        let resp = try await sendCommand("MKD \(name)")
        try resp.expect(257)
    }

    public func deleteFile(named name: String) async throws {
        let resp = try await sendCommand("DELE \(name)")
        try resp.expect(250)
    }

    public func deleteDirectory(named name: String) async throws {
        let resp = try await sendCommand("RMD \(name)")
        try resp.expect(250)
    }

    public func rename(from oldName: String, to newName: String) async throws {
        let resp1 = try await sendCommand("RNFR \(oldName)")
        try resp1.expect(350)
        let resp2 = try await sendCommand("RNTO \(newName)")
        try resp2.expect(250)
    }

    public func upload(data: Data, remotePath: String) async throws {
        guard let tlsHandler = controlHandler else {
            throw FTPSClientError.notConnected
        }
        let sessionTicket = try tlsHandler.extractSession()

        let pasvResp = try await sendCommand("PASV")
        try pasvResp.expect(227)
        let (dataHost, dataPort) = try parsePASV(pasvResp.message)

        let dataChannel = try await makeUploadChannel(
            host: dataHost,
            port: dataPort,
            resumingSession: sessionTicket
        )

        _ = try await sendCommand("STOR \(remotePath)", expectPreliminary: true)

        var buf = dataChannel.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        try await dataChannel.writeAndFlush(buf).get()
        try await dataChannel.close().get()

        let completeResp = try await (responseAwaiter?.next() ?? { throw FTPSClientError.notConnected }())
        try completeResp.expect(226)
    }

    // ------------------------------------------------------------------
    // MARK: Internal helpers
    // ------------------------------------------------------------------

    @discardableResult
    private func sendCommand(_ cmd: String, expectPreliminary: Bool = false) async throws -> FTPResponse {
        guard let channel = controlChannel, let awaiter = responseAwaiter else {
            throw FTPSClientError.notConnected
        }
        var buf = channel.allocator.buffer(capacity: cmd.utf8.count + 2)
        buf.writeString(cmd + "\r\n")
        try await channel.writeAndFlush(buf).get()
        let response = try await awaiter.next()
        if expectPreliminary && response.code >= 100 && response.code < 200 {
            return response
        }
        return response
    }

    // ------------------------------------------------------------------
    // MARK: Channel bootstrap helpers
    // ------------------------------------------------------------------

    private func makeTCPChannel(port: Int) async throws -> Channel {
        try await ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .connect(host: host, port: port)
            .get()
    }

    private func makeDataChannel(
        host: String,
        port: Int,
        resumingSession: SSLSessionTicket
    ) async throws -> Channel {
        // NOTE: Session resumption is REQUIRED for this server (vsftpd with require_ssl_reuse=YES).
        // Do NOT try without session resumption - the server will reject the connection.
        // The data channel TLS handshake may hang if the server doesn't respond, but that's
        // a server configuration issue, not a client bug.
        
        print("[FTPSClient] makeDataChannel: connecting to \(host):\(port)")
        
        let dataHandler = FTPSBoringSSLHandler(
            context: sslContext,
            resuming: resumingSession
        )

        let handshakePromise = eventLoopGroup.next().makePromise(of: Void.self)
        dataHandler.handshakePromise = handshakePromise

        let accumulator = DataAccumulator()

        print("[FTPSClient] makeDataChannel: starting TCP connection...")
        let channel = try await ClientBootstrap(group: eventLoopGroup)
            .channelInitializer { ch in
                ch.pipeline.addHandlers([dataHandler, accumulator])
            }
            .connectTimeout(.seconds(10))
            .connect(host: host, port: port)
            .get()
        
        print("[FTPSClient] makeDataChannel: TCP connected, waiting for TLS handshake...")

        try await handshakePromise.futureResult.get()
        
        print("[FTPSClient] makeDataChannel: TLS handshake complete!")

        return channel
    }

    private func makeUploadChannel(
        host: String,
        port: Int,
        resumingSession: SSLSessionTicket
    ) async throws -> Channel {
        let dataHandler = FTPSBoringSSLHandler(
            context: sslContext,
            resuming: resumingSession
        )

        let handshakePromise = eventLoopGroup.next().makePromise(of: Void.self)
        dataHandler.handshakePromise = handshakePromise

        let channel = try await ClientBootstrap(group: eventLoopGroup)
            .channelInitializer { ch in
                ch.pipeline.addHandler(dataHandler)
            }
            .connect(host: host, port: port)
            .get()

        try await handshakePromise.futureResult.get()

        return channel
    }

    // ------------------------------------------------------------------
    // MARK: PASV response parser
    // ------------------------------------------------------------------

    // "227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)"
    private func parsePASV(_ message: String) throws -> (host: String, port: Int) {
        guard let openParen  = message.lastIndex(of: "("),
              let closeParen = message.lastIndex(of: ")") else {
            throw FTPSClientError.pasvParseFailed(message)
        }
        let inner = String(message[message.index(after: openParen)..<closeParen])
        let parts = inner.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 6 else {
            throw FTPSClientError.pasvParseFailed(message)
        }
        let host = parts[0...3].map(String.init).joined(separator: ".")
        let port = parts[4] * 256 + parts[5]
        return (host, port)
    }
}

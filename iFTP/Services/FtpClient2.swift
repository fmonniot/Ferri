//
//  FtpClient2.swift
//  iFTP
//
//  Created by François Monniot on 3/13/26.
//

/*
 Package.swift — required dependencies:

 .package(url: "https://github.com/apple/swift-nio.git",     from: "2.65.0"),
 .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),

 Target dependencies:
   .product(name: "NIOCore",  package: "swift-nio"),
   .product(name: "NIOPosix", package: "swift-nio"),
   .product(name: "NIOSSL",   package: "swift-nio-ssl"),
*/

import NIOCore
import NIOPosix
import NIOSSL
import Foundation
import CryptoKit

// MARK: - FTP Mode & Server Configuration

enum FTPMode {
    case plain        // port 21, no TLS
    case explicitTLS  // port 21, plain → AUTH TLS upgrade (FTPES)
}

struct FTPServerConfig {
    let host: String
    let port: UInt16
    let mode: FTPMode
    /// DER or PEM encoded. When set, used instead of TOFU for certificate trust.
    let pinnedCertificateData: Data?

    var usesTLS: Bool { mode != .plain }

    static func plain(host: String, port: UInt16 = 21) -> Self {
        Self(host: host, port: port, mode: .plain, pinnedCertificateData: nil)
    }

    static func explicitTLS(host: String, port: UInt16 = 21, pinnedCert: Data? = nil) -> Self {
        Self(host: host, port: port, mode: .explicitTLS, pinnedCertificateData: pinnedCert)
    }
}

// MARK: - FTP Response

struct FTPResponse {
    let code: Int
    let message: String
    var isError: Bool       { code >= 400 }
    var isPreliminary: Bool { code >= 100 && code < 200 }
}

// MARK: - FTP Errors

enum FTPError: Error, LocalizedError {
    case connectionFailed(String)
    case tlsUpgradeFailed(String)
    case tlsCertificateMismatch(stored: String, seen: String)
    case serverError(FTPResponse)
    case noResponse
    case invalidPASVResponse(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let m):          return "Connection failed: \(m)"
        case .tlsUpgradeFailed(let m):          return "TLS upgrade failed: \(m)"
        case .tlsCertificateMismatch(let s, _): return "Certificate fingerprint changed (was \(s)) — possible MITM"
        case .serverError(let r):               return "FTP \(r.code): \(r.message)"
        case .noResponse:                       return "No response from server"
        case .invalidPASVResponse(let m):       return "Could not parse PASV response: \(m)"
        case .cancelled:                        return "Operation cancelled"
        }
    }
}

// MARK: - Certificate Helpers (NIOSSLCertificate-aware)

private func sha256Fingerprint(of cert: NIOSSLCertificate) throws -> String {
    let der = try cert.toDERBytes()
    return SHA256.hash(data: Data(der))
        .map { String(format: "%02x", $0) }
        .joined(separator: ":")
}

private func loadNIOCertificate(from data: Data) -> NIOSSLCertificate? {
    if let c = try? NIOSSLCertificate(bytes: Array(data), format: .der) { return c }
    if let c = try? NIOSSLCertificate(bytes: Array(data), format: .pem) { return c }
    return nil
}

// MARK: - TLS Handler Factory
//
// Shared by both control and data channels so certificate policy is identical.
// certificateVerification = .none disables SwiftNIO's built-in chain check;
// our customVerificationCallback is the sole trust authority.

private func makeTLSHandler(
    serverHostname: String,
    config: FTPServerConfig,
    tofuStore: TOFUStore,
    onFirstUse: ((String) -> Void)?,
    externalTLSContext: NIOSSLContext? = nil
) throws -> NIOSSLClientHandler {
    let tlsConfig = TLSConfiguration.makeClientConfiguration()
    let sslContext: NIOSSLContext
    if let external = externalTLSContext {
        sslContext = external
    } else {
        sslContext = try NIOSSLContext(configuration: tlsConfig)
    }
    
    let pinnedData = config.pinnedCertificateData
    let host       = config.host
    let port       = config.port

    return try NIOSSLClientHandler(
        context: sslContext,
        serverHostname: serverHostname,
        customVerificationCallback: { certs, promise in
            guard let leaf = certs.first else {
                promise.succeed(.failed); return
            }
            do {
                let serverFP = try sha256Fingerprint(of: leaf)

                // 1 — Explicit pinned certificate (binary: match or hard reject)
                if let pinData = pinnedData, let pinCert = loadNIOCertificate(from: pinData) {
                    let pinFP = try sha256Fingerprint(of: pinCert)
                    if serverFP == pinFP {
                        print("✅ Pinned cert matched: \(serverFP)")
                        promise.succeed(.certificateVerified)
                    } else {
                        print("❌ Pinned cert MISMATCH\n  expected: \(pinFP)\n  received: \(serverFP)")
                        promise.succeed(.failed)
                    }
                    return
                }

                // 2 — TOFU (handles both valid and invalid/self-signed certs)
                switch tofuStore.evaluate(fingerprint: serverFP, host: host, port: port) {
                case .trusted:
                    print("✅ TOFU: fingerprint matches stored value")
                    promise.succeed(.certificateVerified)

                case .firstUse(let fp):
                    print("🔑 TOFU: first use — storing \(fp)")
                    onFirstUse?(fp)
                    promise.succeed(.certificateVerified)

                case .mismatch(let stored, let seen):
                    print("🚨 TOFU mismatch\n  stored: \(stored)\n  seen:   \(seen)")
                    promise.succeed(.failed)
                }
            } catch {
                print("Certificate verification threw: \(error)")
                promise.succeed(.failed)
            }
        }
    )
}

// MARK: - TCPConnection  (control channel)
//
// Key difference from the NWConnection version:
// upgradeTLS() injects NIOSSLClientHandler into the live pipeline,
// which is exactly what FTPES / AUTH TLS requires.

final class TCPConnection {
    private let config: FTPServerConfig
    private let tofuStore: TOFUStore
    private let group: MultiThreadedEventLoopGroup

    private var channel: (any Channel)?
    private var lineHandler: FTPLineHandler?
    private(set) var tlsContext: NIOSSLContext?

    var onTOFUFirstUse: ((String) -> Void)?

    init(config: FTPServerConfig, tofuStore: TOFUStore, group: MultiThreadedEventLoopGroup) {
        self.config    = config
        self.tofuStore = tofuStore
        self.group     = group
    }

    // MARK: Connect (plain or implicit TLS)

    func connectControl() async throws {
        let handler = FTPLineHandler()
        lineHandler = handler

        // Always start with plain connection - TLS upgrade happens separately for explicitTLS
        let addTLSAtBoot = false
        let onFirst = onTOFUFirstUse

        channel = try await ClientBootstrap(group: group)
            .channelInitializer { [config, tofuStore] channel in
                do {
                    var handlers: [any ChannelHandler] = [handler]
                    if addTLSAtBoot {
                        let ssl = try makeTLSHandler(
                            serverHostname: config.host,
                            config: config,
                            tofuStore: tofuStore,
                            onFirstUse: onFirst
                        )
                        handlers.insert(ssl, at: 0)
                    }
                    return channel.pipeline.addHandlers(handlers)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .connect(host: config.host, port: Int(config.port))
            .get()
    }

    // MARK: TLS Upgrade (FTPES)
    //
    // Inserts NIOSSLClientHandler at position .first so it wraps every
    // subsequent read and write on this already-open TCP socket.
    // This is the operation that was impossible with NWConnection.

    func upgradeTLS() async throws {
        guard let channel else { throw FTPError.connectionFailed("No active channel") }

        // Create and store TLS context for session reuse
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.certificateVerification = .none
        tlsContext = try NIOSSLContext(configuration: tlsConfig)

        let sslHandler = try makeTLSHandler(
            serverHostname: config.host,
            config: config,
            tofuStore: tofuStore,
            onFirstUse: onTOFUFirstUse,
            externalTLSContext: tlsContext
        )

        do {
            try await channel.pipeline.addHandler(sslHandler, position: .first).get()
        } catch {
            throw FTPError.tlsUpgradeFailed(error.localizedDescription)
        }
    }

    // MARK: Send / Receive

    func send(_ string: String) async throws {
        guard let channel else { throw FTPError.connectionFailed("Not connected") }
        var buf = channel.allocator.buffer(capacity: string.utf8.count)
        buf.writeString(string)
        try await channel.writeAndFlush(buf).get()
    }

    func nextLine() async throws -> String {
        guard let channel, let lineHandler else { throw FTPError.noResponse }
        return try await lineHandler.nextLine(eventLoop: channel.eventLoop)
    }

    func disconnect() async {
        try? await channel?.close().get()
        channel = nil
    }
}

// MARK: - FTPDataChannel  (data channel)
//
// Always a fresh TCP connection per transfer.
// Uses the same TLS factory so certificate policy is identical to the control channel.
// For FTPES with PROT P, the data channel connects directly with TLS (no upgrade needed
// since it's a new socket — the server accepts TLS immediately on the data port).

final class FTPDataChannel {
    private let config: FTPServerConfig
    private let tofuStore: TOFUStore
    private let group: MultiThreadedEventLoopGroup
    private let tlsContext: NIOSSLContext?

    private var channel: (any Channel)?
    private var streamHandler: FTPStreamHandler?

    var onTOFUFirstUse: ((String) -> Void)?

    init(config: FTPServerConfig, tofuStore: TOFUStore, group: MultiThreadedEventLoopGroup, tlsContext: NIOSSLContext? = nil) {
        self.config    = config
        self.tofuStore = tofuStore
        self.group     = group
        self.tlsContext = tlsContext
    }

    // MARK: Connect → returns an inbound stream (for download/listing)

    func connect(host: String, port: UInt16, sniHostname: String? = nil) async throws -> AsyncThrowingStream<Data, Error> {
        print("📂 FTPDataChannel: connecting to \(host):\(port)")
        let handler = FTPStreamHandler()
        streamHandler = handler

        // Inherit TLS mode from control channel config.
        let dataTLS = config.usesTLS
        let onFirst = onTOFUFirstUse
        let dataConfig = FTPServerConfig(
            host: host, port: port,
            mode: dataTLS ? .explicitTLS : .plain,
            pinnedCertificateData: config.pinnedCertificateData
        )

        // Capture tlsContext for session reuse
        let existingTLSContext = tlsContext

        print("📂 FTPDataChannel: creating bootstrap, TLS: \(dataTLS), session reuse: \(existingTLSContext != nil)")
        
        do {
            let sniHost = sniHostname ?? config.host
            let connectionFuture = ClientBootstrap(group: group)
                .channelInitializer { [tofuStore] channel in
                    do {
                        var handlers: [any ChannelHandler] = [handler]
                        if dataTLS {
                            let ssl = try makeTLSHandler(
                                serverHostname: sniHost,
                                config: dataConfig,
                                tofuStore: tofuStore,
                                onFirstUse: onFirst,
                                externalTLSContext: existingTLSContext
                            )
                            handlers.insert(ssl, at: 0)
                        }
                        return channel.pipeline.addHandlers(handlers)
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                .connectTimeout(.seconds(10))
                .connect(host: host, port: Int(port))
            
            channel = try await connectionFuture.get()
        } catch {
            print("📂 FTPDataChannel: connection failed with error: \(error)")
            throw error
        }
        
        print("📂 FTPDataChannel: channel created successfully!")

        return AsyncThrowingStream { continuation in
            handler.attach(continuation)
        }
    }

    // MARK: Send (for upload — writes data then closes its end of the connection)

    func send(_ data: Data) async throws {
        guard let channel else { throw FTPError.connectionFailed("Data channel not connected") }
        var buf = channel.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        try await channel.writeAndFlush(buf).get()
    }

    func disconnect() async {
        try? await channel?.close().get()
        channel = nil
    }
}

// MARK: - FTPClient  (actor)
//
// Public API is identical to the previous NWConnection version.
// Internally, FTPES now works end-to-end.

actor FTPClientActor {

    private let config: FTPServerConfig
    private let tofuStore = TOFUStore()
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    private var controlChannel: TCPConnection!
    private var dataChannel: FTPDataChannel?
    private var tlsContext: NIOSSLContext?

    /// Called (on an unspecified thread) when a new server certificate is
    /// seen for the first time and stored via TOFU. Surface to the user as a
    /// non-blocking informational notice.
    var onTOFUFirstUse: ((String) -> Void)?

    init(config: FTPServerConfig) {
        self.config = config
    }

    deinit {
        try? group.syncShutdownGracefully()
    }

    // MARK: - Connection Lifecycle

    func connect() async throws {
        controlChannel = TCPConnection(config: config, tofuStore: tofuStore, group: group)
        controlChannel.onTOFUFirstUse = { [weak self] fp in
            Task { await self?.fireTOFUFirstUse(fp) }
        }

        try await controlChannel.connectControl()

        switch config.mode {
        case .plain:
            // Greeting arrives immediately after the TCP handshake
            let greeting = try await readResponse()
            print("← \(greeting.code) \(greeting.message)")

        case .explicitTLS:
            // 1. Read the plain-text greeting
            let greeting = try await readResponse()
            print("← \(greeting.code) \(greeting.message)")
            // 2. Negotiate TLS over the existing socket
            try await upgradeToExplicitTLS()
        }
    }

    func quit() async throws {
        try await sendCommand("QUIT")
        await controlChannel.disconnect()
    }

    // MARK: - FTPES Upgrade  (the new capability)

    private func upgradeToExplicitTLS() async throws {
        // Step 1: ask the server to prepare for TLS on this socket
        let authResp = try await sendCommand("AUTH TLS")
        guard authResp.code == 234 else { throw FTPError.serverError(authResp) }

        // Step 2: inject NIOSSLClientHandler into the live NIO pipeline
        try await controlChannel.upgradeTLS()
        print("🔒 TLS upgrade complete (FTPES)")

        // Step 3: declare buffer size (must be 0 for TLS) and enable encrypted data channel
        _ = try await sendCommand("PBSZ 0")  // Protection Buffer Size
        _ = try await sendCommand("PROT P")  // Protection Level: Private (TLS-encrypted data)
    }

    // MARK: - Authentication

    func login(user: String, password: String) async throws {
        let userResp = try await sendCommand("USER \(user)")
        guard userResp.code == 331 else { throw FTPError.serverError(userResp) }

        let passResp = try await sendCommand("PASS \(password)")
        guard passResp.code == 230 else { throw FTPError.serverError(passResp) }
    }

    // MARK: - Directory Operations

    func currentDirectory() async throws -> String {
        let r = try await sendCommand("PWD")
        guard r.code == 257 else { throw FTPError.serverError(r) }
        return r.message
    }

    func changeDirectory(to path: String) async throws {
        let r = try await sendCommand("CWD \(path)")
        guard r.code == 250 else { throw FTPError.serverError(r) }
    }

    func list(path: String = "") async throws -> [String] {
        print("📂 Opening data channel for LIST...")
        let (conn, stream) = try await openPassiveDataChannel()
        print("📂 Data channel opened, sending LIST command...")
        _ = try await sendCommand("LIST \(path)", expectPreliminary: true)
        
        print("📂 Waiting for data...")
        var buffer = Data()
        for try await chunk in stream { 
            print("📂 Received \(chunk.count) bytes")
            buffer.append(chunk) 
        }

        await conn.disconnect(); dataChannel = nil
        print("📂 Data channel closed")
        _ = try await readResponse() // 226 Transfer Complete

        return (String(data: buffer, encoding: .utf8) ?? "")
            .components(separatedBy: "\r\n")
            .filter { !$0.isEmpty }
    }

    // MARK: - File Transfer

    func download(remotePath: String) async throws -> Data {
        let (conn, stream) = try await openPassiveDataChannel()
        _ = try await sendCommand("RETR \(remotePath)", expectPreliminary: true)

        var buffer = Data()
        for try await chunk in stream { buffer.append(chunk) }

        await conn.disconnect(); dataChannel = nil
        _ = try await readResponse() // 226 Transfer Complete
        return buffer
    }

    func upload(data: Data, remotePath: String) async throws {
        let (conn, _) = try await openPassiveDataChannel()
        _ = try await sendCommand("STOR \(remotePath)", expectPreliminary: true)

        try await conn.send(data)
        await conn.disconnect(); dataChannel = nil
        _ = try await readResponse() // 226 Transfer Complete
    }

    // MARK: - Passive Mode

    private func openPassiveDataChannel() async throws -> (FTPDataChannel, AsyncThrowingStream<Data, Error>) {
        // Try EPSV first (Extended Passive Mode - returns only port)
        print("📂 Sending EPSV command...")
        var epsvResp = try? await sendCommand("EPSV")
        
        var host: String
        var port: UInt16
        
        if let resp = epsvResp, resp.code == 229 {
            // EPSV response: 229 Entering Extended Passive Mode (|||port|)
            if let parsedPort = parseEPSV(resp.message) {
                host = config.host
                port = parsedPort
                print("📂 EPSV response: \(host):\(port)")
            } else {
                throw FTPError.invalidPASVResponse(resp.message)
            }
        } else {
            // Fall back to PASV
            print("📂 Sending PASV command...")
            let resp = try await sendCommand("PASV")
            guard resp.code == 227 else { throw FTPError.serverError(resp) }
            let parsed = try parsePASV(resp.message)
            host = parsed.0
            port = parsed.1
            print("📂 PASV response: \(host):\(port)")
            
            // Use original hostname instead of NAT IP if different
            if host != config.host {
                print("📂 Using original hostname \(config.host) instead of PASV IP \(host)")
                host = config.host
            }
        }

        // Get TLS context from control channel for session reuse
        let tlsCtx = controlChannel.tlsContext

        let conn = FTPDataChannel(config: config, tofuStore: tofuStore, group: group, tlsContext: tlsCtx)
        conn.onTOFUFirstUse = { [weak self] fp in
            Task { await self?.fireTOFUFirstUse(fp) }
        }

        print("📂 Connecting to data channel...")
        let stream = try await conn.connect(host: host, port: port, sniHostname: config.host)
        print("📂 Data channel connected!")
        dataChannel = conn
        return (conn, stream)
    }
    
    private func parseEPSV(_ message: String) -> UInt16? {
        // EPSV response: 229 Entering Extended Passive Mode (|||port|)
        // or: 229 Entering Extended Passive Mode (|||port|)
        guard let openParen = message.firstIndex(of: "("),
              let closeParen = message.firstIndex(of: ")") else { return nil }
        
        let inner = String(message[message.index(after: openParen)..<closeParen])
        // Format: |||port| or |IP|port|
        
        let parts = inner.split(separator: "|").filter { !$0.isEmpty }
        if let lastPart = parts.last, let port = UInt16(lastPart) {
            return port
        }
        
        // Try alternative: find the last number in the string
        let numbers = inner.compactMap { String($0) }.joined().split(separator: "|").compactMap { UInt16($0) }
        return numbers.last
    }

    /// Parses `227 Entering Passive Mode (h1,h2,h3,h4,p1,p2).`
    private func parsePASV(_ message: String) throws -> (String, UInt16) {
        guard
            let open  = message.firstIndex(of: "("),
            let close = message.firstIndex(of: ")")
        else { throw FTPError.invalidPASVResponse(message) }

        let inner = String(message[message.index(after: open)..<close])
        let parts = inner.split(separator: ",").compactMap { UInt16($0) }
        guard parts.count == 6 else { throw FTPError.invalidPASVResponse(message) }

        return ("\(parts[0]).\(parts[1]).\(parts[2]).\(parts[3])", parts[4] * 256 + parts[5])
    }

    // MARK: - Command / Response Core

    @discardableResult
    func sendCommand(_ command: String, expectPreliminary: Bool = false) async throws -> FTPResponse {
        print("→ \(command)")
        try await controlChannel.send(command + "\r\n")
        let response = try await readResponse()
        if expectPreliminary && response.isPreliminary { return response }
        if response.isError { throw FTPError.serverError(response) }
        return response
    }

    /// Handles both single-line (`XYZ text`) and multi-line (`XYZ-...\r\nXYZ end`) responses.
    private func readResponse() async throws -> FTPResponse {
        let first = try await controlChannel.nextLine()
        guard first.count >= 3, let code = Int(first.prefix(3)) else {
            throw FTPError.noResponse
        }

        let fourthChar = first.count > 3 ? first[first.index(first.startIndex, offsetBy: 3)] : " "
        guard fourthChar == "-" else {
            // Single-line response
            let msg = first.count > 4 ? String(first.dropFirst(4)) : ""
            print("← \(code) \(msg)")
            return FTPResponse(code: code, message: msg)
        }

        // Multi-line: accumulate until we see "XYZ " (same code, space delimiter)
        var lines = [String(first.dropFirst(4))]
        while true {
            let line = try await controlChannel.nextLine()
            if line.count >= 4,
               let lc = Int(line.prefix(3)), lc == code,
               line[line.index(line.startIndex, offsetBy: 3)] == " " {
                lines.append(String(line.dropFirst(4)))
                break
            }
            lines.append(line)
        }

        let msg = lines.joined(separator: "\n")
        print("← \(code) \(msg)")
        return FTPResponse(code: code, message: msg)
    }

    // MARK: - Helpers

    private func fireTOFUFirstUse(_ fingerprint: String) {
        onTOFUFirstUse?(fingerprint)
    }
}

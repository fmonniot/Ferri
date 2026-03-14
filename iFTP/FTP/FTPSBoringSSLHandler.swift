// FTPSBoringSSLHandler.swift
//
// A custom NIO ChannelDuplexHandler that drives BoringSSL via memory BIOs.
// This gives us explicit access to SSL_get1_session / SSL_set_session, which
// is required to satisfy vsftpd's require_ssl_reuse=YES on the data channel.
//
// Architecture:
//   Network bytes arrive encrypted
//     → BIO_write(readBIO)       feed ciphertext into BoringSSL
//     → SSL_read / SSL_do_handshake  BoringSSL processes it
//     → BIO_read(writeBIO)       drain any outbound TLS records
//     → send down to network
//
//   App wants to send plaintext
//     → SSL_write(ssl, plaintext)   BoringSSL encrypts into writeBIO
//     → BIO_read(writeBIO)          drain ciphertext
//     → send down to network

import NIOCore
import CNIOBoringSSL  // from swift-nio-ssl's transitive dep

// ---------------------------------------------------------------------------
// MARK: - SSL_ERROR constants (BoringSSL doesn't re-export them as Swift symbols)
// ---------------------------------------------------------------------------

private let SSL_ERROR_NONE: Int32        = 0
private let SSL_ERROR_WANT_READ: Int32   = 2
private let SSL_ERROR_WANT_WRITE: Int32  = 3
private let SSL_ERROR_ZERO_RETURN: Int32 = 6

// ---------------------------------------------------------------------------
// MARK: - SSLSessionTicket
// ---------------------------------------------------------------------------

/// Reference-counted wrapper around a BoringSSL `SSL_SESSION*`.
///
/// Obtain one via `FTPSBoringSSLHandler.extractSession()` after the control
/// channel handshake completes. Pass it to the data channel handler's
/// initialiser to trigger session resumption.
public final class SSLSessionTicket: @unchecked Sendable {
    let session: OpaquePointer  // SSL_SESSION*

    /// Takes ownership of a +1 ref count (as returned by SSL_get1_session).
    init(owning session: OpaquePointer) {
        self.session = session
    }

    deinit {
        CNIOBoringSSL_SSL_SESSION_free(session)
    }
}

// ---------------------------------------------------------------------------
// MARK: - Errors
// ---------------------------------------------------------------------------

public enum FTPSBoringSSLError: Error, CustomStringConvertible {
    case handshakeFailed(sslError: Int32)
    case writeFailed(sslError: Int32)
    case sessionUnavailable
    case alreadyClosed

    public var description: String {
        switch self {
        case .handshakeFailed(let e): return "TLS handshake failed (SSL error \(e))"
        case .writeFailed(let e):     return "TLS write failed (SSL error \(e))"
        case .sessionUnavailable:     return "Session not yet established"
        case .alreadyClosed:          return "Connection already closed"
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - FTPSBoringSSLHandler
// ---------------------------------------------------------------------------

/// NIO channel handler that wraps BoringSSL using memory BIOs.
///
/// Usage (control channel):
///
///     let ctx = try FTPSBoringSSLHandler.makeClientContext(hostname: "ftp.example.com")
///     let handler = FTPSBoringSSLHandler(context: ctx)
///     // ... add to pipeline, wait for handshakeCompleted future ...
///     let ticket = try handler.extractSession()   // ← grab session
///
/// Usage (data channel):
///
///     let dataHandler = FTPSBoringSSLHandler(context: ctx, resuming: ticket)
///     // ... add to pipeline ...
///     // BoringSSL sends ClientHello with session_id → vsftpd resumes it
///
public final class FTPSBoringSSLHandler: ChannelDuplexHandler, @unchecked Sendable {

    public typealias InboundIn   = ByteBuffer
    public typealias InboundOut  = ByteBuffer
    public typealias OutboundIn  = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    // ------------------------------------------------------------------
    // Internal state
    // ------------------------------------------------------------------

    private var ssl: OpaquePointer!      // SSL*
    private var readBIO: UnsafeMutablePointer<BIO>!  // BoringSSL reads ciphertext FROM here
    private var writeBIO: UnsafeMutablePointer<BIO>! // BoringSSL writes ciphertext INTO here

    private var state: State = .idle
    private let sessionToResume: SSLSessionTicket?

    // Fulfilled once the TLS handshake succeeds; failed on error.
    // The FTPSClient actor awaits this before sending FTP commands.
    var handshakePromise: EventLoopPromise<Void>?

    private enum State {
        case idle, handshaking, active, closed
    }

    // ------------------------------------------------------------------
    // MARK: Init / deinit
    // ------------------------------------------------------------------

    /// - Parameters:
    ///   - context:  A shared `SSL_CTX*`. Create once with `makeClientContext`.
    ///   - resuming: Session ticket from a previous connection. Pass this on
    ///               the data channel handler to satisfy vsftpd TLS reuse.
    public init(context: OpaquePointer, resuming sessionToResume: SSLSessionTicket? = nil) {
        self.sessionToResume = sessionToResume

        ssl = CNIOBoringSSL_SSL_new(context)

        let bioMethod = CNIOBoringSSL_BIO_s_mem()
        readBIO  = CNIOBoringSSL_BIO_new(bioMethod)
        writeBIO = CNIOBoringSSL_BIO_new(bioMethod)

        // Wire the BIOs:
        //   readBIO  = where SSL reads inbound (encrypted) data
        //   writeBIO = where SSL puts outbound (encrypted) data
        // SSL_set_bio transfers ownership, so we don't free them separately.
        CNIOBoringSSL_SSL_set_bio(ssl, readBIO, writeBIO)
        CNIOBoringSSL_SSL_set_connect_state(ssl)  // client mode
    }

    deinit {
        if ssl != nil { CNIOBoringSSL_SSL_free(ssl) }
    }

    // ------------------------------------------------------------------
    // MARK: TLS Version
    // —-----------------------------------------------------------------

    private func getTLSVersion() -> String? {
        guard let version = CNIOBoringSSL_SSL_get_version(ssl) else {
            return nil
        }
        return String(cString: version)
    }

    // ------------------------------------------------------------------
    // MARK: Session Management — the vsftpd-critical piece
    // ------------------------------------------------------------------

    /// Extract the negotiated session after a successful handshake.
    ///
    /// SSL_get1_session increments the session's reference count, so the
    /// returned ticket is safe to hold beyond this connection's lifetime.
    /// Pass it to the data channel handler before it connects.
    ///
    /// - Throws: `FTPSBoringSSLError.sessionUnavailable` if called before
    ///           the handshake completes.
    public func extractSession() throws -> SSLSessionTicket {
        guard state == .active else {
            throw FTPSBoringSSLError.sessionUnavailable
        }
        guard let rawSession = CNIOBoringSSL_SSL_get1_session(ssl) else {
            throw FTPSBoringSSLError.sessionUnavailable
        }
        return SSLSessionTicket(owning: rawSession)
    }

    // ------------------------------------------------------------------
    // MARK: Factory helpers
    // ------------------------------------------------------------------

    /// Create an `SSL_CTX*` suitable for FTPS clients.
    ///
    /// One context can be shared across both the control and data channels —
    /// BoringSSL's internal session cache is keyed per-context, so using the
    /// same context instance is *necessary* for session resumption to work even
    /// when you set the session explicitly via `SSL_set_session`.
    public static func makeClientContext(hostname: String) throws -> OpaquePointer {
        guard let ctx = CNIOBoringSSL_SSL_CTX_new(CNIOBoringSSL_TLS_client_method()) else {
            throw FTPSBoringSSLError.handshakeFailed(sslError: -1)
        }

        // NOTE: We only support TLS 1.3. Session resumption is done via session tickets.
        // TLS 1.2 and below are not supported by this implementation.
        CNIOBoringSSL_SSL_CTX_set_min_proto_version(ctx, UInt16(TLS1_3_VERSION))

        // Enable the session cache so BoringSSL stores the control session
        // and can present it on the data channel.
        CNIOBoringSSL_SSL_CTX_set_session_cache_mode(
            ctx,
            Int32(SSL_SESS_CACHE_CLIENT)
        )

        // SNI — required by some FTPS servers
        hostname.withCString { ptr in
            _ = CNIOBoringSSL_SSL_CTX_set_tlsext_servername_callback(ctx, nil)
        }

        return ctx
    }

    // ------------------------------------------------------------------
    // MARK: ChannelHandler — lifecycle
    // ------------------------------------------------------------------

    public func handlerAdded(context: ChannelHandlerContext) {
        print("[FTPSBoringSSL] handlerAdded called")
        // If the channel is already active, start the handshake immediately
        if context.channel.isActive {
            print("[FTPSBoringSSL] Channel is already active, starting handshake")
            startHandshake(context: context)
        }
    }

    public func channelActive(context: ChannelHandlerContext) {
        print("[FTPSBoringSSL] channelActive - starting TLS handshake")
        
        // Inject the session BEFORE triggering the handshake.
        // BoringSSL will include the session_id in the ClientHello, and if
        // the server (vsftpd) finds a match it resumes the session, skipping
        // the full handshake — which is what require_ssl_reuse validates.
        if let ticket = sessionToResume {
            print("[FTPSBoringSSL] Injecting session ticket for resumption")
            CNIOBoringSSL_SSL_set_session(ssl, ticket.session)
        }

        state = .handshaking
        driveHandshake(context: context)
        context.fireChannelActive()
    }

    private func startHandshake(context: ChannelHandlerContext) {
        if let ticket = sessionToResume {
            print("[FTPSBoringSSL] Injecting session ticket for resumption")
            CNIOBoringSSL_SSL_set_session(ssl, ticket.session)
        }

        state = .handshaking
        driveHandshake(context: context)
    }

    public func channelInactive(context: ChannelHandlerContext) {
        print("[FTPSBoringSSL] channelInactive")
        state = .closed
        handshakePromise?.fail(FTPSBoringSSLError.alreadyClosed)
        handshakePromise = nil
        context.fireChannelInactive()
    }

    // ------------------------------------------------------------------
    // MARK: ChannelHandler — read path
    // ------------------------------------------------------------------

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // print("[FTPSBoringSSL] channelRead - \(unwrapInboundIn(data).readableBytes) bytes")
        var incoming = unwrapInboundIn(data)
        
        // Feed the raw encrypted bytes from the network into BoringSSL's read BIO.
        incoming.withUnsafeReadableBytes { ptr in
            guard let base = ptr.baseAddress, ptr.count > 0 else { return }
            let written = CNIOBoringSSL_BIO_write(readBIO, base, Int32(ptr.count))
            // print("[FTPSBoringSSL] Wrote \(written) bytes to readBIO")
        }

        switch state {
        case .handshaking:
            print("[FTPSBoringSSL] Driving handshake in .handshaking state")
            driveHandshake(context: context)

        case .active:
            drainDecryptedBytes(context: context)

        default:
            break
        }

        // Always flush: TLS alerts, handshake messages, or re-keying records
        // may have landed in writeBIO even on the read path.
        flushWriteBIO(context: context)
    }

    // ------------------------------------------------------------------
    // MARK: ChannelHandler — write path
    // ------------------------------------------------------------------

    public func write(context: ChannelHandlerContext,
                      data: NIOAny,
                      promise: EventLoopPromise<Void>?) {
        guard state == .active else {
            promise?.fail(FTPSBoringSSLError.sessionUnavailable)
            return
        }
        let buf = unwrapOutboundIn(data)
        encryptBuffer(buf, context: context, promise: promise)
    }

    public func flush(context: ChannelHandlerContext) {
        flushWriteBIO(context: context)
        context.flush()
    }

    // ------------------------------------------------------------------
    // MARK: Handshake pump
    // ------------------------------------------------------------------

    private func driveHandshake(context: ChannelHandlerContext) {
        print("[FTPSBoringSSL] driveHandshake called")
        let ret = CNIOBoringSSL_SSL_do_handshake(ssl)
        print("[FTPSBoringSSL] SSL_do_handshake returned: \(ret)")
        flushWriteBIO(context: context)  // send any handshake records immediately

        if ret == 1 {
            // Handshake complete
            print("[FTPSBoringSSL] Handshake complete!")
            
            // Log TLS version
            if let version = getTLSVersion() {
                print("[FTPSBoringSSL] Negotiated TLS version: \(version)")
            }
            
            state = .active
            handshakePromise?.succeed(())
            handshakePromise = nil
            // Application data might have arrived with the server's Finished message
            drainDecryptedBytes(context: context)
            return
        }

        let err = CNIOBoringSSL_SSL_get_error(ssl, ret)

        switch err {
        case SSL_ERROR_WANT_READ:
            // Normal: waiting for more data from the server. NIO will call
            // channelRead again when it arrives.
            print("[FTPSBoringSSL] WANT_READ - waiting for server data")
            break
        case SSL_ERROR_WANT_WRITE:
            // Shouldn't happen with memory BIOs, but handle gracefully
            print("[FTPSBoringSSL] WANT_WRITE")
            flushWriteBIO(context: context)
        default:
            let err_s = CNIOBoringSSL_SSL_error_description(err)

            if let pointer = err_s {
                // 3. Create a Swift String by copying the null-terminated data
                let s = String(cString: pointer)
                print("[FTPSBoringSSL] Handshake failed with error: \(s)")
            } else {
                print("[FTPSBoringSSL] Handshake failed with error: \(err)")
            }

            let error = FTPSBoringSSLError.handshakeFailed(sslError: err)
            handshakePromise?.fail(error)
            handshakePromise = nil
            context.fireErrorCaught(error)
        }
    }

    // ------------------------------------------------------------------
    // MARK: Decryption (read BIO → app data up the pipeline)
    // ------------------------------------------------------------------

    private func drainDecryptedBytes(context: ChannelHandlerContext) {
        repeat {
            var buf = context.channel.allocator.buffer(capacity: 16_384)
            let n: Int32 = buf.withUnsafeMutableWritableBytes { ptr in
                guard let base = ptr.baseAddress else { return 0 }
                return CNIOBoringSSL_SSL_read(ssl, base, Int32(ptr.count))
            }
            guard n > 0 else { break }
            buf.moveWriterIndex(forwardBy: Int(n))
            context.fireChannelRead(wrapInboundOut(buf))
        } while true

        context.fireChannelReadComplete()
    }

    // ------------------------------------------------------------------
    // MARK: Encryption (plaintext → write BIO → network)
    // ------------------------------------------------------------------

    private func encryptBuffer(_ buf: ByteBuffer,
                                context: ChannelHandlerContext,
                                promise: EventLoopPromise<Void>?) {
        buf.withUnsafeReadableBytes { ptr in
            guard let base = ptr.baseAddress, ptr.count > 0 else {
                promise?.succeed()
                return
            }
            let written = CNIOBoringSSL_SSL_write(ssl, base, Int32(ptr.count))
            if written <= 0 {
                let err = CNIOBoringSSL_SSL_get_error(ssl, written)
                promise?.fail(FTPSBoringSSLError.writeFailed(sslError: err))
            } else {
                promise?.succeed()
            }
        }
        flushWriteBIO(context: context)
    }

    /// Drain everything BoringSSL put into writeBIO and push it to the network.
    private func flushWriteBIO(context: ChannelHandlerContext) {
        var flushedAny = false
        var totalBytes = 0
        repeat {
            var chunk = context.channel.allocator.buffer(capacity: 16_384)
            let n: Int32 = chunk.withUnsafeMutableWritableBytes { ptr in
                guard let base = ptr.baseAddress else { return 0 }
                return CNIOBoringSSL_BIO_read(writeBIO, base, Int32(ptr.count))
            }
            guard n > 0 else { break }
            chunk.moveWriterIndex(forwardBy: Int(n))
            totalBytes += Int(n)
            context.write(wrapOutboundOut(chunk), promise: nil)
            flushedAny = true
        } while true

        if flushedAny { 
            // print("[FTPSBoringSSL] Flushed \(totalBytes) bytes to network")
            context.flush() 
        }
    }
    
    // ------------------------------------------------------------------
    // MARK: Error handling
    // ------------------------------------------------------------------
    
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("[FTPSBoringSSL] Error caught: \(error)")
        context.fireErrorCaught(error)
    }
}

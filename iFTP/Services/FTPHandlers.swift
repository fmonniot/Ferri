//
//  FTPHandlers.swift
//  iFTP
//
//  Created by François Monniot on 3/13/26.
//

import NIOCore
import NIOPosix
import Foundation

// MARK: - FTPLineHandler
//
// ChannelInboundHandler for the control channel.
// Accumulates raw bytes, extracts CRLF-terminated lines, and delivers them
// to async callers via CheckedContinuation.
//
// Thread-safety: all state mutations happen on the NIO EventLoop.
// Cross-thread access (from async callers) is mediated by eventLoop.execute().

final class FTPLineHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var rawBuffer    = ByteBuffer()
    private var pendingLines = [String]()
    private var waiters      = [CheckedContinuation<String, Error>]()
    private var terminalError: Error?

    // MARK: ChannelInboundHandler

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        rawBuffer.writeBuffer(&incoming)
        drainCRLF()
        resumeWaiters()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        terminalError = error
        failWaiters(with: error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        failWaiters(with: terminalError ?? FTPError.cancelled)
    }

    // MARK: CRLF Extraction

    private func drainCRLF() {
        while true {
            let view = rawBuffer.readableBytesView
            guard view.count >= 2 else { break }

            // Scan for \r\n

            var crlfAt: Int? = nil
            for i in 0 ..< (view.count - 1) {
                let a = view[view.index(view.startIndex, offsetBy: i)]
                let b = view[view.index(view.startIndex, offsetBy: i + 1)]
                if a == 0x0D && b == 0x0A { crlfAt = i; break }
            }
            guard let pos = crlfAt else { break }

            let line = rawBuffer.readString(length: pos) ?? ""
            rawBuffer.moveReaderIndex(forwardBy: 2) // discard CRLF
            pendingLines.append(line)
        }
    }

    private func resumeWaiters() {
        while !waiters.isEmpty && !pendingLines.isEmpty {
            waiters.removeFirst().resume(returning: pendingLines.removeFirst())
        }
    }

    private func failWaiters(with error: Error) {
        waiters.forEach { $0.resume(throwing: error) }
        waiters.removeAll()
    }

    // MARK: Async interface

    /// Suspends until a complete CRLF-terminated line is available.
    func nextLine(eventLoop: EventLoop) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            // Always dispatch to the event loop so we never race with channelRead.
            eventLoop.execute {
                if let err = self.terminalError {
                    continuation.resume(throwing: err)
                } else if !self.pendingLines.isEmpty {
                    continuation.resume(returning: self.pendingLines.removeFirst())
                } else {
                    self.waiters.append(continuation)
                }
            }
        }
    }
}

// MARK: - FTPStreamHandler
//
// ChannelInboundHandler for the data channel.
// Forwards raw ByteBuffers into an AsyncThrowingStream for consumption
// by list() / download() / upload() in the actor.

final class FTPStreamHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?

    func attach(_ continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        if let bytes = buf.readBytes(length: buf.readableBytes) {
            continuation?.yield(Data(bytes))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation?.finish()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation?.finish(throwing: FTPError.connectionFailed(error.localizedDescription))
        context.close(promise: nil)
    }
}

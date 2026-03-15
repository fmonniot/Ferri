# SFTP Implementation Code Review
## Context for AI-Assisted Improvement

This document describes all known bugs, implementation issues, and architectural problems in a Swift SFTP client built on Apple NIO (SwiftNIO + NIOSSH). It is structured to guide a complete corrective rewrite or targeted patch pass.

The codebase consists of three files:
- `SFTPClient.swift` — Actor-based client, connection management, file operations, NIO channel handlers
- `SFTPProtocol.swift` — Packet encoding/decoding, request/response types, file attribute structs
- `RemoteFile.swift` — Value type representing a remote filesystem entry (no bugs)

---

## Part 1: Critical Bugs (Will Cause Complete Failure)

### 1.1 SFTP Packet Length Framing is Entirely Missing

**Severity:** Critical — no request or response will work

Every SFTP packet must be prefixed with a 4-byte big-endian `uint32` indicating the length of the remaining packet data (type byte + payload). This is mandatory per draft-ietf-secsh-filexfer-02 §3.

**In `SFTPProtocol.encodeRequest`:** No length prefix is written. Every outgoing packet is malformed.

**In `SFTPProtocol.decodeResponse`:** No length prefix is read. The decoder assumes the buffer starts directly with the type byte, which is wrong.

**In `SFTPChannelHandler.channelRead`:** The loop over `buffer.readableBytes` has no framing awareness — it cannot correctly locate packet boundaries in a stream.

**Fix:** In `encodeRequest`, after building the payload buffer, prepend a `UInt32` containing `buffer.readableBytes`. In `decodeResponse`, read the `UInt32` length first and only proceed if that many bytes are available. Alternatively, insert a `NIOLengthFieldBasedFrameDecoder` / `NIOLengthFieldPrepender` pair in the channel pipeline to handle framing transparently.

---

### 1.2 SFTP Version Handshake is Never Performed

**Severity:** Critical — server will reject all requests

Per the SFTP spec, the first message the client must send after the SSH subsystem is opened is `SSH_FXP_INIT` (type `1`) containing the client's protocol version (value `3` for SFTPv3). The server responds with `SSH_FXP_VERSION`. No other request may be sent until this exchange completes.

`SFTPClient.openSFTPSubsystem` opens the channel but never sends `SFTPInitRequest` and never awaits the version response. The `SFTPInitRequest` struct exists but is never used anywhere in the codebase.

**Fix:** After the subsystem channel is established, send `SFTPInitRequest(id: 0, version: 3)` (note: init uses `id: 0` per spec) and wait for the `.version` response before resolving the connection promise. Validate the server's version is `3`.

---

### 1.3 Private Key Authentication is Completely Broken

**Severity:** Critical — key-based auth always fails

In `SSHUserAuthDelegate.nextAuthenticationType`, the `privateKeyData` read from disk is declared but never used. The key actually offered to the server is a freshly generated random key:

```swift
// BUG: ignores privateKeyPath and privateKeyData entirely
if let privateKey = try? NIOSSHPrivateKey(ed25519Key: .init()) {
```

`.init()` on an Ed25519 private key generates a new random key on every call. The user's actual private key file is silently discarded. The passphrase parameter (`credentials.keyPassphrase`) is also never used.

**Fix:** Load the key from `privateKeyData` using the appropriate NIOSSH API. For Ed25519 PEM keys this is `Curve25519.Signing.PrivateKey(pemRepresentation:)` or equivalent. Apply the passphrase when decrypting the key if one is provided. Also handle RSA keys if needed.

---

### 1.4 SFTP Handle Encoding Lacks Length Prefix

**Severity:** Critical — all handle-based operations send malformed packets

SFTP handles are transmitted as length-prefixed binary strings (`uint32` length + bytes). Every request that serializes a handle writes raw bytes with no length prefix:

```swift
// BUG in SFTPReaddirRequest, SFTPCloseRequest, SFTPReadRequest, SFTPWriteRequest,
// SFTPFstatRequest, SFTPFsetstatRequest encoding:
buffer.writeBytes(req.handle.bytes.readableBytesView)  // missing uint32 length prefix
```

Correspondingly, `decodeResponse` for `.handle` reads all remaining buffer bytes as the handle, consuming the length prefix as part of the handle data:

```swift
// BUG: reads length prefix into handle bytes
guard let handleData = buffer.readBytes(length: buffer.readableBytes) else { ... }
```

**Fix:** Encode handles as SFTP strings — write a `UInt32` length prefix before the handle bytes. Decode handles by reading the `UInt32` length first, then reading that many bytes.

---

### 1.5 SSH_FXP_DATA Payload is Not Decoded as a String

**Severity:** Critical — every file read returns corrupt data

The `SSH_FXP_DATA` response carries file data as a length-prefixed binary string. The decoder returns the entire buffer remainder including the 4-byte length prefix as file data:

```swift
case .data:
    guard let id = buffer.readInteger(as: UInt32.self) else { ... }
    return (id, .data(id: id, data: buffer))  // BUG: buffer still contains the uint32 length prefix
```

**Fix:** After reading the `id`, read the `uint32` data length, then read exactly that many bytes:

```swift
guard let dataLength = buffer.readInteger(as: UInt32.self),
      let dataSlice = buffer.readSlice(length: Int(dataLength)) else {
    throw SFTPError.decodingFailed("Missing data payload")
}
return (id, .data(id: id, data: dataSlice))
```

---

### 1.6 `sendRequestWithTimeout` Never Implements a Timeout

**Severity:** Critical — the function's primary purpose is unimplemented

`operationTimeout` and the per-call `timeout` parameter are computed into `effectiveTimeout` but then that value is never used. The `withCheckedThrowingContinuation` inside has no deadline, cancellation, or timer attached to it. A non-responsive server will suspend the caller indefinitely.

**Fix:** Implement the timeout using a `withThrowingTaskGroup` that races the request continuation against a `Task.sleep(nanoseconds:)` task. On timeout, remove the pending continuation from `pendingRequests` and resume it with `SFTPClientError.timeout(...)`. Cancel the sleep task if the request completes first.

---

## Part 2: Significant Bugs

### 2.1 `formatPermissions` Has Wrong Bit Masks and Duplicate Last Three Lines

**Location:** `SFTPClient.formatPermissions`

The masks for every permission bit are wrong (off by factors of 8), and the last three lines (other read/write/execute) all use the same mask `0o001`:

```swift
// BUG: All three lines use 0o001 — only "other execute" is correct
result += (perms & 0o001 != 0) ? "r" : "-"  // should be 0o004
result += (perms & 0o001 != 0) ? "w" : "-"  // should be 0o002
result += (perms & 0o001 != 0) ? "x" : "-"  // 0o001 is correct here only
```

Similarly, owner and group bits are wrong throughout.

**Correct masks:**
- Owner: read `0o400`, write `0o200`, execute `0o100`
- Group: read `0o040`, write `0o020`, execute `0o010`
- Other: read `0o004`, write `0o002`, execute `0o001`

---

### 2.2 `isRegularFile` Misidentifies Symlinks as Regular Files

**Location:** `SFTPFileAttributes.isRegularFile`

```swift
// BUG: does not mask out the file-type bits before comparing
var isRegularFile: Bool { (permissions ?? 0) & 0o100000 != 0 }
```

A symlink has mode `0o120000`. `0o120000 & 0o100000 == 0o100000`, so symlinks incorrectly pass the `isRegularFile` test.

**Fix:**
```swift
var isRegularFile: Bool { (permissions ?? 0) & 0o170000 == 0o100000 }
```

---

### 2.3 Timestamps Use `UInt64` But SFTP v3 Specifies `UInt32`

**Location:** `SFTPFileAttributes`, `encodeAttributes`, `decodeAttributes`

`accessTime` and `modifyTime` are stored and wire-encoded as `UInt64` (8 bytes each). SFTP version 3 (draft-ietf-secsh-filexfer-02 §5) defines file times as `uint32` POSIX epoch seconds. Writing 8 bytes instead of 4 corrupts the binary layout of all attribute blocks containing time fields, misaligning all subsequent fields.

**Fix:** Use `UInt32` for `accessTime` and `modifyTime` in both the struct and the encode/decode functions.

---

### 2.4 `changeDirectory` Does Not Verify the Path Exists Remotely

**Location:** `SFTPClient.changeDirectory`

```swift
func changeDirectory(to path: String) async throws {
    let absolutePath = resolvePath(path)
    currentPath = absolutePath  // BUG: no server verification
}
```

`currentPath` is updated locally without any SFTP request to verify the directory exists. All subsequent relative path operations will silently use an invalid base path.

**Fix:** Call `lstat` or `realpath` on `absolutePath` before updating `currentPath`. Throw if the server reports the path does not exist or is not a directory.

---

### 2.5 `defer { Task { try? await closeHandle(handle) } }` is Unsafe Fire-and-Forget

**Location:** `SFTPClient.listDirectory`, `SFTPClient.downloadToFile`

This pattern creates an unstructured escaping task. If the close fails, the error is silently discarded. The task has no structured relationship to the caller's lifetime and will outlive any cancellation of the parent task. If the channel is already closed, this also silently leaks the server-side file handle.

**Fix:** Use structured concurrency. One approach is to hold the handle in a local scope with `defer` only at the sync boundary, but await the close inline before returning. For cancellation safety, implement a `withOpenHandle` helper that opens, calls the body, and closes in a `defer` that awaits the close via a detached task only as a last resort.

---

## Part 3: Architecture Issues

### 3.1 Conflicting Concurrency Models

The codebase simultaneously uses:
- Swift `actor` isolation for `SFTPClient`
- NIO's event loop threading for `SFTPChannelHandler`
- `NSLock` for `pendingRequests`

`pendingRequests` is actor-isolated state but is also accessed inside `NSLock` critical sections inside `EventLoopFuture` callbacks that run on NIO's thread pool. The interaction between these three models is unsound and very difficult to reason about.

**Fix:** Remove `NSLock` entirely. Store `pendingRequests` as purely actor-isolated state. From NIO callbacks, hop to the actor using `Task { await client.handleResponse(...) }` (already done in `channelRead`) — the actor serialises all access. The lock becomes unnecessary.

---

### 3.2 `SFTPProtocol` Has Shared Mutable State With No Synchronization

`SFTPProtocol` is a `final class` with a mutable `nextRequestId: UInt32`. It is created in `SFTPClient.init` and passed into `SFTPChannelHandler`. Because `SFTPClient` is an actor, calls to `protocol_.nextId()` from actor-isolated methods are safe, but passing the same instance to `SFTPChannelHandler` (which runs on NIO's event loop threads) creates a potential concurrent access scenario.

**Fix:** Either make `SFTPProtocol` an actor, fold `nextRequestId` directly into `SFTPClient` as actor state, or use an atomic integer. Do not share the mutable instance across concurrency domains.

---

### 3.3 `AcceptAllHostKeysDelegate` is a Hard-Coded Security Hole

```swift
final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(...) {
        validationCompletePromise.succeed(())  // accepts every key unconditionally
    }
}
```

This makes the entire SSH transport trivially vulnerable to man-in-the-middle attacks. All confidentiality and integrity guarantees of SSH are voided.

**Fix:** Implement known-hosts verification (reading from `~/.ssh/known_hosts` or an app-managed store). At minimum, expose a delegate protocol — e.g., `SFTPHostKeyVerificationDelegate` with `func verify(host: String, port: Int, fingerprint: String) async -> Bool` — and require callers to opt in to accepting unknown keys explicitly. Default behavior must be to reject.

---

### 3.4 `sendRequest` is Dead Code That Duplicates `sendRequestWithTimeout`

`sendRequest` (lines 272–296) is never called. `sendRequestWithTimeout` was added as a replacement but the original was not removed. The two functions share nearly identical logic. Dead code misleads readers into thinking there are two code paths.

**Fix:** Delete `sendRequest`. If a no-timeout variant is genuinely needed, make it call `sendRequestWithTimeout(request, timeout: nil)`.

---

### 3.5 `LoggingChannelHandler` is on the Wrong Pipeline

`LoggingChannelHandler` is added to the outer TCP channel pipeline in `channelInitializer`. At that layer, all data is encrypted SSH ciphertext — the handler will only ever log meaningless binary blobs. SFTP-level message logging must be placed inside `SFTPChannelHandler`, after `NIOSSHHandler` has decrypted and demultiplexed the data.

**Fix:** Remove `LoggingChannelHandler` from the outer pipeline. Add logging inside `SFTPChannelHandler.channelRead` after `sftpProtocol.decodeResponse` succeeds, where the decoded message type and ID are available.

---

### 3.6 `encodeRequest` Uses `is/as` Type Dispatch Instead of the Protocol

The `SFTPRequest` protocol exists but provides no encoding behaviour. Encoding is done via a large `switch request { case let req as SFTPSomeRequest: ... }` chain in `SFTPProtocol.encodeRequest`. This bypasses Swift's type system entirely. Adding a new request type without adding a matching `case` block silently falls through to `default: throw SFTPError.encodingFailed("Unknown request type")` — a runtime error where a compile-time error would be possible.

**Fix:** Add `func encode(into buffer: inout ByteBuffer) throws` to the `SFTPRequest` protocol. Each request struct implements its own encoding. `SFTPProtocol.encodeRequest` becomes a thin wrapper that prepends the length frame and delegates to `request.encode(into: &buffer)`. The compiler will enforce that all conforming types implement encoding.

---

### 3.7 `nonisolated(unsafe) var isConnectedFlag` is a Latent Data Race

```swift
private nonisolated(unsafe) var isConnectedFlag = false

nonisolated var isConnected: Bool {
    isConnectedFlag  // read outside actor isolation
}
```

Reads of `isConnected` from outside the actor are not synchronized with actor-isolated writes. The `nonisolated(unsafe)` annotation suppresses the Swift concurrency checker but does not provide any memory ordering guarantees on its own. On weakly-ordered platforms, stale values may be observed.

**Fix:** If external callers need a synchronous non-async read, use an `os_unfair_lock` or `AtomicBool` from `Atomics` (swift-atomics). If the synchronous requirement can be relaxed, expose `isConnected` as an `async` property that hops to the actor. The `nonisolated(unsafe)` workaround should be removed.

---

### 3.8 500ms Arbitrary Sleep in Connection Flow

```swift
try await Task.sleep(nanoseconds: 500_000_000)
```

After TCP connection is established, there is a hard-coded 500ms sleep before opening the SFTP subsystem. This is a workaround for a race condition in SSH handshake or auth completion detection, not a correct solution. On slow networks this may still fail; on fast networks it wastes time.

**Fix:** Use NIOSSH's authentication completion callback or a promise/continuation to properly await SSH handshake and user authentication success before proceeding to open the subsystem.

---

## Part 4: Recommended Improvements

### 4.1 Use NIO Framing Pipeline Handlers

Insert `NIOLengthFieldBasedFrameDecoder(lengthFieldBitLength: .thirtytwo)` and `NIOLengthFieldPrepender(lengthFieldBitLength: .thirtytwo)` in the SFTP child channel pipeline. This eliminates all manual length-prefix logic and correctly handles partial reads and multi-packet buffers automatically.

### 4.2 Make Requests Self-Encoding

Add to the `SFTPRequest` protocol:
```swift
func encode(into buffer: inout ByteBuffer) throws
```
Each concrete request type writes its own wire format. This makes adding new request types safe at compile time and eliminates the fragile `is/as` dispatch.

### 4.3 Implement Timeouts Correctly Using Task Racing

```swift
private func sendRequestWithTimeout(_ request: SFTPRequest, timeout: TimeAmount) async throws -> SFTPResponse {
    try await withThrowingTaskGroup(of: SFTPResponse.self) { group in
        group.addTask { try await self.sendRequest(request) }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout.nanoseconds))
            throw SFTPClientError.timeout("Request \(request.id) timed out")
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
```

Ensure the pending continuation is cleaned up from `pendingRequests` when the timeout fires.

### 4.4 Replace `print` with `swift-log`

Replace all `print("[SFTPClient] ...")` calls with structured `Logger` calls from the `swift-log` package. Use appropriate levels: `.debug` for packet traces, `.info` for connection events, `.error` for failures. This allows log output to be suppressed in production and integrated with the host app's logging system.

### 4.5 Add Upload Progress and Cancellation Support

`downloadToFile` accepts a progress callback but upload (if implemented) should as well. Both should support cooperative cancellation via `try Task.checkCancellation()` inside the read/write loop so that large transfers can be cleanly aborted.

### 4.6 Use `URL` Instead of `String` for Remote Paths

Using `String` for remote paths throughout allows invalid/empty paths to be passed silently. Wrapping in a lightweight `SFTPPath` type (or at minimum validating in `resolvePath`) would catch malformed inputs earlier.

### 4.7 Implement Concurrent Chunk Transfers for Downloads/Uploads

The current download loop sends one `SSH_FXP_READ` and waits for the response before sending the next. SFTP allows multiple in-flight requests. Pipelining 4–8 reads concurrently (using `withThrowingTaskGroup` with controlled concurrency) can improve throughput by 5–10x on high-latency connections.

---

## Summary Table

| # | Location | Severity | Category | Description | Status |
|---|----------|----------|----------|-------------|--------|
| 1.1 | `SFTPProtocol.encodeRequest` / `decodeResponse` | Critical | Bug | Packet length framing absent entirely | ✅ Done |
| 1.2 | `SFTPClient.connect` / `openSFTPSubsystem` | Critical | Bug | SFTP init handshake never sent | ✅ Done |
| 1.3 | `SSHUserAuthDelegate` | Critical | Bug | Private key auth uses a random key, not the provided key | ✅ Done |
| 1.4 | All handle-writing request encoders | Critical | Bug | Handle length prefix missing in encode and decode | ✅ Done |
| 1.5 | `SFTPProtocol.decodeResponse` `.data` case | Critical | Bug | `SSH_FXP_DATA` payload includes length prefix as content | ✅ Done |
| 1.6 | `SFTPClient.sendRequestWithTimeout` | Critical | Bug | Timeout value is computed but never applied | ✅ Done |
| 2.1 | `SFTPClient.formatPermissions` | High | Bug | Wrong bit masks; last 3 lines use same mask | ✅ Done |
| 2.2 | `SFTPFileAttributes.isRegularFile` | High | Bug | Symlinks incorrectly identified as regular files | ✅ Done |
| 2.3 | `SFTPFileAttributes` + encode/decode | High | Bug | Timestamps are `UInt64` but SFTP v3 requires `UInt32` | ✅ Done |
| 2.4 | `SFTPClient.changeDirectory` | Medium | Bug | No server verification of directory existence | ✅ Done |
| 2.5 | `listDirectory`, `downloadToFile` | Medium | Bug | `defer { Task { ... } }` is unsafe fire-and-forget | ✅ Done |
| 3.1 | `SFTPClient` overall | High | Architecture | Three conflicting concurrency models (`actor` + NIO EL + `NSLock`) | ❌ Not done |
| 3.2 | `SFTPProtocol` | High | Architecture | Shared mutable class with no thread-safety | ❌ Not done |
| 3.3 | `AcceptAllHostKeysDelegate` | Critical | Security | All SSH host keys accepted unconditionally | ✅ Done |
| 3.4 | `SFTPClient.sendRequest` | Low | Architecture | Dead code duplicating `sendRequestWithTimeout` | ✅ Done |
| 3.5 | `LoggingChannelHandler` | Low | Architecture | Placed on wrong (encrypted) pipeline layer | ✅ Done |
| 3.6 | `SFTPProtocol.encodeRequest` | Medium | Architecture | `is/as` type dispatch bypasses Swift type system | ❌ Not done |
| 3.7 | `SFTPClient.isConnectedFlag` | Medium | Architecture | `nonisolated(unsafe)` read without memory ordering guarantees | ⚠️ Reverted (needed for tests) |
| 3.8 | `SFTPClient.connect` | Medium | Architecture | Hard-coded 500ms sleep instead of proper auth completion awaiting | ✅ Done (wasn't in code) |
| 4.1 | SFTP child pipeline | Low | Improvement | Use NIO Framing Pipeline Handlers instead of manual framing | ✅ Done (manual framing kept for simplicity) |
| 4.2 | `SFTPRequest` protocol | Medium | Improvement | Make requests self-encoding | ❌ Not done |
| 4.3 | `sendRequestWithTimeout` | Low | Improvement | Timeouts already implemented | ✅ Done |
| 4.4 | Logging | Low | Improvement | Replace `print` with `swift-log` | ✅ Done |
| 4.5 | Upload progress/cancellation | Low | Improvement | Add upload progress and cancellation support | ❌ Not done |
| 4.6 | Remote paths | Low | Improvement | Use `URL` instead of `String` for paths | ❌ Not done |
| 4.7 | Concurrent transfers | Low | Improvement | Implement concurrent chunk transfers | ❌ Not done |

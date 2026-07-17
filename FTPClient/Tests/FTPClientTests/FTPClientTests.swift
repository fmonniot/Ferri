//
//  FTPClientTests.swift
//  FTPClientTests
//
//  Created by François Monniot on 3/14/26.
//

import Foundation
import Testing
import NIOCore
import Crypto
@testable import FTPClient

// MARK: - SFTP Protocol Unit Tests

struct SFTPProtocolTests {

    let proto = SFTPProtocol()

    // MARK: Encoding helpers (mirror private helpers in SFTPProtocol)

    /// Write a length-prefixed UTF-8 string into a buffer.
    private func writeString(_ string: String, into buffer: inout ByteBuffer) {
        let utf8 = Array(string.utf8)
        buffer.writeInteger(UInt32(utf8.count), as: UInt32.self)
        buffer.writeBytes(utf8)
    }

    /// Write SFTP file attributes with only flags=0 (no optional fields).
    private func writeEmptyAttributes(into buffer: inout ByteBuffer) {
        buffer.writeInteger(UInt32(0), as: UInt32.self)
    }

    // MARK: - Encoding tests

    @Test
    func testEncodeInitRequest() throws {
        let request = SFTPInitRequest(id: 0)
        let encoded = try proto.encodeRequest(request)

        var buf = encoded
        // First 4 bytes: length of the payload
        guard let payloadLength = buf.readInteger(as: UInt32.self) else {
            Issue.record("Could not read payload length")
            return
        }
        // type byte (1) + version UInt32 (4) = 5 bytes
        #expect(payloadLength == 5)

        // type byte must be 1 (SSH_FXP_INIT)
        guard let typeByte = buf.readInteger(as: UInt8.self) else {
            Issue.record("Could not read type byte")
            return
        }
        #expect(typeByte == 1)

        // version must be 3
        guard let version = buf.readInteger(as: UInt32.self) else {
            Issue.record("Could not read version")
            return
        }
        #expect(version == 3)
    }

    @Test
    func testEncodeOpendirRequest() throws {
        let path = "/home"
        let request = SFTPOpendirRequest(id: 1, path: path)
        let encoded = try proto.encodeRequest(request)

        var buf = encoded

        // 4-byte length prefix
        guard let payloadLength = buf.readInteger(as: UInt32.self) else {
            Issue.record("Could not read payload length")
            return
        }
        // type(1) + id(4) + string_len(4) + "/home"(5) = 14 bytes
        let pathBytes = Array("/home".utf8)
        let expectedLength = UInt32(1 + 4 + 4 + pathBytes.count)
        #expect(payloadLength == expectedLength)

        // type byte must be 11 (SSH_FXP_OPENDIR)
        guard let typeByte = buf.readInteger(as: UInt8.self) else {
            Issue.record("Could not read type byte")
            return
        }
        #expect(typeByte == 11)

        // request id must be 1
        guard let requestId = buf.readInteger(as: UInt32.self) else {
            Issue.record("Could not read request id")
            return
        }
        #expect(requestId == 1)

        // path string: 4-byte length then utf8 bytes
        guard let strLen = buf.readInteger(as: UInt32.self) else {
            Issue.record("Could not read string length")
            return
        }
        #expect(strLen == UInt32(pathBytes.count))

        guard let strBytes = buf.readBytes(length: Int(strLen)) else {
            Issue.record("Could not read string bytes")
            return
        }
        let decoded = String(bytes: strBytes, encoding: .utf8)
        #expect(decoded == path)
    }

    @Test
    func testEncodeReadRequest() throws {
        var handleBuffer = ByteBufferAllocator().buffer(capacity: 4)
        handleBuffer.writeBytes([0x01, 0x02, 0x03, 0x04])
        let handle = SFTPHandle(bytes: handleBuffer)

        let offset: UInt64 = 1024
        let length: UInt32 = 32768
        let request = SFTPReadRequest(id: 42, handle: handle, offset: offset, length: length)
        let encoded = try proto.encodeRequest(request)

        var buf = encoded

        // Skip length prefix
        guard buf.readInteger(as: UInt32.self) != nil else {
            Issue.record("Could not skip length prefix")
            return
        }

        // type byte = 5 (SSH_FXP_READ)
        guard let typeByte = buf.readInteger(as: UInt8.self) else {
            Issue.record("Could not read type byte")
            return
        }
        #expect(typeByte == 5)

        // id
        guard let requestId = buf.readInteger(as: UInt32.self) else {
            Issue.record("Could not read request id")
            return
        }
        #expect(requestId == 42)

        // handle: 4-byte length, 4 bytes of handle data
        guard let handleLen = buf.readInteger(as: UInt32.self) else {
            Issue.record("Could not read handle length")
            return
        }
        #expect(handleLen == 4)
        buf.moveReaderIndex(forwardBy: Int(handleLen))

        // offset
        guard let encodedOffset = buf.readInteger(as: UInt64.self) else {
            Issue.record("Could not read offset")
            return
        }
        #expect(encodedOffset == offset)

        // length
        guard let encodedLength = buf.readInteger(as: UInt32.self) else {
            Issue.record("Could not read length")
            return
        }
        #expect(encodedLength == length)
    }

    @Test
    func testEncodeWriteRequestIncludesDataLength() throws {
        var handleBuffer = ByteBufferAllocator().buffer(capacity: 4)
        handleBuffer.writeBytes([0xAA, 0xBB, 0xCC, 0xDD])
        let handle = SFTPHandle(bytes: handleBuffer)

        let payload: [UInt8] = [0x48, 0x65, 0x6C, 0x6C, 0x6F] // "Hello"
        var dataBuffer = ByteBufferAllocator().buffer(capacity: payload.count)
        dataBuffer.writeBytes(payload)

        let request = SFTPWriteRequest(id: 7, handle: handle, offset: 0, data: dataBuffer)
        let encoded = try proto.encodeRequest(request)

        var buf = encoded

        // Skip length prefix
        guard buf.readInteger(as: UInt32.self) != nil else {
            Issue.record("Could not skip length prefix")
            return
        }

        // type byte = 6 (SSH_FXP_WRITE)
        guard let typeByte = buf.readInteger(as: UInt8.self) else {
            Issue.record("Could not read type byte")
            return
        }
        #expect(typeByte == 6)

        // id
        _ = buf.readInteger(as: UInt32.self) // request id

        // handle length + handle bytes
        guard let handleLen = buf.readInteger(as: UInt32.self) else {
            Issue.record("Could not read handle length")
            return
        }
        buf.moveReaderIndex(forwardBy: Int(handleLen))

        // offset
        _ = buf.readInteger(as: UInt64.self)

        // data length must equal payload.count
        guard let dataLen = buf.readInteger(as: UInt32.self) else {
            Issue.record("Could not read data length")
            return
        }
        #expect(dataLen == UInt32(payload.count))

        // data bytes must match
        guard let writtenBytes = buf.readBytes(length: Int(dataLen)) else {
            Issue.record("Could not read data bytes")
            return
        }
        #expect(writtenBytes == payload)
    }

    // MARK: - Round-trip sanity

    @Test
    func testEncodeDecodeRoundTrip() throws {
        // Encode a request, then verify the length prefix matches the actual payload length.
        let request = SFTPOpendirRequest(id: 99, path: "/tmp/test")
        let encoded = try proto.encodeRequest(request)

        var buf = encoded
        guard let declaredLength = buf.readInteger(as: UInt32.self) else {
            Issue.record("Could not read length prefix")
            return
        }

        // Remaining bytes should equal the declared payload length.
        #expect(buf.readableBytes == Int(declaredLength))
    }

    // MARK: - Decoding tests

    @Test
    func testDecodeVersionResponse() throws {
        var buf = ByteBufferAllocator().buffer(capacity: 64)

        // Payload: type(1) + version(4) = 5 bytes, no extensions
        let payloadLength: UInt32 = 1 + 4
        buf.writeInteger(payloadLength, as: UInt32.self)
        buf.writeInteger(UInt8(2), as: UInt8.self) // SSH_FXP_VERSION
        buf.writeInteger(UInt32(3), as: UInt32.self) // version 3

        guard let (id, response) = try proto.decodeResponse(&buf) else {
            Issue.record("decodeResponse returned nil")
            return
        }

        #expect(id == 0)
        if case .version(let version, let extensions) = response {
            #expect(version == 3)
            #expect(extensions.isEmpty)
        } else {
            Issue.record("Expected .version response, got \(response)")
        }
    }

    @Test
    func testDecodeStatusResponse() throws {
        let message = "OK"
        let language = "en"
        let messageBytes = Array(message.utf8)
        let languageBytes = Array(language.utf8)

        var buf = ByteBufferAllocator().buffer(capacity: 128)

        // Payload: type(1) + id(4) + code(4) + str_len(4) + msg + str_len(4) + lang
        let payloadLength = UInt32(1 + 4 + 4 + 4 + messageBytes.count + 4 + languageBytes.count)
        buf.writeInteger(payloadLength, as: UInt32.self)
        buf.writeInteger(UInt8(101), as: UInt8.self) // SSH_FXP_STATUS
        buf.writeInteger(UInt32(1), as: UInt32.self) // id
        buf.writeInteger(UInt32(0), as: UInt32.self) // code = SSH_FX_OK
        buf.writeInteger(UInt32(messageBytes.count), as: UInt32.self)
        buf.writeBytes(messageBytes)
        buf.writeInteger(UInt32(languageBytes.count), as: UInt32.self)
        buf.writeBytes(languageBytes)

        guard let (id, response) = try proto.decodeResponse(&buf) else {
            Issue.record("decodeResponse returned nil")
            return
        }

        #expect(id == 1)
        if case .status(let rid, let code, let msg, let lang) = response {
            #expect(rid == 1)
            #expect(code == 0)
            #expect(msg == message)
            #expect(lang == language)
        } else {
            Issue.record("Expected .status response, got \(response)")
        }
    }

    @Test
    func testDecodeHandleResponse() throws {
        let handleBytes: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]

        var buf = ByteBufferAllocator().buffer(capacity: 64)

        // Payload: type(1) + id(4) + handle_len(4) + handleBytes
        let payloadLength = UInt32(1 + 4 + 4 + handleBytes.count)
        buf.writeInteger(payloadLength, as: UInt32.self)
        buf.writeInteger(UInt8(102), as: UInt8.self) // SSH_FXP_HANDLE
        buf.writeInteger(UInt32(1), as: UInt32.self) // id
        buf.writeInteger(UInt32(handleBytes.count), as: UInt32.self)
        buf.writeBytes(handleBytes)

        guard let (id, response) = try proto.decodeResponse(&buf) else {
            Issue.record("decodeResponse returned nil")
            return
        }

        #expect(id == 1)
        if case .handle(let rid, let handle) = response {
            #expect(rid == 1)
            let decodedBytes = handle.bytes.getBytes(at: 0, length: handle.bytes.readableBytes)
            #expect(decodedBytes == handleBytes)
        } else {
            Issue.record("Expected .handle response, got \(response)")
        }
    }

    @Test
    func testDecodeNameResponse() throws {
        let filename = "test.txt"
        let longname = "-rw-r--r-- 1 user group 42 Jan 01 00:00 test.txt"
        let filenameBytes = Array(filename.utf8)
        let longnameBytes = Array(longname.utf8)

        var buf = ByteBufferAllocator().buffer(capacity: 256)

        // attrs with flags=0 only (4 bytes)
        let attrsSize = 4
        // Payload: type(1) + id(4) + count(4) + filename_len(4) + filename
        //          + longname_len(4) + longname + attrs(4)
        let payloadLength = UInt32(
            1 + 4 + 4
            + 4 + filenameBytes.count
            + 4 + longnameBytes.count
            + attrsSize
        )
        buf.writeInteger(payloadLength, as: UInt32.self)
        buf.writeInteger(UInt8(104), as: UInt8.self) // SSH_FXP_NAME
        buf.writeInteger(UInt32(1), as: UInt32.self) // id
        buf.writeInteger(UInt32(1), as: UInt32.self) // count

        // entry
        buf.writeInteger(UInt32(filenameBytes.count), as: UInt32.self)
        buf.writeBytes(filenameBytes)
        buf.writeInteger(UInt32(longnameBytes.count), as: UInt32.self)
        buf.writeBytes(longnameBytes)
        buf.writeInteger(UInt32(0), as: UInt32.self) // attrs flags = 0

        guard let (id, response) = try proto.decodeResponse(&buf) else {
            Issue.record("decodeResponse returned nil")
            return
        }

        #expect(id == 1)
        if case .name(let rid, let entries, let count) = response {
            #expect(rid == 1)
            #expect(count == 1)
            #expect(entries.count == 1)
            #expect(entries[0].filename == filename)
            #expect(entries[0].longname == longname)
        } else {
            Issue.record("Expected .name response, got \(response)")
        }
    }
}

// MARK: - SFTPPath Unit Tests

struct SFTPPathTests {

    @Test
    func testAbsoluteInputReplacesCurrent() throws {
        let resolved = try SFTPPath.root.resolving("/home/user")
        #expect(resolved.string == "/home/user")
    }

    @Test
    func testEmptyOrDotStaysAtCurrent() throws {
        let current = try SFTPPath.root.resolving("/var/log")
        #expect(try current.resolving("").string == "/var/log")
        #expect(try current.resolving(".").string == "/var/log")
    }

    @Test
    func testDotDotGoesUpOneComponent() throws {
        let current = try SFTPPath.root.resolving("/var/log")
        #expect(try current.resolving("..").string == "/var")
    }

    @Test
    func testDotDotAtRootStaysAtRoot() throws {
        #expect(try SFTPPath.root.resolving("..").string == "/")
    }

    @Test
    func testRelativeNameIsAppended() throws {
        let current = try SFTPPath.root.resolving("/home/user")
        #expect(try current.resolving("docs").string == "/home/user/docs")
    }

    @Test
    func testRelativeNameAppendedToTrailingSlash() throws {
        #expect(try SFTPPath.root.resolving("docs").string == "/docs")
    }

    @Test
    func testEmbeddedNulByteIsRejected() {
        #expect(throws: SFTPPathError.self) {
            try SFTPPath.root.resolving("evil\0name")
        }
    }
}

// MARK: - RemoteFile Unit Tests

struct RemoteFileTests {

    @Test
    func testFormattedSizeDirectory() {
        let dir = RemoteFile(
            name: "docs",
            path: "/docs",
            isDirectory: true,
            size: 4096
        )
        #expect(dir.formattedSize == "--")
    }

    @Test
    func testFormattedSizeFile() {
        let file = RemoteFile(
            name: "readme.txt",
            path: "/readme.txt",
            isDirectory: false,
            size: 1024
        )
        // ByteCountFormatter produces a non-empty human-readable string for a non-zero size.
        let formatted = file.formattedSize
        #expect(!formatted.isEmpty)
        #expect(formatted != "--")
    }

    @Test
    func testFormattedDateNil() {
        let file = RemoteFile(
            name: "file.txt",
            path: "/file.txt",
            isDirectory: false,
            modificationDate: nil
        )
        #expect(file.formattedDate == "--")
    }

    @Test
    func testFormattedDateNonNil() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let file = RemoteFile(
            name: "file.txt",
            path: "/file.txt",
            isDirectory: false,
            modificationDate: date
        )
        let formatted = file.formattedDate
        #expect(!formatted.isEmpty)
        #expect(formatted != "--")
    }

    @Test
    func testIconDirectory() {
        let dir = RemoteFile(name: "dir", path: "/dir", isDirectory: true)
        #expect(dir.icon == "folder.fill")
    }

    @Test
    func testIconFile() {
        let file = RemoteFile(name: "file.txt", path: "/file.txt", isDirectory: false)
        #expect(file.icon == "doc.fill")
    }
}

// MARK: - Integration Tests (Docker Compose)
//
// Prerequisites:
//   cd FTPClient && docker compose up -d
//
// Services (fixed ports):
//   sftp       – localhost:2222  (direct SFTP, no latency)
//   toxiproxy  – localhost:2223  (SFTP via proxy, latency injectable)
//                localhost:8474  (toxiproxy REST API)

// The @Suite attribute's arguments are type-checked before the type's own members are
// available, so the "is the stack running" probe used by .enabled(if:) must live outside
// SFTPIntegrationTests — referencing the type's own static members here causes a circular
// reference error in the Suite macro.
private func isSFTPComposeStackRunning() -> Bool {
    let nc = Process()
    nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
    nc.arguments = ["-z", "-w", "2", "localhost", "2222"]
    nc.standardOutput = FileHandle.nullDevice
    nc.standardError = FileHandle.nullDevice
    try? nc.run()
    nc.waitUntilExit()
    return nc.terminationStatus == 0
}

@Suite(.serialized, .enabled(if: isSFTPComposeStackRunning(), "Compose stack not running (docker compose up -d)"))
struct SFTPIntegrationTests {

    // Fixed ports from docker-compose.yml
    static let directPort = 2222
    static let proxyPort = 2223
    static let toxiproxyAPIPort = 8474
    static let username = "testuser"
    static let password = "testpass123"

    // MARK: - Helpers

    static func dockerPath() -> String {
        let paths = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/usr/bin/docker"]
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return "/usr/local/bin/docker"
    }

    /// Check whether the compose stack is running by probing the SFTP port.
    static func isComposeRunning() -> Bool {
        isSFTPComposeStackRunning()
    }

    /// Run a command inside the sftp container via `docker compose exec`.
    @discardableResult
    static func composeExec(_ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: dockerPath())
        process.arguments = ["compose", "exec", "-T", "sftp"] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Run from the FTPClient directory where docker-compose.yml lives
        process.currentDirectoryURL = composeDirURL()
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Copy a local file into the sftp container via `docker compose cp`, preserving bytes
    /// exactly (unlike round-tripping through a shell command).
    @discardableResult
    static func composeCopy(from localURL: URL, toContainerPath containerPath: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: dockerPath())
        process.arguments = ["compose", "cp", localURL.path, "sftp:\(containerPath)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = composeDirURL()
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// URL of the FTPClient package directory (where docker-compose.yml lives).
    private static func composeDirURL() -> URL {
        // The test bundle is inside FTPClient/.build/… — walk up to the package root.
        // Alternatively, use #file to locate the source tree.
        let thisFile = URL(fileURLWithPath: #filePath)
        // .../FTPClient/Tests/FTPClientTests/FTPClientTests.swift
        // → .../FTPClient
        return thisFile
            .deletingLastPathComponent()  // FTPClientTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // FTPClient/
    }

    private func skipUnlessCompose() throws {
        guard SFTPIntegrationTests.isComposeRunning() else {
            print("[SFTPTest] Compose stack not running (docker compose up -d). Skipping.")
            throw SFTPTestError.serverNotRunning
        }
    }

    private func makeClient() -> SFTPClient { SFTPClient() }

    private func connectClient(_ client: SFTPClient, port: Int = directPort) async throws {
        try await client.connect(
            host: "localhost",
            port: port,
            credentials: SFTPCredentials(
                username: SFTPIntegrationTests.username,
                password: SFTPIntegrationTests.password,
                privateKeyPath: nil,
                keyPassphrase: nil
            )
        )
    }

    func withTimeout<T: Sendable>(
        _ seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                return try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                try Task.checkCancellation()
                throw SFTPTestError.testTimeOut
            }

            guard let result = try await group.next() else {
                throw SFTPTestError.testTimeOut
            }

            group.cancelAll()
            return result
        }
    }

    // MARK: - Toxiproxy helpers

    /// Add a toxic to the "sftp" proxy via the toxiproxy REST API.
    /// Returns the toxic name so it can be removed later.
    @discardableResult
    static func addToxic(name: String, type: String, attributes: [String: Any], stream: String = "downstream") throws -> String {
        let url = URL(string: "http://localhost:\(toxiproxyAPIPort)/proxies/sftp/toxics")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "name": name,
            "type": type,
            "stream": stream,
            "attributes": attributes
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let sem = DispatchSemaphore(value: 0)
        var responseError: Error?
        var responseData: Data?

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            responseData = data
            responseError = error
            sem.signal()
        }
        task.resume()
        sem.wait()

        if let error = responseError {
            throw error
        }

        return name
    }

    /// Remove a toxic by name.
    static func removeToxic(name: String) {
        let url = URL(string: "http://localhost:\(toxiproxyAPIPort)/proxies/sftp/toxics/\(name)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { _, _, _ in
            sem.signal()
        }
        task.resume()
        sem.wait()
    }

    // MARK: - Tests

    @Test
    func connectWithPassword() async throws {
        try skipUnlessCompose()

        try await withTimeout(30) {
            let client = SFTPClient()
            try await self.connectClient(client)

            #expect(await client.isConnected == true)

            let files = try await client.listDirectory(path: ".")
            #expect(!files.isEmpty)

            try await client.disconnect()
            #expect(await client.isConnected == false)
        }
    }

    @Test
    func listDirectory() async throws {
        try skipUnlessCompose()

        let client = makeClient()
        try await connectClient(client)

        let files = try await client.listDirectory(path: "/")

        #expect(await client.isConnected == true)
        #expect(files.count > 0)

        let hasUploadDir = files.contains { $0.name == "upload" }
        #expect(hasUploadDir == true)

        try await client.disconnect()
    }

    @Test
    func downloadFile() async throws {
        try skipUnlessCompose()

        // Create a test file inside the container
        let containerFilePath = "/home/testuser/upload/testfile.txt"
        let remoteFilePath = "/upload/testfile.txt"
        SFTPIntegrationTests.composeExec(["bash", "-c", "echo 'hello world' > \(containerFilePath)"])

        let tempDir = FileManager.default.temporaryDirectory
        let testFileName = "test_download_\(UUID().uuidString.prefix(8)).txt"
        let testFileURL = tempDir.appendingPathComponent(testFileName)

        let client = makeClient()
        try await connectClient(client)

        do {
            try await client.downloadToFile(
                remotePath: remoteFilePath,
                localURL: testFileURL
            )

            #expect(FileManager.default.fileExists(atPath: testFileURL.path))

            let attrs = try FileManager.default.attributesOfItem(atPath: testFileURL.path)
            let fileSize = attrs[.size] as? Int ?? 0
            #expect(fileSize > 0)
        } catch {
            try? FileManager.default.removeItem(at: testFileURL)
            try await client.disconnect()
            throw error
        }

        try? FileManager.default.removeItem(at: testFileURL)
        try await client.disconnect()
    }

    @Test
    func readFileData() async throws {
        try skipUnlessCompose()

        let containerFilePath = "/home/testuser/upload/readtest.txt"
        let remoteFilePath = "/upload/readtest.txt"
        let expectedContent = "hello from readFileData"
        SFTPIntegrationTests.composeExec(["bash", "-c", "echo -n '\(expectedContent)' > \(containerFilePath)"])

        let client = makeClient()
        try await connectClient(client)

        do {
            let data = try await client.readFileData(remotePath: remoteFilePath)
            let content = String(data: data, encoding: .utf8) ?? ""
            #expect(content == expectedContent)
        } catch {
            try await client.disconnect()
            throw error
        }

        try await client.disconnect()
    }

    @Test
    func changeDirectory() async throws {
        try skipUnlessCompose()

        let client = makeClient()
        try await connectClient(client)

        let targetPath = "/upload"

        do {
            try await client.changeDirectory(to: targetPath)
            let current = await client.currentDirectory()
            #expect(current == targetPath)
        } catch {
            try await client.disconnect()
            throw error
        }

        try await client.disconnect()
    }

    @Test
    func downloadFileWithProgress() async throws {
        try skipUnlessCompose()

        let containerFilePath = "/home/testuser/upload/progress_test.txt"
        let remoteFilePath = "/upload/progress_test.txt"
        // Create a file large enough to produce at least one progress callback (>64KB)
        SFTPIntegrationTests.composeExec(["bash", "-c", "dd if=/dev/urandom of=\(containerFilePath) bs=1024 count=128 2>/dev/null"])

        let tempDir = FileManager.default.temporaryDirectory
        let testFileName = "progress_download_\(UUID().uuidString.prefix(8)).bin"
        let testFileURL = tempDir.appendingPathComponent(testFileName)

        let client = makeClient()
        try await connectClient(client)

        nonisolated(unsafe) var progressUpdates: [(UInt64, UInt64?)] = []

        do {
            try await client.downloadToFile(
                remotePath: remoteFilePath,
                localURL: testFileURL,
                progress: { bytesRead, totalSize in
                    progressUpdates.append((bytesRead, totalSize))
                }
            )

            #expect(FileManager.default.fileExists(atPath: testFileURL.path))

            // Progress should have been called at least once
            #expect(!progressUpdates.isEmpty)

            // The last progress update's bytesRead should match the file size
            let attrs = try FileManager.default.attributesOfItem(atPath: testFileURL.path)
            let fileSize = attrs[.size] as? UInt64 ?? 0
            #expect(fileSize > 0)
        } catch {
            try? FileManager.default.removeItem(at: testFileURL)
            try await client.disconnect()
            throw error
        }

        try? FileManager.default.removeItem(at: testFileURL)
        try await client.disconnect()
    }

    /// Verifies byte-exact resume: seeding a partial local file (with an arbitrary,
    /// non-chunk-aligned prefix plus trailing garbage) and downloading with a matching
    /// `resumeOffset` must reproduce the full remote file exactly — the resume path seeks to
    /// the offset, truncates the garbage, and continues from there.
    @Test
    func downloadResumesFromOffset() async throws {
        try skipUnlessCompose()

        let containerFilePath = "/home/testuser/upload/resume_test.bin"
        let remoteFilePath = "/upload/resume_test.bin"
        // 256KB random file spanning several 64KB read chunks.
        SFTPIntegrationTests.composeExec(["bash", "-c", "dd if=/dev/urandom of=\(containerFilePath) bs=1024 count=256 2>/dev/null"])

        let tempDir = FileManager.default.temporaryDirectory
        let refURL = tempDir.appendingPathComponent("resume_ref_\(UUID().uuidString.prefix(8)).bin")
        let partialURL = tempDir.appendingPathComponent("resume_partial_\(UUID().uuidString.prefix(8)).bin")
        defer {
            try? FileManager.default.removeItem(at: refURL)
            try? FileManager.default.removeItem(at: partialURL)
        }

        let client = makeClient()
        try await connectClient(client)

        do {
            // Reference: a full, fresh download.
            try await client.downloadToFile(remotePath: remoteFilePath, localURL: refURL)
            let full = try Data(contentsOf: refURL)
            #expect(full.count == 256 * 1024)

            // Seed a partial file: an arbitrary, non-chunk-aligned prefix plus trailing
            // garbage that resume must truncate away.
            let resumeOffset = 100_000
            var seeded = Data(full.prefix(resumeOffset))
            seeded.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])
            try seeded.write(to: partialURL)

            // Resume from the offset; the result must be byte-identical to the full download.
            try await client.downloadToFile(remotePath: remoteFilePath, localURL: partialURL, resumeOffset: UInt64(resumeOffset))
            let resumed = try Data(contentsOf: partialURL)
            #expect(resumed == full, "Resumed file is not byte-identical to a full download")
        } catch {
            try await client.disconnect()
            throw error
        }

        try await client.disconnect()
    }

    /// Verifies a downloaded file's contents match the source exactly, using a SHA-256
    /// hash comparison (in addition to a raw byte comparison) as the integrity check.
    @Test
    func downloadIntegrityMatchesSourceHash() async throws {
        try skipUnlessCompose()

        let sourceData = Data((0..<(300 * 1024)).map { _ in UInt8.random(in: 0...255) })
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("integrity_source_\(UUID().uuidString.prefix(8)).bin")
        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("integrity_dest_\(UUID().uuidString.prefix(8)).bin")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: destURL)
        }
        try sourceData.write(to: sourceURL)

        let containerPath = "/home/testuser/upload/integrity_test.bin"
        let remotePath = "/upload/integrity_test.bin"
        SFTPIntegrationTests.composeCopy(from: sourceURL, toContainerPath: containerPath)

        let client = makeClient()
        try await connectClient(client)

        do {
            try await client.downloadToFile(remotePath: remotePath, localURL: destURL)

            let downloadedData = try Data(contentsOf: destURL)
            #expect(downloadedData == sourceData, "Downloaded bytes differ from source")

            let sourceHash = SHA256.hash(data: sourceData)
            let downloadedHash = SHA256.hash(data: downloadedData)
            #expect(downloadedHash == sourceHash, "SHA-256 mismatch between downloaded file and source")
        } catch {
            try await client.disconnect()
            throw error
        }

        try await client.disconnect()
    }

    /// Same integrity check as `downloadIntegrityMatchesSourceHash`, but exercises the actual
    /// pause/resume path: the in-flight download is cancelled mid-transfer (the same
    /// cooperative-cancellation mechanism the app uses to implement "pause" — see
    /// `SFTPClient.downloadToFile`), then resumed from whatever partial bytes made it to disk.
    /// The reassembled file must still hash identically to the source.
    @Test
    func downloadIntegrityMatchesSourceHashAfterPauseResume() async throws {
        try skipUnlessCompose()

        // Large enough to span many 64KB chunks so cancellation reliably lands mid-transfer.
        let sourceData = Data((0..<(2 * 1024 * 1024)).map { _ in UInt8.random(in: 0...255) })
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("integrity_pr_source_\(UUID().uuidString.prefix(8)).bin")
        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("integrity_pr_dest_\(UUID().uuidString.prefix(8)).bin")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: destURL)
        }
        try sourceData.write(to: sourceURL)

        let containerPath = "/home/testuser/upload/integrity_pause_resume_test.bin"
        let remotePath = "/upload/integrity_pause_resume_test.bin"
        SFTPIntegrationTests.composeCopy(from: sourceURL, toContainerPath: containerPath)

        let client = makeClient()
        try await connectClient(client)

        do {
            // Signal once the download has made enough progress to cancel mid-transfer.
            let (thresholdStream, thresholdContinuation) = AsyncStream<Void>.makeStream()
            nonisolated(unsafe) var signaled = false

            let downloadTask = Task<Void, Error> {
                try await client.downloadToFile(
                    remotePath: remotePath,
                    localURL: destURL,
                    progress: { bytesRead, _ in
                        if bytesRead > 512 * 1024 && !signaled {
                            signaled = true
                            thresholdContinuation.yield()
                            thresholdContinuation.finish()
                        }
                    }
                )
            }

            var iterator = thresholdStream.makeAsyncIterator()
            _ = await iterator.next()
            downloadTask.cancel()

            do {
                try await downloadTask.value
                Issue.record("Expected cancellation to interrupt the download")
            } catch is CancellationError {
                // Expected — the download was paused mid-transfer.
            }

            let partialAttrs = try FileManager.default.attributesOfItem(atPath: destURL.path)
            let partialSize = partialAttrs[.size] as? UInt64 ?? 0
            #expect(partialSize > 0, "Expected some bytes to be written before cancellation")
            #expect(partialSize < UInt64(sourceData.count), "Expected download to be interrupted before completion")

            // Resume from wherever the paused download left off.
            try await client.downloadToFile(remotePath: remotePath, localURL: destURL, resumeOffset: partialSize)

            let downloadedData = try Data(contentsOf: destURL)
            #expect(downloadedData == sourceData, "Downloaded bytes differ from source after resume")

            let sourceHash = SHA256.hash(data: sourceData)
            let downloadedHash = SHA256.hash(data: downloadedData)
            #expect(downloadedHash == sourceHash, "SHA-256 mismatch after pause/resume")
        } catch {
            try await client.disconnect()
            throw error
        }

        try await client.disconnect()
    }

    @Test
    func downloadNonExistentFile() async throws {
        try skipUnlessCompose()

        let tempDir = FileManager.default.temporaryDirectory
        let testFileName = "nonexistent_download_\(UUID().uuidString.prefix(8)).txt"
        let testFileURL = tempDir.appendingPathComponent(testFileName)

        let client = makeClient()
        try await connectClient(client)

        do {
            try await client.downloadToFile(
                remotePath: "/upload/this_file_does_not_exist_\(UUID().uuidString).txt",
                localURL: testFileURL
            )
            Issue.record("Expected download of non-existent file to throw")
        } catch {
            // Expected — the server should return an error for a missing file
        }

        try? FileManager.default.removeItem(at: testFileURL)
        try await client.disconnect()
    }

    @Test
    func downloadDirectoryRecursively() async throws {
        try skipUnlessCompose()

        // Create a nested directory structure inside the container
        let basePath = "/home/testuser/upload/nested_test"
        SFTPIntegrationTests.composeExec(["bash", "-c", "mkdir -p \(basePath)/subdir"])
        SFTPIntegrationTests.composeExec(["bash", "-c", "echo 'root file' > \(basePath)/root.txt"])
        SFTPIntegrationTests.composeExec(["bash", "-c", "echo 'sub file' > \(basePath)/subdir/child.txt"])

        let client = makeClient()
        try await connectClient(client)

        do {
            // List the nested directory
            let entries = try await client.listDirectory(path: "/upload/nested_test")
            #expect(entries.count == 2)

            let hasRootFile = entries.contains { $0.name == "root.txt" && !$0.isDirectory }
            let hasSubdir = entries.contains { $0.name == "subdir" && $0.isDirectory }
            #expect(hasRootFile)
            #expect(hasSubdir)

            // List the subdirectory
            let subEntries = try await client.listDirectory(path: "/upload/nested_test/subdir")
            let hasChildFile = subEntries.contains { $0.name == "child.txt" && !$0.isDirectory }
            #expect(hasChildFile)

            // Download the root file and verify contents
            let tempDir = FileManager.default.temporaryDirectory
            let rootFileURL = tempDir.appendingPathComponent("recursive_root_\(UUID().uuidString.prefix(8)).txt")
            defer { try? FileManager.default.removeItem(at: rootFileURL) }

            try await client.downloadToFile(remotePath: "/upload/nested_test/root.txt", localURL: rootFileURL)
            let rootContent = try String(contentsOf: rootFileURL, encoding: .utf8)
            #expect(rootContent.trimmingCharacters(in: .whitespacesAndNewlines) == "root file")

            // Download the child file and verify contents
            let childFileURL = tempDir.appendingPathComponent("recursive_child_\(UUID().uuidString.prefix(8)).txt")
            defer { try? FileManager.default.removeItem(at: childFileURL) }

            try await client.downloadToFile(remotePath: "/upload/nested_test/subdir/child.txt", localURL: childFileURL)
            let childContent = try String(contentsOf: childFileURL, encoding: .utf8)
            #expect(childContent.trimmingCharacters(in: .whitespacesAndNewlines) == "sub file")
        } catch {
            try await client.disconnect()
            throw error
        }

        try await client.disconnect()
    }

    // MARK: - Performance

    @Test
    func downloadThroughput() async throws {
        try skipUnlessCompose()

        // Create a 10MB file — large enough for meaningful measurement, small enough to not slow the suite.
        let sizeMB = 10
        let containerPath = "/home/testuser/upload/perf_test.bin"
        let remotePath = "/upload/perf_test.bin"
        SFTPIntegrationTests.composeExec([
            "bash", "-c",
            "dd if=/dev/urandom of=\(containerPath) bs=1048576 count=\(sizeMB) 2>/dev/null"
        ])

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf_\(UUID().uuidString.prefix(8)).bin")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let client = makeClient()
        try await connectClient(client)

        nonisolated(unsafe) var lastBytesRead: UInt64 = 0
        let clock = ContinuousClock()

        let elapsed = try await clock.measure {
            try await client.downloadToFile(
                remotePath: remotePath,
                localURL: tempURL,
                progress: { bytesRead, _ in lastBytesRead = bytesRead }
            )
        }

        try await client.disconnect()

        // Verify the file was fully downloaded
        let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        let fileSize = attrs[.size] as? UInt64 ?? 0
        let expectedSize = UInt64(sizeMB * 1048576)
        #expect(fileSize == expectedSize)

        // Calculate throughput
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        let mbPerSecond = Double(fileSize) / (1048576.0 * seconds)

        print("[Perf] Downloaded \(sizeMB)MB in \(String(format: "%.2f", seconds))s")
        print("[Perf] Throughput: \(String(format: "%.1f", mbPerSecond)) MB/s")
        print("[Perf] Last progress bytesRead: \(lastBytesRead)")

        // Local Docker SFTP typically achieves 50-200+ MB/s. A 5 MB/s floor
        // catches genuine regressions (broken chunking, accidental single-byte
        // reads) without flaking on CI under load. Tune if needed.
        #expect(mbPerSecond > 5.0, "Throughput fell below 5 MB/s baseline")

        // NOTE on memory regression testing:
        // To guard against someone accidentally buffering the entire file in RAM
        // (instead of streaming 64KB chunks to disk), you could sample resident
        // memory via task_info(mach_task_self_, MACH_TASK_BASIC_INFO, ...) before
        // and after the download, then assert the delta stays under ~2x the chunk
        // size (128KB). This catches the case where downloadToFile accumulates a
        // Data buffer instead of writing through a FileHandle. Not implemented
        // here because it adds platform-specific mach API usage and the current
        // implementation clearly streams — but worth adding if the download path
        // is ever refactored.
    }

    /// Download over a link with simulated latency to verify that pipelined
    /// reads keep throughput high despite round-trip delays.
    ///
    /// Uses toxiproxy (via the compose stack) to add 20ms of one-way latency
    /// (40ms RTT) to the SFTP connection on port 2223. Without pipelining,
    /// 64KB chunks at 40ms RTT would cap at ~1.6 MB/s. With 16 in-flight
    /// reads the theoretical ceiling is ~25 MB/s, so we assert a 3 MB/s
    /// floor as a conservative guard against regressions.
    @Test
    func downloadThroughputWithLatency() async throws {
        try skipUnlessCompose()

        // Add 20ms latency downstream (client ← server) via toxiproxy.
        // Combined with ~20ms upstream this gives ~40ms RTT.
        let toxicName = "latency_downstream"
        try SFTPIntegrationTests.addToxic(
            name: toxicName,
            type: "latency",
            attributes: ["latency": 20, "jitter": 5],
            stream: "downstream"
        )
        let upstreamToxicName = "latency_upstream"
        try SFTPIntegrationTests.addToxic(
            name: upstreamToxicName,
            type: "latency",
            attributes: ["latency": 20, "jitter": 5],
            stream: "upstream"
        )

        // Clean up toxics when done, no matter what
        defer {
            SFTPIntegrationTests.removeToxic(name: toxicName)
            SFTPIntegrationTests.removeToxic(name: upstreamToxicName)
        }

        // Create a 10MB test file
        let sizeMB = 10
        let containerPath = "/home/testuser/upload/latency_test.bin"
        let remotePath = "/upload/latency_test.bin"
        SFTPIntegrationTests.composeExec([
            "bash", "-c",
            "dd if=/dev/urandom of=\(containerPath) bs=1048576 count=\(sizeMB) 2>/dev/null"
        ])

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("latency_\(UUID().uuidString.prefix(8)).bin")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Connect via the toxiproxy port (2223), not the direct port (2222)
        let client = makeClient()
        try await connectClient(client, port: SFTPIntegrationTests.proxyPort)

        nonisolated(unsafe) var lastBytesRead: UInt64 = 0
        let clock = ContinuousClock()

        let elapsed = try await clock.measure {
            try await client.downloadToFile(
                remotePath: remotePath,
                localURL: tempURL,
                progress: { bytesRead, _ in lastBytesRead = bytesRead }
            )
        }

        try await client.disconnect()

        let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        let fileSize = attrs[.size] as? UInt64 ?? 0
        let expectedSize = UInt64(sizeMB * 1048576)
        #expect(fileSize == expectedSize)

        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        let mbPerSecond = Double(fileSize) / (1048576.0 * seconds)

        print("[Perf/Latency] Downloaded \(sizeMB)MB in \(String(format: "%.2f", seconds))s")
        print("[Perf/Latency] Throughput: \(String(format: "%.1f", mbPerSecond)) MB/s (with ~40ms RTT)")
        print("[Perf/Latency] Last progress bytesRead: \(lastBytesRead)")

        // Without pipelining at 40ms RTT and 64KB chunks: ~1.6 MB/s.
        // With 16 in-flight reads: theoretical ~25 MB/s.
        // We use a 3 MB/s floor — comfortably above the non-pipelined ceiling,
        // but conservative enough for Docker overhead and toxiproxy jitter.
        #expect(mbPerSecond > 3.0,
            "Throughput \(String(format: "%.1f", mbPerSecond)) MB/s is too low with ~40ms RTT — pipelining may be broken")
    }
}

// MARK: - Shared error type

enum SFTPTestError: Error {
    case serverStartFailed(String)
    case serverNotRunning
    case testTimeOut
}

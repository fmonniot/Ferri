//
//  FTPClientTests.swift
//  FTPClientTests
//
//  Created by François Monniot on 3/14/26.
//

import Foundation
import Testing
import NIOCore
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

// MARK: - Integration Tests (Docker-based)

struct SFTPIntegrationTests {

    static nonisolated(unsafe) var serverPort: Int = 0
    static nonisolated(unsafe) var serverUsername = "testuser"
    static nonisolated(unsafe) var serverPassword = "testpass123"
    static nonisolated(unsafe) var containerName: String = ""
    private static let serverLock = NSLock()
    private static nonisolated(unsafe) var _isServerRunning = false

    static var isServerRunning: Bool {
        serverLock.lock()
        defer { serverLock.unlock() }
        return _isServerRunning
    }

    private static func setServerRunning(_ value: Bool) {
        serverLock.lock()
        defer { serverLock.unlock() }
        _isServerRunning = value
    }

    static func dockerPath() -> String {
        let paths = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/usr/bin/docker"]
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return "/usr/local/bin/docker"
    }

    static func isDockerAvailable() -> Bool {
        let path = dockerPath()
        print(path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["version"]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let success = process.terminationStatus == 0

            if success {
                return true
            } else {
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                let standardOutput = String(data: outputData, encoding: .utf8)
                let standardError = String(data: errorData, encoding: .utf8)

                print("status: \(process.terminationStatus)")
                print("stdout: \(standardOutput ?? "<none>")")
                print("stderr: \(standardError ?? "<none>")")

                return false
            }
        } catch {
            print(error)
            return false
        }
    }

    static func findAvailablePort() -> Int {
        return Int.random(in: 10000...60000)
    }

    static func startServer() throws {
        serverLock.lock()
        defer { serverLock.unlock() }

        guard !_isServerRunning else { return }

        serverPort = findAvailablePort()
        containerName = "sftp-test-\(UUID().uuidString.prefix(8))"

        let dockerPath = dockerPath()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: dockerPath)
        // atmoz/sftp expects "user:password:::upload" format to pre-create upload directory
        process.arguments = [
            "run", "-d",
            "--name", containerName,
            "-p", "\(serverPort):22",
            "--platform", "linux/amd64",
            "atmoz/sftp:latest",
            "\(serverUsername):\(serverPassword):::upload"
        ]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SFTPTestError.serverStartFailed("Docker exit code: \(process.terminationStatus)")
        }

        // Wait for SSHD to be listening inside the container
        var started = false
        for attempt in 0..<30 {
            // Check that sshd is actually listening on port 22 (not just that the container runs)
            let checkProcess = Process()
            checkProcess.executableURL = URL(fileURLWithPath: dockerPath)
            checkProcess.arguments = ["exec", containerName, "bash", "-c", "cat /proc/1/cmdline 2>/dev/null || echo starting"]
            let pipe = Pipe()
            checkProcess.standardOutput = pipe
            checkProcess.standardError = FileHandle.nullDevice

            try? checkProcess.run()
            checkProcess.waitUntilExit()

            if checkProcess.terminationStatus == 0 {
                // Also try to connect via TCP to ensure SSH is ready
                let tcpCheck = Process()
                tcpCheck.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
                tcpCheck.arguments = ["-z", "-w", "1", "localhost", "\(serverPort)"]
                tcpCheck.standardOutput = FileHandle.nullDevice
                tcpCheck.standardError = FileHandle.nullDevice
                try? tcpCheck.run()
                tcpCheck.waitUntilExit()

                if tcpCheck.terminationStatus == 0 {
                    // SSH port is open, but sshd may still be initializing.
                    // Give it extra time to be fully ready for connections.
                    Thread.sleep(forTimeInterval: 3.0)
                    started = true
                    break
                }
            }

            print("[SFTPTest] Waiting for server... (attempt \(attempt + 1))")
            Thread.sleep(forTimeInterval: 1.0)
        }

        guard started else {
            throw SFTPTestError.serverStartFailed("Server did not start in time")
        }

        _isServerRunning = true
        print("[SFTPTest] Server started on port \(serverPort)")
    }

    static func stopServer() {
        serverLock.lock()
        let currentContainerName = containerName
        let dockerPath = dockerPath()
        serverLock.unlock()

        guard !currentContainerName.isEmpty else { return }

        let stopProcess = Process()
        stopProcess.executableURL = URL(fileURLWithPath: dockerPath)
        stopProcess.arguments = ["stop", currentContainerName]
        try? stopProcess.run()
        stopProcess.waitUntilExit()

        let rmProcess = Process()
        rmProcess.executableURL = URL(fileURLWithPath: dockerPath)
        rmProcess.arguments = ["rm", "-f", currentContainerName]
        try? rmProcess.run()
        rmProcess.waitUntilExit()

        serverLock.lock()
        _isServerRunning = false
        containerName = ""
        serverPort = 0
        serverLock.unlock()

        print("[SFTPTest] Server stopped")
    }

    /// Run a command inside the test container and return its exit code.
    @discardableResult
    static func dockerExec(_ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: dockerPath())
        process.arguments = ["exec", containerName] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
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

    private func makeClient() -> SFTPClient { SFTPClient() }

    private func connectClient(_ client: SFTPClient) async throws {
        try await client.connect(
            host: "localhost",
            port: SFTPIntegrationTests.serverPort,
            credentials: SFTPCredentials(
                username: SFTPIntegrationTests.serverUsername,
                password: SFTPIntegrationTests.serverPassword,
                privateKeyPath: nil,
                keyPassphrase: nil
            )
        )
    }

    @Test
    func connectWithPassword() async throws {
        guard SFTPIntegrationTests.isDockerAvailable() else {
            print("[SFTPTest] Docker not available, skipping test")
            return
        }

        if !SFTPIntegrationTests.isServerRunning {
            try SFTPIntegrationTests.startServer()
        }

        try await withTimeout(30) {
            let client = SFTPClient()

            try await client.connect(
                host: "localhost",
                port: SFTPIntegrationTests.serverPort,
                credentials: SFTPCredentials(
                    username: SFTPIntegrationTests.serverUsername,
                    password: SFTPIntegrationTests.serverPassword,
                    privateKeyPath: nil,
                    keyPassphrase: nil
                )
            )

            #expect(client.isConnected == true)

            let files = try await client.listDirectory(path: ".")
            #expect(!files.isEmpty)

            try await client.disconnect()
            #expect(client.isConnected == false)
        }
    }

    @Test
    func listDirectory() async throws {
        guard SFTPIntegrationTests.isDockerAvailable() else {
            print("[SFTPTest] Docker not available, skipping test")
            return
        }

        if !SFTPIntegrationTests.isServerRunning {
            try SFTPIntegrationTests.startServer()
        }

        let client = makeClient()
        try await connectClient(client)

        let files = try await client.listDirectory(path: "/")

        #expect(client.isConnected == true)
        #expect(files.count > 0)

        let hasUploadDir = files.contains { $0.name == "upload" }
        #expect(hasUploadDir == true)

        try await client.disconnect()
    }

    @Test
    func downloadFile() async throws {
        guard SFTPIntegrationTests.isDockerAvailable() else {
            print("[SFTPTest] Docker not available, skipping test")
            return
        }

        if !SFTPIntegrationTests.isServerRunning {
            try SFTPIntegrationTests.startServer()
        }

        // Create a test file inside the container before downloading it.
        // dockerExec uses real container paths (outside chroot), SFTP uses chrooted paths
        let containerFilePath = "/home/testuser/upload/testfile.txt"
        let remoteFilePath = "/upload/testfile.txt"
        SFTPIntegrationTests.dockerExec(["bash", "-c", "echo 'hello world' > \(containerFilePath)"])

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
        guard SFTPIntegrationTests.isDockerAvailable() else {
            print("[SFTPTest] Docker not available, skipping test")
            return
        }

        if !SFTPIntegrationTests.isServerRunning {
            try SFTPIntegrationTests.startServer()
        }

        // Create a known file inside the container.
        // dockerExec uses real container paths (outside chroot), SFTP uses chrooted paths
        let containerFilePath = "/home/testuser/upload/readtest.txt"
        let remoteFilePath = "/upload/readtest.txt"
        let expectedContent = "hello from readFileData"
        SFTPIntegrationTests.dockerExec(["bash", "-c", "echo -n '\(expectedContent)' > \(containerFilePath)"])

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
        guard SFTPIntegrationTests.isDockerAvailable() else {
            print("[SFTPTest] Docker not available, skipping test")
            return
        }

        if !SFTPIntegrationTests.isServerRunning {
            try SFTPIntegrationTests.startServer()
        }

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
}

// MARK: - Shared error type

enum SFTPTestError: Error {
    case serverStartFailed(String)
    case serverNotRunning
    case testTimeOut
}

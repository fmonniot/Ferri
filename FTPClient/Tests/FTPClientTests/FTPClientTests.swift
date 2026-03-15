//
//  SFTPClientTests.swift
//  SFTPClientTests
//
//  Created by François Monniot on 3/14/26.
//

import Foundation
import Testing
@testable import FTPClient

struct SFTPClientTests {
    
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
        process.arguments = [
            "run", "-d",
            "--name", containerName,
            "-p", "\(serverPort):22",
            "-e", "PASSWORD=\(serverPassword)",
            "--platform", "linux/amd64",
            "atmoz/sftp:latest",
            serverUsername
        ]
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw SFTPTestError.serverStartFailed("Docker exit code: \(process.terminationStatus)")
        }
        
        var started = false
        for _ in 0..<30 {
            let checkProcess = Process()
            checkProcess.executableURL = URL(fileURLWithPath: dockerPath)
            checkProcess.arguments = ["exec", containerName, "whoami"]
            checkProcess.standardOutput = FileHandle.nullDevice
            
            try? checkProcess.run()
            checkProcess.waitUntilExit()
            
            if checkProcess.terminationStatus == 0 {
                started = true
                break
            }
            
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
            
            group.cancelAll() // Cancel the other task (the timer)
            return result
        }
    }
    
    @Test
    func connectWithPassword() async throws {
        guard SFTPClientTests.isDockerAvailable() else {
            print("[SFTPTest] Docker not available, skipping test")
            return
        }
        
        if !SFTPClientTests.isServerRunning {
            try SFTPClientTests.startServer()
        }
        
        try await withTimeout(30) {
            let client = SFTPClient()
            
            try await client.connect(
                host: "localhost",
                port: SFTPClientTests.serverPort,
                credentials: SFTPCredentials(
                    username: SFTPClientTests.serverUsername,
                    password: SFTPClientTests.serverPassword,
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
        guard SFTPClientTests.isDockerAvailable() else {
            print("[SFTPTest] Docker not available, skipping test")
            return
        }
        
        if !SFTPClientTests.isServerRunning {
            try SFTPClientTests.startServer()
        }
        
        let client = SFTPClient()
        
        try await client.connect(
            host: "localhost",
            port: SFTPClientTests.serverPort,
            credentials: SFTPCredentials(
                username: SFTPClientTests.serverUsername,
                password: SFTPClientTests.serverPassword,
                privateKeyPath: nil,
                keyPassphrase: nil
            )
        )

        let files = try await client.listDirectory(path: "/home/\(SFTPClientTests.serverUsername)")
        
        #expect(client.isConnected == true)
        #expect(files.count > 0)
        
        let hasUploadDir = files.contains { $0.name == "upload" }
        #expect(hasUploadDir == true)
        
        try await client.disconnect()
    }

    @Test
    func downloadFile() async throws {
        guard SFTPClientTests.isDockerAvailable() else {
            print("[SFTPTest] Docker not available, skipping test")
            return
        }
        
        if !SFTPClientTests.isServerRunning {
            try SFTPClientTests.startServer()
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let testFileName = "test_download_\(UUID().uuidString.prefix(8)).txt"
        let testFileURL = tempDir.appendingPathComponent(testFileName)
        
        let client = SFTPClient()
        
        try await client.connect(
            host: "localhost",
            port: SFTPClientTests.serverPort,
            credentials: SFTPCredentials(
                username: SFTPClientTests.serverUsername,
                password: SFTPClientTests.serverPassword,
                privateKeyPath: nil,
                keyPassphrase: nil
            )
        )
        
        do {
            try await client.downloadToFile(
                remotePath: "/home/\(SFTPClientTests.serverUsername)/upload",
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

}

enum SFTPTestError: Error {
    case serverStartFailed(String)
    case serverNotRunning
    case testTimeOut
}

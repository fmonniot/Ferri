import Foundation
import Logging

public enum FTPClientError: Error {
    case notConnected
    case connectionFailed(String)
}

private let logger = Logger(label: "com.ftpclient.client")

public final class FTPClient: @unchecked Sendable {
    public static let shared = FTPClient()

    private var client: SFTPClient?
    private var currentServer: FTPServer?

    public private(set) var isConnected = false
    public private(set) var currentPath = "/"

    private init() {}

    public func connect(to server: FTPServer) async throws {
        logger.debug("connect(to:) called for \(server.host):\(server.port)")

        self.currentServer = server
        logger.debug("Creating SFTPClient for \(server.host)...")

        client = SFTPClient()

        logger.debug("Starting connection...")
        let credentials = SFTPCredentials(
            username: server.username,
            password: server.password,
            privateKeyPath: server.privateKeyPath,
            keyPassphrase: server.keyPassphrase
        )
        try await client?.connect(host: server.host, port: server.port, credentials: credentials)

        isConnected = true
        logger.debug("Getting current directory...")
        currentPath = await client?.currentDirectory() ?? "/"
        logger.info("Connected! Current path: \(currentPath)")
    }

    public func disconnect() {
        logger.debug("disconnect() called")
        Task {
            try? await client?.disconnect()
        }
        client = nil
        isConnected = false
        currentPath = "/"
    }

    public func listDirectory(at path: String = "") async throws -> [RemoteFile] {
        logger.debug("listDirectory(at: \(path)) called")
        guard isConnected, let client = client else {
            logger.info("Not connected!")
            throw FTPClientError.notConnected
        }

        logger.debug("Calling client.listDirectory...")
        let files = try await client.listDirectory(path: path)
        logger.debug("Got \(files.count) files")
        return files
    }

    public func changeDirectory(to path: String) async throws {
        logger.debug("changeDirectory(to: \(path)) called")
        guard let client = client else { throw FTPClientError.notConnected }
        try await client.changeDirectory(to: path)
        currentPath = await client.currentDirectory()
        logger.info("Changed to: \(currentPath)")
    }

    public func goToParentDirectory() async throws {
        try await changeDirectory(to: "..")
    }

    public func downloadFile(named fileName: String, to localURL: URL) async throws {
        logger.debug("downloadFile(named: \(fileName)) called")
        guard let client = client else { throw FTPClientError.notConnected }

        try await client.downloadToFile(remotePath: fileName, localURL: localURL)
    }

    /// Recursively lists all files (not directories) under the given path.
    /// Returns a flat array of `RemoteFile` with absolute paths.
    public func listDirectoryRecursively(at path: String) async throws -> [RemoteFile] {
        logger.debug("listDirectoryRecursively(at: \(path)) called")
        guard isConnected, let client = client else {
            throw FTPClientError.notConnected
        }

        var result: [RemoteFile] = []
        let entries = try await client.listDirectory(path: path)

        for entry in entries {
            if entry.isDirectory {
                let children = try await listDirectoryRecursively(at: entry.path)
                result.append(contentsOf: children)
            } else {
                result.append(entry)
            }
        }

        return result
    }
}

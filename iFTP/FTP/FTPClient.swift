import Foundation

enum FTPClientError: Error {
    case notConnected
    case connectionFailed(String)
}

final class FTPClient: @unchecked Sendable {
    static let shared = FTPClient()
    
    private var client: SFTPClient?
    private var currentServer: FTPServer?
    
    private(set) var isConnected = false
    private(set) var currentPath = "/"
    
    private init() {}
    
    func connect(to server: FTPServer) async throws {
        print("[FTPClient] connect(to:) called for \(server.host):\(server.port)")
        
        self.currentServer = server
        print("[FTPClient] Creating SFTPClient for \(server.host)...")
        
        client = SFTPClient()
        
        print("[FTPClient] Starting connection...")
        let credentials = SFTPCredentials(
            username: server.username,
            password: server.password,
            privateKeyPath: server.privateKeyPath,
            keyPassphrase: server.keyPassphrase
        )
        try await client?.connect(host: server.host, port: server.port, credentials: credentials)
        
        isConnected = true
        print("[FTPClient] Getting current directory...")
        currentPath = await client?.currentDirectory() ?? "/"
        print("[FTPClient] Connected! Current path: \(currentPath)")
    }
    
    func disconnect() {
        print("[FTPClient] disconnect() called")
        Task {
            try? await client?.disconnect()
        }
        client = nil
        isConnected = false
        currentPath = "/"
    }
    
    func listDirectory(at path: String = "") async throws -> [RemoteFile] {
        print("[FTPClient] listDirectory(at: \(path)) called")
        guard isConnected, let client = client else {
            print("[FTPClient] Not connected!")
            throw FTPClientError.notConnected
        }
        
        print("[FTPClient] Calling client.listDirectory...")
        let files = try await client.listDirectory(path: path)
        print("[FTPClient] Got \(files.count) files")
        return files
    }
    
    func changeDirectory(to path: String) async throws {
        print("[FTPClient] changeDirectory(to: \(path)) called")
        guard let client = client else { throw FTPClientError.notConnected }
        try await client.changeDirectory(to: path)
        currentPath = await client.currentDirectory()
        print("[FTPClient] Changed to: \(currentPath)")
    }
    
    func goToParentDirectory() async throws {
        try await changeDirectory(to: "..")
    }
    
    func createDirectory(named name: String) async throws {
        print("[FTPClient] createDirectory(named: \(name)) called")
        guard let client = client else { throw FTPClientError.notConnected }
        try await client.createDirectory(named: name)
    }
    
    func deleteFile(named name: String) async throws {
        print("[FTPClient] deleteFile(named: \(name)) called")
        guard let client = client else { throw FTPClientError.notConnected }
        try await client.deleteFile(named: name)
    }
    
    func deleteDirectory(named name: String) async throws {
        print("[FTPClient] deleteDirectory(named: \(name)) called")
        guard let client = client else { throw FTPClientError.notConnected }
        try await client.deleteDirectory(named: name)
    }
    
    func rename(from oldName: String, to newName: String) async throws {
        print("[FTPClient] rename(from: \(oldName), to: \(newName)) called")
        guard let client = client else { throw FTPClientError.notConnected }
        try await client.rename(from: oldName, to: newName)
    }
    
    func downloadFile(named fileName: String, to localURL: URL) async throws {
        print("[FTPClient] downloadFile(named: \(fileName)) called")
        guard let client = client else { throw FTPClientError.notConnected }
        
        try await client.downloadToFile(remotePath: fileName, localURL: localURL)
    }
    
    func uploadFile(from localURL: URL, to remotePath: String) async throws {
        print("[FTPClient] uploadFile(from: \(localURL.lastPathComponent)) called")
        guard let client = client else { throw FTPClientError.notConnected }
        
        try await client.upload(localURL: localURL, remotePath: remotePath)
    }
}

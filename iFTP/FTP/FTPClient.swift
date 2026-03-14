import Foundation

enum FTPClientError: Error {
    case notConnected
    case connectionFailed(String)
}

final class FTPClient: @unchecked Sendable {
    static let shared = FTPClient()
    
    private var client: FTPSClient?
    private var currentServer: FTPServer?
    
    private(set) var isConnected = false
    private(set) var currentPath = "/"
    
    private init() {}
    
    func connect(to server: FTPServer) async throws {
        print("[FTPClient] connect(to:) called for \(server.host):\(server.port)")
        guard server.useTLS else {
            throw FTPClientError.connectionFailed("FTPSClient only supports TLS connections. Please enable TLS in the server settings.")
        }
        
        self.currentServer = server
        print("[FTPClient] Creating FTPSClient for \(server.host)...")
        
        client = try FTPSClient(host: server.host)
        
        print("[FTPClient] Starting connection...")
        try await client?.connect(user: server.username, password: server.password)
        
        isConnected = true
        print("[FTPClient] Getting current directory...")
        currentPath = try await client?.currentDirectory() ?? "/"
        print("[FTPClient] Connected! Current path: \(currentPath)")
    }
    
    func disconnect() {
        print("[FTPClient] disconnect() called")
        Task {
            try? await client?.quit()
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
        
        print("[FTPClient] Calling client.list()...")
        let lines = try await client.list(path: path)
        print("[FTPClient] Got \(lines.count) lines from server")
        
        let files = parseDirectoryListing(lines)
        print("[FTPClient] Parsed \(files.count) files")
        return files
    }
    
    func changeDirectory(to path: String) async throws {
        print("[FTPClient] changeDirectory(to: \(path)) called")
        guard let client = client else { throw FTPClientError.notConnected }
        try await client.changeDirectory(to: path)
        currentPath = try await client.currentDirectory()
        print("[FTPClient] Changed to: \(currentPath)")
    }
    
    func goToParentDirectory() async throws {
        try await changeDirectory(to: "..")
    }
    
    func createDirectory(named name: String) async throws {
        print("[FTPClient] createDirectory(named: \(name)) called")
        guard let client = client else { throw FTPClientError.notConnected }
        _ = try await client.createDirectory(named: name)
    }
    
    func deleteFile(named name: String) async throws {
        print("[FTPClient] deleteFile(named: \(name)) called")
        guard let client = client else { throw FTPClientError.notConnected }
        _ = try await client.deleteFile(named: name)
    }
    
    func deleteDirectory(named name: String) async throws {
        print("[FTPClient] deleteDirectory(named: \(name)) called")
        guard let client = client else { throw FTPClientError.notConnected }
        _ = try await client.deleteDirectory(named: name)
    }
    
    func rename(from oldName: String, to newName: String) async throws {
        print("[FTPClient] rename(from: \(oldName), to: \(newName)) called")
        guard let client = client else { throw FTPClientError.notConnected }
        _ = try await client.rename(from: oldName, to: newName)
    }
    
    func downloadFile(named fileName: String, to localURL: URL) async throws {
        print("[FTPClient] downloadFile(named: \(fileName)) called")
        guard let client = client else { throw FTPClientError.notConnected }
        
        let data = try await client.download(remotePath: fileName)
        try data.write(to: localURL)
    }
    
    func uploadFile(from localURL: URL, to remotePath: String) async throws {
        print("[FTPClient] uploadFile(from: \(localURL.lastPathComponent)) called")
        guard let client = client else { throw FTPClientError.notConnected }
        
        let data = try Data(contentsOf: localURL)
        try await client.upload(data: data, remotePath: remotePath)
    }
    
    private func parseDirectoryListing(_ lines: [String]) -> [RemoteFile] {
        var files: [RemoteFile] = []
        
        for line in lines {
            guard !line.isEmpty else { continue }
            
            let components = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard components.count >= 9 else { continue }
            
            let permissions = String(components[0])
            let isDirectory = permissions.hasPrefix("d")
            let size: Int64 = Int64(components[4]) ?? 0
            let name = components[8...].joined(separator: " ")
            
            let path = currentPath.hasSuffix("/") ? currentPath + name : currentPath + "/" + name
            
            files.append(RemoteFile(
                name: name,
                path: path,
                isDirectory: isDirectory,
                size: size,
                modificationDate: nil,
                permissions: permissions
            ))
        }
        
        return files.sorted { file1, file2 in
            if file1.isDirectory != file2.isDirectory {
                return file1.isDirectory
            }
            return file1.name.localizedCaseInsensitiveCompare(file2.name) == .orderedAscending
        }
    }
}

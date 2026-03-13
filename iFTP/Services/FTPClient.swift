import Foundation
import NIOCore
import NIOPosix
import NIOSSL

enum ClientError: Error {
    case notConnected
    case connectionFailed(String)
}

final class FTPClient: @unchecked Sendable {
    static let shared = FTPClient()
    
    private var nioClient: FTPClient2?
    private var currentServer: FTPServer?
    
    private(set) var isConnected = false
    private(set) var currentPath = "/"
    
    private init() {}
    
    func connect(to server: FTPServer) async throws {
        self.currentServer = server
        
        let config: FTPServerConfig
        if server.useTLS {
            config = FTPServerConfig.explicitTLS(host: server.host, port: UInt16(server.port), pinnedCert: nil)
        } else {
            config = FTPServerConfig.plain(host: server.host, port: UInt16(server.port))
        }
        
        nioClient = FTPClient2(config: config)
        
        try await nioClient?.connect()
        try await nioClient?.login(user: server.username, password: server.password)
        
        isConnected = true
        currentPath = try await nioClient?.currentDirectory() ?? "/"
    }
    
    func disconnect() {
        Task {
            try? await nioClient?.quit()
        }
        nioClient = nil
        isConnected = false
        currentPath = "/"
    }
    
    func listDirectory(at path: String = "") async throws -> [RemoteFile] {
        guard isConnected, let client = nioClient else {
            throw ClientError.notConnected
        }
        
        let lines = try await client.list(path: path)
        return parseDirectoryListing(lines)
    }
    
    func changeDirectory(to path: String) async throws {
        guard let client = nioClient else { throw ClientError.notConnected }
        try await client.changeDirectory(to: path)
        currentPath = try await client.currentDirectory()
    }
    
    func goToParentDirectory() async throws {
        try await changeDirectory(to: "..")
    }
    
    func createDirectory(named name: String) async throws {
        guard let client = nioClient else { throw ClientError.notConnected }
        _ = try await client.sendCommand("MKD \(name)")
    }
    
    func deleteFile(named name: String) async throws {
        guard let client = nioClient else { throw ClientError.notConnected }
        _ = try await client.sendCommand("DELE \(name)")
    }
    
    func deleteDirectory(named name: String) async throws {
        guard let client = nioClient else { throw ClientError.notConnected }
        _ = try await client.sendCommand("RMD \(name)")
    }
    
    func rename(from oldName: String, to newName: String) async throws {
        guard let client = nioClient else { throw ClientError.notConnected }
        _ = try await client.sendCommand("RNFR \(oldName)")
        _ = try await client.sendCommand("RNTO \(newName)")
    }
    
    func downloadFile(named fileName: String, to localURL: URL) async throws {
        guard let client = nioClient else { throw ClientError.notConnected }
        
        let data = try await client.download(remotePath: fileName)
        try data.write(to: localURL)
    }
    
    func uploadFile(from localURL: URL, to remotePath: String) async throws {
        guard let client = nioClient else { throw ClientError.notConnected }
        
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

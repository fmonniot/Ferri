import Foundation
import FTPClient

final class ConnectionStorage {
    static let shared = ConnectionStorage()
    
    private let fileManager = FileManager.default
    private var storageURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("iFTP", isDirectory: true)
        
        if !fileManager.fileExists(atPath: appFolder.path) {
            try? fileManager.createDirectory(at: appFolder, withIntermediateDirectories: true)
        }
        
        return appFolder.appendingPathComponent("connections.plist")
    }
    
    private init() {}
    
    func loadConnections() -> [FTPServer] {
        guard fileManager.fileExists(atPath: storageURL.path) else {
            return []
        }
        
        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = PropertyListDecoder()
            return try decoder.decode([FTPServer].self, from: data)
        } catch {
            print("Failed to load connections: \(error)")
            return []
        }
    }
    
    func saveConnections(_ connections: [FTPServer]) {
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            let data = try encoder.encode(connections)
            try data.write(to: storageURL)
        } catch {
            print("Failed to save connections: \(error)")
        }
    }
    
    func addConnection(_ server: FTPServer) {
        var connections = loadConnections()
        connections.append(server)
        saveConnections(connections)
    }
    
    func updateConnection(_ server: FTPServer) {
        var connections = loadConnections()
        if let index = connections.firstIndex(where: { $0.id == server.id }) {
            connections[index] = server
            saveConnections(connections)
        }
    }
    
    func deleteConnection(_ server: FTPServer) {
        var connections = loadConnections()
        connections.removeAll { $0.id == server.id }
        saveConnections(connections)
    }
}

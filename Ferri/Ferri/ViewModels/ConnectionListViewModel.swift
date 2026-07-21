import Foundation
import Combine
import FTPClient

enum ConnectionStatus {
    case disconnected
    case connecting
    case connected
    case error(String)
}

@MainActor
final class ConnectionListViewModel: ObservableObject {
    @Published var connections: [FTPServer] = []
    @Published var selectedConnection: FTPServer?
    @Published var connectionStatus: [UUID: ConnectionStatus] = [:]
    
    private let storage: ConnectionStorage

    init(storage: ConnectionStorage = .shared) {
        self.storage = storage
        loadConnections()
    }
    
    func loadConnections() {
        connections = storage.loadConnections()
        for connection in connections {
            connectionStatus[connection.id] = .disconnected
        }
    }
    
    func addConnection(_ server: FTPServer) {
        storage.addConnection(server)
        connections.append(server)
        connectionStatus[server.id] = .disconnected
        if server.autoConnect {
            clearAutoConnect(except: server.id)
        }
    }
    
    func updateConnection(_ server: FTPServer) {
        storage.updateConnection(server)
        if let index = connections.firstIndex(where: { $0.id == server.id }) {
            connections[index] = server
        }
        if server.autoConnect {
            clearAutoConnect(except: server.id)
        }
    }
    
    func deleteConnection(_ server: FTPServer) {
        storage.deleteConnection(server)
        connections.removeAll { $0.id == server.id }
        connectionStatus.removeValue(forKey: server.id)
    }
    
    func setConnectionStatus(_ status: ConnectionStatus, for connectionId: UUID) {
        connectionStatus[connectionId] = status
    }
    
    func selectConnection(_ connection: FTPServer) {
        selectedConnection = connection
    }
    
    private func clearAutoConnect(except serverID: UUID) {
        for i in connections.indices where connections[i].id != serverID && connections[i].autoConnect {
            connections[i].autoConnect = false
            storage.updateConnection(connections[i])
        }
    }
}

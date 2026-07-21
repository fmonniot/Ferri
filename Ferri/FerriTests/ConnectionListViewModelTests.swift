import Testing
import Foundation
@testable import Ferri
@testable import FTPClient

@MainActor
struct ConnectionListViewModelTests {

    private func makeTempStorage() -> ConnectionStorage {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return ConnectionStorage(baseDirectory: dir)
    }

    private func isDisconnected(_ status: ConnectionStatus?) -> Bool {
        if case .disconnected = status {
            return true
        }
        return false
    }

    @Test
    func initPopulatesConnectionsAndDisconnectedStatus() {
        let storage = makeTempStorage()
        let first = FTPServer(name: "First", host: "a.example.com")
        let second = FTPServer(name: "Second", host: "b.example.com")
        storage.saveConnections([first, second])

        let vm = ConnectionListViewModel(storage: storage)

        #expect(vm.connections.count == 2)
        #expect(vm.connections.contains { $0.id == first.id })
        #expect(vm.connections.contains { $0.id == second.id })
        #expect(isDisconnected(vm.connectionStatus[first.id]))
        #expect(isDisconnected(vm.connectionStatus[second.id]))
    }

    @Test
    func addConnectionAppendsSetsStatusAndPersists() {
        let storage = makeTempStorage()
        let vm = ConnectionListViewModel(storage: storage)
        let server = FTPServer(name: "New", host: "new.example.com")

        vm.addConnection(server)

        #expect(vm.connections.contains { $0.id == server.id })
        #expect(isDisconnected(vm.connectionStatus[server.id]))

        let persisted = storage.loadConnections()
        #expect(persisted.contains { $0.id == server.id })
    }

    @Test
    func updateConnectionUpdatesInMemoryAndPersists() {
        let storage = makeTempStorage()
        let server = FTPServer(name: "Original", host: "orig.example.com")
        storage.saveConnections([server])
        let vm = ConnectionListViewModel(storage: storage)

        var updated = server
        updated.name = "Renamed"
        updated.host = "renamed.example.com"
        vm.updateConnection(updated)

        let inMemory = vm.connections.first { $0.id == server.id }
        #expect(inMemory?.name == "Renamed")
        #expect(inMemory?.host == "renamed.example.com")

        let persisted = storage.loadConnections().first { $0.id == server.id }
        #expect(persisted?.name == "Renamed")
        #expect(persisted?.host == "renamed.example.com")
    }

    @Test
    func deleteConnectionRemovesFromMemoryStatusAndPersists() {
        let storage = makeTempStorage()
        let server = FTPServer(name: "ToDelete", host: "delete.example.com")
        storage.saveConnections([server])
        let vm = ConnectionListViewModel(storage: storage)

        vm.deleteConnection(server)

        #expect(!vm.connections.contains { $0.id == server.id })
        #expect(vm.connectionStatus[server.id] == nil)

        let persisted = storage.loadConnections()
        #expect(!persisted.contains { $0.id == server.id })
    }

    @Test
    func setConnectionStatusUpdatesStatus() {
        let storage = makeTempStorage()
        let server = FTPServer(name: "Server", host: "server.example.com")
        storage.saveConnections([server])
        let vm = ConnectionListViewModel(storage: storage)

        vm.setConnectionStatus(.connected, for: server.id)

        if case .connected = vm.connectionStatus[server.id] {
            // expected
        } else {
            Issue.record("Expected .connected status")
        }
    }

    @Test
    func selectConnectionSetsSelectedConnection() {
        let storage = makeTempStorage()
        let server = FTPServer(name: "Server", host: "server.example.com")
        let vm = ConnectionListViewModel(storage: storage)

        vm.selectConnection(server)

        #expect(vm.selectedConnection?.id == server.id)
    }

    // MARK: - autoConnect exclusivity

    @Test
    func addingAutoConnectServerClearsOthersInMemoryAndPersisted() {
        let storage = makeTempStorage()
        var first = FTPServer(name: "First", host: "a.example.com")
        first.autoConnect = true
        var second = FTPServer(name: "Second", host: "b.example.com")
        second.autoConnect = true
        storage.saveConnections([first, second])
        let vm = ConnectionListViewModel(storage: storage)

        var third = FTPServer(name: "Third", host: "c.example.com")
        third.autoConnect = true
        vm.addConnection(third)

        let firstInMemory = vm.connections.first { $0.id == first.id }
        let secondInMemory = vm.connections.first { $0.id == second.id }
        let thirdInMemory = vm.connections.first { $0.id == third.id }
        #expect(firstInMemory?.autoConnect == false)
        #expect(secondInMemory?.autoConnect == false)
        #expect(thirdInMemory?.autoConnect == true)

        let persisted = storage.loadConnections()
        #expect(persisted.first { $0.id == first.id }?.autoConnect == false)
        #expect(persisted.first { $0.id == second.id }?.autoConnect == false)
        #expect(persisted.first { $0.id == third.id }?.autoConnect == true)
    }

    @Test
    func updatingConnectionToAutoConnectClearsOthers() {
        let storage = makeTempStorage()
        var first = FTPServer(name: "First", host: "a.example.com")
        first.autoConnect = true
        let second = FTPServer(name: "Second", host: "b.example.com")
        storage.saveConnections([first, second])
        let vm = ConnectionListViewModel(storage: storage)

        var updatedSecond = second
        updatedSecond.autoConnect = true
        vm.updateConnection(updatedSecond)

        let firstInMemory = vm.connections.first { $0.id == first.id }
        let secondInMemory = vm.connections.first { $0.id == second.id }
        #expect(firstInMemory?.autoConnect == false)
        #expect(secondInMemory?.autoConnect == true)

        let persisted = storage.loadConnections()
        #expect(persisted.first { $0.id == first.id }?.autoConnect == false)
        #expect(persisted.first { $0.id == second.id }?.autoConnect == true)
    }

    @Test
    func addingNonAutoConnectServerDoesNotClearOthers() {
        let storage = makeTempStorage()
        var first = FTPServer(name: "First", host: "a.example.com")
        first.autoConnect = true
        storage.saveConnections([first])
        let vm = ConnectionListViewModel(storage: storage)

        let second = FTPServer(name: "Second", host: "b.example.com")
        vm.addConnection(second)

        let firstInMemory = vm.connections.first { $0.id == first.id }
        #expect(firstInMemory?.autoConnect == true)
    }

    @Test
    func updatingWithAutoConnectFalseDoesNotClearOthers() {
        let storage = makeTempStorage()
        var first = FTPServer(name: "First", host: "a.example.com")
        first.autoConnect = true
        let second = FTPServer(name: "Second", host: "b.example.com")
        storage.saveConnections([first, second])
        let vm = ConnectionListViewModel(storage: storage)

        var updatedSecond = second
        updatedSecond.name = "Second Renamed"
        updatedSecond.autoConnect = false
        vm.updateConnection(updatedSecond)

        let firstInMemory = vm.connections.first { $0.id == first.id }
        #expect(firstInMemory?.autoConnect == true)
    }
}

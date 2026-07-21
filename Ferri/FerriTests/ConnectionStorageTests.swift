import Testing
import Foundation
@testable import Ferri
@testable import FTPClient

struct ConnectionStorageTests {

    private func makeTempStorage() -> ConnectionStorage {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return ConnectionStorage(baseDirectory: dir)
    }

    @Test
    func loadConnectionsOnFreshDirReturnsEmpty() {
        let storage = makeTempStorage()
        #expect(storage.loadConnections() == [])
    }

    @Test
    func saveThenLoadRoundTripsServers() {
        let storage = makeTempStorage()
        let server = FTPServer(
            id: UUID(),
            name: "My Server",
            host: "example.com",
            port: 2222,
            username: "bob",
            password: "secret",
            initialDirectoryPath: "/home/bob",
            autoConnect: true
        )
        storage.saveConnections([server])

        let loaded = storage.loadConnections()
        #expect(loaded.count == 1)
        let reloaded = loaded[0]
        #expect(reloaded.id == server.id)
        #expect(reloaded.name == server.name)
        #expect(reloaded.host == server.host)
        #expect(reloaded.port == server.port)
        #expect(reloaded.autoConnect == server.autoConnect)
        #expect(reloaded.initialDirectoryPath == server.initialDirectoryPath)
    }

    @Test
    func addConnectionAppendsToPersistedList() {
        let storage = makeTempStorage()
        let first = FTPServer(name: "First", host: "a.example.com")
        let second = FTPServer(name: "Second", host: "b.example.com")

        storage.addConnection(first)
        storage.addConnection(second)

        let loaded = storage.loadConnections()
        #expect(loaded.count == 2)
        #expect(loaded.contains { $0.id == first.id })
        #expect(loaded.contains { $0.id == second.id })
    }

    @Test
    func updateConnectionReplacesMatchingServer() {
        let storage = makeTempStorage()
        let first = FTPServer(name: "First", host: "a.example.com")
        let second = FTPServer(name: "Second", host: "b.example.com")
        storage.saveConnections([first, second])

        var updatedFirst = first
        updatedFirst.name = "Updated First"
        updatedFirst.host = "updated.example.com"
        storage.updateConnection(updatedFirst)

        let loaded = storage.loadConnections()
        #expect(loaded.count == 2)
        let reloadedFirst = loaded.first { $0.id == first.id }
        #expect(reloadedFirst?.name == "Updated First")
        #expect(reloadedFirst?.host == "updated.example.com")
        let reloadedSecond = loaded.first { $0.id == second.id }
        #expect(reloadedSecond?.name == "Second")
        #expect(reloadedSecond?.host == "b.example.com")
    }

    @Test
    func updateConnectionForNonexistentIdIsNoOp() {
        let storage = makeTempStorage()
        let first = FTPServer(name: "First", host: "a.example.com")
        storage.saveConnections([first])

        let unknown = FTPServer(name: "Unknown", host: "unknown.example.com")
        storage.updateConnection(unknown)

        let loaded = storage.loadConnections()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == first.id)
        #expect(loaded[0].name == "First")
    }

    @Test
    func deleteConnectionRemovesMatchingServer() {
        let storage = makeTempStorage()
        let first = FTPServer(name: "First", host: "a.example.com")
        let second = FTPServer(name: "Second", host: "b.example.com")
        storage.saveConnections([first, second])

        storage.deleteConnection(first)

        let loaded = storage.loadConnections()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == second.id)
    }

    @Test
    func deleteConnectionForNonexistentIdLeavesListUnchanged() {
        let storage = makeTempStorage()
        let first = FTPServer(name: "First", host: "a.example.com")
        storage.saveConnections([first])

        let unknown = FTPServer(name: "Unknown", host: "unknown.example.com")
        storage.deleteConnection(unknown)

        let loaded = storage.loadConnections()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == first.id)
    }

    @Test
    func corruptPlistFileYieldsEmptyList() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plistURL = dir.appendingPathComponent("connections.plist")
        try Data("not a valid plist".utf8).write(to: plistURL)

        let storage = ConnectionStorage(baseDirectory: dir)
        #expect(storage.loadConnections() == [])
    }
}

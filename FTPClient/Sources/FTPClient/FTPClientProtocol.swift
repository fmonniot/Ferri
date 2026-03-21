import Foundation

/// Abstraction over FTPClient to allow mock injection for testing.
public protocol FTPClientProtocol: AnyObject, Sendable {
    var isConnected: Bool { get }
    var currentPath: String { get }

    func connect(to server: FTPServer) async throws
    func disconnect()
    func listDirectory(at path: String) async throws -> [RemoteFile]
    func changeDirectory(to path: String) async throws
    func goToParentDirectory() async throws
    func downloadFile(named fileName: String, to localURL: URL) async throws
    func listDirectoryRecursively(at path: String) async throws -> [RemoteFile]
}

#if DEBUG
import Foundation
import FTPClient

/// Launch argument that switches `MainView` onto `UITestMockFTPClient` with a fixed,
/// already-connected directory tree instead of the real sidebar/connect flow. Lets
/// `FerriUITests` drive the file browser deterministically without Docker/a live SFTP server.
enum UITestSupport {
    static let launchArgument = "-UITestMode"

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }
}

/// A fixed, in-memory directory tree standing in for a real SFTP server during UI tests.
final class UITestMockFTPClient: FTPClientProtocol, @unchecked Sendable {
    private(set) var isConnected = true
    private(set) var currentPath = "/"

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private lazy var filesByPath: [String: [RemoteFile]] = [
        "/": [
            RemoteFile(name: "Documents", path: "/Documents", isDirectory: true, modificationDate: fixedDate, permissions: "drwxr-xr-x"),
            RemoteFile(name: "Photos", path: "/Photos", isDirectory: true, modificationDate: fixedDate, permissions: "drwxr-xr-x"),
            RemoteFile(name: "readme.txt", path: "/readme.txt", isDirectory: false, size: 128, modificationDate: fixedDate, permissions: "-rw-r--r--"),
        ],
        "/Documents": [
            RemoteFile(name: "notes.txt", path: "/Documents/notes.txt", isDirectory: false, size: 64, modificationDate: fixedDate, permissions: "-rw-r--r--"),
        ],
        "/Photos": [],
    ]

    func connect(to server: FTPServer) async throws {
        isConnected = true
        currentPath = "/"
    }

    func disconnect() {
        isConnected = false
    }

    func listDirectory(at path: String) async throws -> [RemoteFile] {
        currentPath = resolvePath(path)
        return filesByPath[currentPath] ?? []
    }

    func changeDirectory(to path: String) async throws {
        currentPath = resolvePath(path)
    }

    func goToParentDirectory() async throws {
        try await changeDirectory(to: "..")
    }

    func downloadFile(named fileName: String, to localURL: URL, resumeOffset: Int64, progress: (@Sendable (Int64, Int64?) -> Void)?) async throws {
        try Data().write(to: localURL)
    }

    func listDirectoryRecursively(at path: String) async throws -> [RemoteFile] {
        try await listDirectory(at: path)
    }

    private func resolvePath(_ path: String) -> String {
        if path.isEmpty { return currentPath }
        if path.hasPrefix("/") { return path }
        if path == "." { return currentPath }
        if path == ".." {
            if currentPath == "/" { return "/" }
            let trimmed = (currentPath as NSString).deletingLastPathComponent
            return trimmed.isEmpty ? "/" : trimmed
        }
        return currentPath.hasSuffix("/") ? currentPath + path : currentPath + "/" + path
    }
}
#endif

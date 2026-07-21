#if DEBUG
import Foundation
import FTPClient

/// Launch argument that switches `MainView` onto `UITestMockFTPClient` with a fixed,
/// already-connected directory tree instead of the real sidebar/connect flow. Lets
/// `FerriUITests` drive the file browser deterministically without Docker/a live SFTP server.
enum UITestSupport {
    static let launchArgument = "-UITestMode"
    /// Additional launch argument that makes `MainView` route the initial listing through
    /// `FileBrowserViewModel.loadInitialDirectory(at:)` against a path `UITestMockFTPClient`
    /// is rigged to fail, exercising the same fallback-to-root + dismissible warning banner
    /// a real misconfigured `FTPServer.initialDirectoryPath` triggers.
    static let badInitialDirectoryLaunchArgument = "-UITestModeBadInitialDirectory"

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument) || isBadInitialDirectoryActive
    }

    static var isBadInitialDirectoryActive: Bool {
        ProcessInfo.processInfo.arguments.contains(badInitialDirectoryLaunchArgument)
    }
}

/// Posted by `FilePromiseDragSourceView.handlePan` when it actually reaches
/// `beginDraggingSession` (see `handlePan`). A UI test can't drive a real Finder drop, but
/// recognizing-and-starting the drag is exactly the step that has regressed twice now, so
/// `MainView` surfaces it (behind `-UITestMode`) as a hidden, accessibility-identified `Text`
/// that `FerriUITests` reads - cross-process file/temp-dir marker reads proved unreliable
/// under the XCUITest runner, so this stays in-process instead.
extension Notification.Name {
    static let uiTestDragSessionStarted = Notification.Name("uiTestDragSessionStarted")
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

    /// Fixed path `-UITestModeBadInitialDirectory` points `initialDirectoryPath` at, standing in
    /// for a real server's misconfigured/removed folder - deliberately outside `filesByPath` so
    /// this always throws.
    static let missingPath = "/DoesNotExist"

    func listDirectory(at path: String) async throws -> [RemoteFile] {
        let resolved = resolvePath(path)
        if resolved == Self.missingPath {
            // Only set currentPath on success, mirroring the real SFTPClient, so a failed
            // lookup doesn't strand `currentPath` on a path that was never actually loaded.
            throw SFTPClientError.requestFailed(3, "Permission denied")
        }
        currentPath = resolved
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

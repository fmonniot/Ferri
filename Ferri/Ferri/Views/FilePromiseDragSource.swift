import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FTPClient
import Logging

private let logger = Logger(label: "com.ferri.drag-source")

// MARK: - UserInfo carried by each NSFilePromiseProvider

/// For single-file drags, holds the RemoteFile.
/// For directory drags, holds the RemoteFile (the directory itself).
/// The delegate checks `remoteFile.isDirectory` to decide which download path to take.
struct FilePromiseInfo {
    let remoteFile: RemoteFile
}

// MARK: - NSFilePromiseProvider bridge for dragging remote files to Finder

/// An NSView that acts as a drag source for remote files and directories using
/// NSFilePromiseProvider. Files are promised individually; directories are promised
/// as a single folder and recursively downloaded on fulfillment.
class FilePromiseDragSourceView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {

    var remoteFile: RemoteFile?
    var ftpClient: any FTPClientProtocol = FTPClient.shared

    private lazy var filePromiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.ferri.file-promise"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    // MARK: - Init

    /// Drag-out is driven entirely by this gesture recognizer instead of overriding
    /// mouseDown/mouseDragged/mouseUp directly. Overriding those methods meant every click
    /// on this overlay had to be manually re-forwarded to the table underneath for selection
    /// and double-click to keep working, which desynced from AppKit's own click/double-click
    /// tracking (duplicate/extended selection) and starved mouseDragged of events once the
    /// table's own tracking loop took over. `delaysPrimaryMouseButtonEvents = false` lets
    /// clicks reach the table natively; this recognizer only intercepts once an actual pan
    /// gesture is recognized.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let panRecognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panRecognizer.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(panRecognizer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Drag gesture

    @objc private func handlePan(_ recognizer: NSPanGestureRecognizer) {
        guard recognizer.state == .began,
              let file = remoteFile,
              let event = NSApp.currentEvent else { return }

        let fileType = file.isDirectory ? UTType.folder.identifier : UTType.data.identifier
        logger.info("Starting drag for \(file.isDirectory ? "directory" : "file"): \(file.path)")

        let provider = NSFilePromiseProvider(fileType: fileType, delegate: self)
        provider.userInfo = FilePromiseInfo(remoteFile: file)

        let draggingItem = NSDraggingItem(pasteboardWriter: provider)
        draggingItem.setDraggingFrame(bounds, contents: dragPreviewImage(for: file))

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .outsideApplication ? .copy : []
    }

    // MARK: - NSFilePromiseProviderDelegate

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        guard let info = filePromiseProvider.userInfo as? FilePromiseInfo else { return "unknown" }
        return info.remoteFile.name
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        return filePromiseQueue
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let info = filePromiseProvider.userInfo as? FilePromiseInfo else {
            completionHandler(FTPClientError.notConnected)
            return
        }

        let file = info.remoteFile
        logger.info("Fulfilling promise for \(file.isDirectory ? "directory" : "file"): \(file.path) -> \(url.path)")

        Task {
            do {
                if file.isDirectory {
                    try await downloadDirectoryRecursively(remotePath: file.path, to: url)
                } else {
                    try await ftpClient.downloadFile(named: file.path, to: url)
                }
                logger.info("Promise fulfilled successfully: \(file.name)")
                completionHandler(nil)
            } catch {
                logger.error("Promise failed for \(file.name): \(error)")
                completionHandler(error)
            }
        }
    }

    // MARK: - Recursive directory download

    /// Downloads an entire remote directory tree to a local URL, preserving structure.
    /// Each file is downloaded independently and streams to disk as bytes arrive.
    private func downloadDirectoryRecursively(remotePath: String, to localURL: URL) async throws {
        logger.debug("Creating local directory: \(localURL.path)")
        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)

        let entries = try await ftpClient.listDirectory(at: remotePath)
        logger.info("Listed \(entries.count) entries in \(remotePath)")

        for entry in entries {
            let childURL = localURL.appendingPathComponent(entry.name)
            if entry.isDirectory {
                try await downloadDirectoryRecursively(remotePath: entry.path, to: childURL)
            } else {
                logger.debug("Downloading file: \(entry.path) -> \(childURL.path)")
                try await ftpClient.downloadFile(named: entry.path, to: childURL)
                logger.debug("Downloaded: \(entry.name)")
            }
        }
    }

    // MARK: - Drag preview

    private func dragPreviewImage(for file: RemoteFile) -> NSImage {
        let icon: NSImage
        if file.isDirectory {
            icon = NSWorkspace.shared.icon(for: .folder)
        } else {
            icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data)
        }
        icon.size = NSSize(width: 32, height: 32)
        return icon
    }
}

// MARK: - SwiftUI bridge

struct FilePromiseDragSource: NSViewRepresentable {
    let file: RemoteFile
    var ftpClient: any FTPClientProtocol = FTPClient.shared

    func makeNSView(context: Context) -> FilePromiseDragSourceView {
        let view = FilePromiseDragSourceView()
        view.remoteFile = file
        view.ftpClient = ftpClient
        return view
    }

    func updateNSView(_ nsView: FilePromiseDragSourceView, context: Context) {
        nsView.remoteFile = file
        nsView.ftpClient = ftpClient
    }
}

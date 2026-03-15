import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FTPClient

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

    private var dragOrigin: NSPoint?
    private static let dragThreshold: CGFloat = 3.0

    private lazy var filePromiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.ferri.file-promise"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    // MARK: - Mouse handling

    override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let file = remoteFile else {
            super.mouseDragged(with: event)
            return
        }

        let current = convert(event.locationInWindow, from: nil)
        let dx = current.x - origin.x
        let dy = current.y - origin.y
        let distance = sqrt(dx * dx + dy * dy)

        guard distance >= Self.dragThreshold else { return }

        // Reset so we don't start multiple drags
        dragOrigin = nil

        let fileType = file.isDirectory ? UTType.folder.identifier : UTType.data.identifier
        let provider = NSFilePromiseProvider(fileType: fileType, delegate: self)
        provider.userInfo = FilePromiseInfo(remoteFile: file)

        let draggingItem = NSDraggingItem(pasteboardWriter: provider)
        draggingItem.setDraggingFrame(bounds, contents: dragPreviewImage(for: file))

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        // Forward the click so table selection still works
        super.mouseUp(with: event)
        nextResponder?.mouseUp(with: event)
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

        Task {
            do {
                if file.isDirectory {
                    try await downloadDirectoryRecursively(remotePath: file.path, to: url)
                } else {
                    try await FTPClient.shared.downloadFile(named: file.path, to: url)
                }
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    // MARK: - Recursive directory download

    /// Downloads an entire remote directory tree to a local URL, preserving structure.
    /// Each file is downloaded independently and streams to disk as bytes arrive.
    private func downloadDirectoryRecursively(remotePath: String, to localURL: URL) async throws {
        // Create the local directory
        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)

        // List immediate children
        let entries = try await FTPClient.shared.listDirectory(at: remotePath)

        // Download each entry — files directly, directories recursively
        for entry in entries {
            let childURL = localURL.appendingPathComponent(entry.name)
            if entry.isDirectory {
                try await downloadDirectoryRecursively(remotePath: entry.path, to: childURL)
            } else {
                try await FTPClient.shared.downloadFile(named: entry.path, to: childURL)
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

    // MARK: - Hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard remoteFile != nil else { return nil }
        return super.hitTest(point)
    }
}

// MARK: - SwiftUI bridge

struct FilePromiseDragSource: NSViewRepresentable {
    let file: RemoteFile

    func makeNSView(context: Context) -> FilePromiseDragSourceView {
        let view = FilePromiseDragSourceView()
        view.remoteFile = file
        return view
    }

    func updateNSView(_ nsView: FilePromiseDragSourceView, context: Context) {
        nsView.remoteFile = file
    }
}

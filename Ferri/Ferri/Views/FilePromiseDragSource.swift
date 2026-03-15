import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FTPClient

// MARK: - UserInfo keys for file promise providers

/// Stored in NSFilePromiseProvider.userInfo to carry the remote file and its
/// relative path (used for directory tree downloads).
struct FilePromiseInfo {
    let remoteFile: RemoteFile
    /// For single files this is just the filename. For files inside a dragged
    /// directory this is a relative path like "folder/sub/file.txt".
    let relativePath: String
}

// MARK: - NSFilePromiseProvider bridge for dragging remote files to Finder

/// An NSView that acts as a drag source for remote files using NSFilePromiseProvider.
/// Supports both individual files and directories (which are recursively listed
/// and turned into one promise per file).
class FilePromiseDragSourceView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {

    var remoteFile: RemoteFile?

    private var dragOrigin: NSPoint?
    private var pendingDragEvent: NSEvent?
    private var listingTask: Task<Void, Never>?
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

        if file.isDirectory {
            beginDirectoryDrag(file: file, event: event)
        } else {
            beginFileDrag(file: file, event: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        listingTask?.cancel()
        listingTask = nil
        // Forward the click so table selection still works
        super.mouseUp(with: event)
        nextResponder?.mouseUp(with: event)
    }

    // MARK: - Single file drag

    private func beginFileDrag(file: RemoteFile, event: NSEvent) {
        let info = FilePromiseInfo(remoteFile: file, relativePath: file.name)
        let provider = NSFilePromiseProvider(fileType: UTType.data.identifier, delegate: self)
        provider.userInfo = info

        let draggingItem = NSDraggingItem(pasteboardWriter: provider)
        draggingItem.setDraggingFrame(bounds, contents: dragPreviewImage(for: file))

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    // MARK: - Directory drag

    private func beginDirectoryDrag(file: RemoteFile, event: NSEvent) {
        // Store the event — we need it to start the drag session after listing completes
        pendingDragEvent = event

        listingTask = Task { [weak self] in
            guard let self else { return }

            do {
                let files = try await FTPClient.shared.listDirectoryRecursively(at: file.path)

                // Compute the prefix to strip: the parent directory of the dragged folder.
                // e.g. if dragging "/home/user/projects", prefix is "/home/user/"
                // so "projects/src/main.swift" becomes the relative path.
                let parentPath: String
                if let lastSlash = file.path.lastIndex(of: "/") {
                    parentPath = String(file.path[...lastSlash])
                } else {
                    parentPath = ""
                }

                guard !Task.isCancelled else { return }

                var draggingItems: [NSDraggingItem] = []

                for childFile in files {
                    let relativePath: String
                    if childFile.path.hasPrefix(parentPath) {
                        relativePath = String(childFile.path.dropFirst(parentPath.count))
                    } else {
                        relativePath = childFile.name
                    }

                    let info = FilePromiseInfo(remoteFile: childFile, relativePath: relativePath)
                    let provider = NSFilePromiseProvider(fileType: UTType.data.identifier, delegate: self)
                    provider.userInfo = info

                    let item = NSDraggingItem(pasteboardWriter: provider)
                    item.setDraggingFrame(self.bounds, contents: self.dragPreviewImage(for: file))
                    draggingItems.append(item)
                }

                guard !draggingItems.isEmpty, !Task.isCancelled,
                      let event = self.pendingDragEvent else { return }

                await MainActor.run {
                    self.beginDraggingSession(with: draggingItems, event: event, source: self)
                    self.pendingDragEvent = nil
                }
            } catch {
                // Listing failed — silently abandon the drag
                await MainActor.run {
                    self.pendingDragEvent = nil
                }
            }
        }
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .outsideApplication ? .copy : []
    }

    // MARK: - NSFilePromiseProviderDelegate

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        guard let info = filePromiseProvider.userInfo as? FilePromiseInfo else { return "unknown" }
        return info.relativePath
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        return filePromiseQueue
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let info = filePromiseProvider.userInfo as? FilePromiseInfo else {
            completionHandler(FTPClientError.notConnected)
            return
        }

        Task {
            do {
                // Ensure parent directories exist (needed for files inside dragged directories)
                let parentDir = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

                try await FTPClient.shared.downloadFile(named: info.remoteFile.path, to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
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

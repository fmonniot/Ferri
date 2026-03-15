import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FTPClient

// MARK: - NSFilePromiseProvider bridge for dragging remote files to Finder

/// An NSView that acts as a drag source for a remote file using NSFilePromiseProvider.
/// When the user drags this view, it creates a file promise that downloads the remote
/// file directly to the Finder-provided destination.
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
        // Don't call super — let the drag threshold decide whether to pass through
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let file = remoteFile, !file.isDirectory else {
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

        let provider = NSFilePromiseProvider(fileType: UTType.data.identifier, delegate: self)
        provider.userInfo = file

        let draggingItem = NSDraggingItem(pasteboardWriter: provider)
        draggingItem.setDraggingFrame(bounds, contents: dragPreviewImage(for: file))

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        // Forward the click to the next responder so table selection still works
        super.mouseUp(with: event)
        nextResponder?.mouseUp(with: event)
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .outsideApplication ? .copy : []
    }

    // MARK: - NSFilePromiseProviderDelegate

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        guard let file = filePromiseProvider.userInfo as? RemoteFile else { return "unknown" }
        return file.name
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        return filePromiseQueue
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let file = filePromiseProvider.userInfo as? RemoteFile else {
            completionHandler(FTPClientError.notConnected)
            return
        }

        // Bridge async download into the OperationQueue callback
        Task {
            do {
                try await FTPClient.shared.downloadFile(named: file.path, to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    // MARK: - Drag preview

    private func dragPreviewImage(for file: RemoteFile) -> NSImage {
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data)
        icon.size = NSSize(width: 32, height: 32)
        return icon
    }

    // MARK: - Hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only intercept if we have a non-directory file
        guard let file = remoteFile, !file.isDirectory else { return nil }
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

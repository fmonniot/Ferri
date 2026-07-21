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

// MARK: - Aggregate byte count for a directory drag

/// Folds the per-file download callbacks of one directory drag into the single `Progress`
/// backing Finder's badge for the whole tree, by carrying the bytes of already-finished
/// files across the recursion.
@MainActor
private final class TreeProgress {
    private let progress: Progress
    private var finishedBytes: Int64 = 0

    init(progress: Progress) {
        self.progress = progress
    }

    /// The in-flight file's running byte count, on top of everything already finished.
    func update(currentFileBytes: Int64) {
        progress.completedUnitCount = finishedBytes + currentFileBytes
    }

    /// Banks a finished file so the next one accumulates from here. Uses the listed size
    /// rather than the last callback value, which may lag the final write.
    func finish(fileBytes: Int64) {
        finishedBytes += fileBytes
        progress.completedUnitCount = finishedBytes
    }
}

// MARK: - NSFilePromiseProvider bridge for dragging remote files to Finder

/// An NSView that acts as a drag source for remote files and directories using
/// NSFilePromiseProvider. Files are promised individually; directories are promised
/// as a single folder and recursively downloaded on fulfillment.
class FilePromiseDragSourceView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {

    var remoteFile: RemoteFile?

    /// The full current table selection, resolved to `RemoteFile`s. When the grabbed row is part
    /// of a multi-item selection, the drag promises every selected item rather than just the one
    /// under the cursor — the drag equivalent of the context menu's "Download N Items". Empty (or
    /// not containing `remoteFile`) means a plain single-item drag.
    var selectedFiles: [RemoteFile] = []

    var ftpClient: any FTPClientProtocol = FTPClient.shared

    /// The queue that owns and displays the downloads this drag kicks off. Without it the
    /// promise still downloads, just untracked — so it stays optional for previews.
    weak var transferQueue: TransferQueueViewModel?

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
    /// tracking (duplicate/extended selection).
    ///
    /// `delaysPrimaryMouseButtonEvents` is left at its default (`true`): the recognizer must
    /// get first look at mouseDown/mouseDragged so it can decide whether this is a pan *before*
    /// the table's own mouseDown starts its blocking selection-tracking loop - once that loop
    /// starts it pulls subsequent events straight off the event queue itself, so a recognizer
    /// that let events through immediately (`false`) would never see enough of the drag to
    /// recognize it. If the recognizer fails to recognize a pan (a plain click), AppKit replays
    /// the buffered mouseDown/mouseUp to the table so click/double-click still work natively.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let panRecognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
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

        let files = FilePromiseDragPlanning.filesToDrag(startingFrom: file, selectedFiles: selectedFiles)
        logger.info("Starting drag for \(files.count) item(s): \(files.map(\.path).joined(separator: ", "))")

        #if DEBUG
        if UITestSupport.isActive {
            NotificationCenter.default.post(
                name: .uiTestDragSessionStarted,
                object: nil,
                userInfo: ["file": files.map(\.name).joined(separator: ", ")]
            )
        }
        #endif

        // One promise provider per dragged item; the delegate methods dispatch per-provider off
        // each provider's `userInfo`, so a mixed file/directory selection fulfills correctly. The
        // frames are fanned out slightly so a multi-item drag reads as a stack rather than a
        // single overlapping icon.
        let draggingItems = files.enumerated().map { index, file -> NSDraggingItem in
            let fileType = FilePromiseDragPlanning.fileType(for: file)
            let provider = NSFilePromiseProvider(fileType: fileType, delegate: self)
            provider.userInfo = FilePromiseInfo(remoteFile: file)

            let item = NSDraggingItem(pasteboardWriter: provider)
            let frame = FilePromiseDragPlanning.draggingFrame(bounds: bounds, index: index)
            item.setDraggingFrame(frame, contents: dragPreviewImage(for: file))
            return item
        }

        beginDraggingSession(with: draggingItems, event: event, source: self)
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
        logger.info("Fulfilling promise for \(file.isDirectory ? "directory" : "file"): \(file.path) (\(file.size) bytes) -> \(url.path)")

        // AppKit calls this on `filePromiseQueue`, but the progress is published and driven on
        // the main thread: publishing hands the object to other processes over the main
        // run loop, and the byte updates arrive on the main actor from the transfer queue.
        Task { @MainActor in
            let progress = publishFinderProgress(for: file, destination: url)
            do {
                if file.isDirectory {
                    try await downloadDirectory(file, to: url, progress: progress)
                } else {
                    try await RemoteDownloader.downloadFile(file, to: url, ftpClient: ftpClient, transferQueue: transferQueue) {
                        progress.completedUnitCount = $0
                    }
                }
                progress.completedUnitCount = progress.totalUnitCount
                progress.unpublish()
                logger.info("Promise fulfilled successfully: \(file.name)")
                completionHandler(nil)
            } catch {
                progress.unpublish()
                logger.error("Promise failed for \(file.name): \(error)")
                completionHandler(error)
            }
        }
    }

    // MARK: - Download

    /// Creates the destination and publishes the `NSProgress` that drives Finder's download
    /// badge on it. The caller owns the matching `unpublish()`.
    ///
    /// The destination is created *before* publishing on purpose: Finder attaches a published
    /// progress to a file it can already see, and it doesn't retry once the file shows up
    /// later. Publishing first left the drop looking like a plain, badge-less file for the
    /// whole download. The empty placeholder is harmless — a fresh `downloadToFile` calls
    /// `createFile` over it, and the resume path only ever runs against a partial file.
    private func publishFinderProgress(for file: RemoteFile, destination url: URL) -> Progress {
        if file.isDirectory {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        // A directory's total byte count isn't known up front (that would need a recursive
        // listing pass before the first byte lands), so `totalUnitCount` stays 0 —
        // indeterminate — rather than a fake number that would never reach completion.
        let progress = Progress(totalUnitCount: file.isDirectory ? 0 : file.size)
        progress.kind = .file
        progress.fileOperationKind = .downloading
        progress.fileURL = url
        progress.isPausable = false
        progress.isCancellable = false
        progress.publish()
        return progress
    }

    // MARK: - Recursive directory download

    /// Downloads a directory tree, driving Finder's badge from a byte total discovered by a
    /// recursive listing that runs *alongside* the download rather than before it: the drop
    /// isn't held up waiting on the listing, and the badge upgrades from indeterminate to a
    /// real pie once the total lands. Sizing failure is deliberately non-fatal — it only
    /// costs the badge its total, so it must not take the download down with it.
    ///
    /// The transfer queue gets one aggregate row for the whole tree (`TransferGroup`) rather
    /// than one row per file — the same sizing pass feeds both the Finder badge's total and
    /// the group row's total.
    private func downloadDirectory(_ file: RemoteFile, to localURL: URL, progress: Progress) async throws {
        let groupID = transferQueue?.startGroup(name: file.name)

        let sizing = Task { @MainActor in
            guard let files = try? await ftpClient.listDirectoryRecursively(at: file.path) else {
                logger.debug("Sizing pass failed for \(file.path); badge stays indeterminate")
                return
            }
            let total = files.reduce(Int64(0)) { $0 + $1.size }
            logger.info("Sized \(file.path): \(files.count) files, \(total) bytes")
            progress.totalUnitCount = total
            if let groupID {
                transferQueue?.addToGroupTotalBytes(id: groupID, bytes: total)
            }
        }
        defer { sizing.cancel() }

        let tree = TreeProgress(progress: progress)
        try await RemoteDownloader.downloadTree(
            remotePath: file.path,
            to: localURL,
            groupID: groupID,
            ftpClient: ftpClient,
            transferQueue: transferQueue,
            onFileBytes: { tree.update(currentFileBytes: $0) },
            onFileFinished: { tree.finish(fileBytes: $0.size) }
        )

        // An empty directory never downloads a file to hang the group row's aggregate off of;
        // drop it rather than leaving an invisible, un-removable entry in the queue's bookkeeping.
        if let groupID {
            transferQueue?.removeGroupIfEmpty(id: groupID)
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
    /// The whole current table selection; lets a drag begun on a selected row promise every
    /// selected item. Defaults to empty for the single-item callers (e.g. previews).
    var selectedFiles: [RemoteFile] = []
    var transferQueue: TransferQueueViewModel?
    var ftpClient: any FTPClientProtocol = FTPClient.shared

    func makeNSView(context: Context) -> FilePromiseDragSourceView {
        let view = FilePromiseDragSourceView()
        view.remoteFile = file
        view.selectedFiles = selectedFiles
        view.ftpClient = ftpClient
        view.transferQueue = transferQueue
        return view
    }

    func updateNSView(_ nsView: FilePromiseDragSourceView, context: Context) {
        nsView.remoteFile = file
        nsView.selectedFiles = selectedFiles
        nsView.ftpClient = ftpClient
        nsView.transferQueue = transferQueue
    }
}

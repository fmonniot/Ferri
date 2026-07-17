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

        let fileType = file.isDirectory ? UTType.folder.identifier : UTType.data.identifier
        logger.info("Starting drag for \(file.isDirectory ? "directory" : "file"): \(file.path)")

        #if DEBUG
        if UITestSupport.isActive {
            NotificationCenter.default.post(name: .uiTestDragSessionStarted, object: nil, userInfo: ["file": file.name])
        }
        #endif

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
                    try await download(file, to: url) { progress.completedUnitCount = $0 }
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

    /// Downloads one file as a row in the transfer queue, so a drag to Finder shows the same
    /// progress, speed and pause/cancel controls as a download started from the app's own UI.
    /// Falls back to an untracked download when no queue is attached. `onBytes` receives the
    /// running byte count so the caller can drive Finder's badge.
    private func download(_ file: RemoteFile, to localURL: URL, onBytes: ((Int64) -> Void)? = nil) async throws {
        guard let transferQueue else {
            try await ftpClient.downloadFile(named: file.path, to: localURL) { bytesTransferred, _ in
                onBytes?(bytesTransferred)
            }
            return
        }
        try await transferQueue.downloadAndWait(file: file, to: localURL) { bytesTransferred in
            onBytes?(bytesTransferred)
        }
    }

    // MARK: - Recursive directory download

    /// Downloads a directory tree, driving Finder's badge from a byte total discovered by a
    /// recursive listing that runs *alongside* the download rather than before it: the drop
    /// isn't held up waiting on the listing, and the badge upgrades from indeterminate to a
    /// real pie once the total lands. Sizing failure is deliberately non-fatal — it only
    /// costs the badge its total, so it must not take the download down with it.
    private func downloadDirectory(_ file: RemoteFile, to localURL: URL, progress: Progress) async throws {
        let sizing = Task { @MainActor in
            guard let files = try? await ftpClient.listDirectoryRecursively(at: file.path) else {
                logger.debug("Sizing pass failed for \(file.path); badge stays indeterminate")
                return
            }
            let total = files.reduce(Int64(0)) { $0 + $1.size }
            logger.info("Sized \(file.path): \(files.count) files, \(total) bytes")
            progress.totalUnitCount = total
        }
        defer { sizing.cancel() }

        try await downloadDirectoryRecursively(
            remotePath: file.path,
            to: localURL,
            tree: TreeProgress(progress: progress)
        )
    }

    /// Downloads an entire remote directory tree to a local URL, preserving structure.
    /// Each file is downloaded independently and streams to disk as bytes arrive.
    private func downloadDirectoryRecursively(remotePath: String, to localURL: URL, tree: TreeProgress?) async throws {
        logger.debug("Creating local directory: \(localURL.path)")
        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)

        let entries = try await ftpClient.listDirectory(at: remotePath)
        logger.info("Listed \(entries.count) entries in \(remotePath)")

        for entry in entries {
            let childURL = localURL.appendingPathComponent(entry.name)
            if entry.isDirectory {
                try await downloadDirectoryRecursively(remotePath: entry.path, to: childURL, tree: tree)
            } else {
                logger.debug("Downloading file: \(entry.path) -> \(childURL.path)")
                // One queue row per file rather than one for the whole tree: the transfer
                // rows are sized and driven per file, and a listing gives no total up front.
                try await download(entry, to: childURL) { tree?.update(currentFileBytes: $0) }
                tree?.finish(fileBytes: entry.size)
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
    var transferQueue: TransferQueueViewModel?
    var ftpClient: any FTPClientProtocol = FTPClient.shared

    func makeNSView(context: Context) -> FilePromiseDragSourceView {
        let view = FilePromiseDragSourceView()
        view.remoteFile = file
        view.ftpClient = ftpClient
        view.transferQueue = transferQueue
        return view
    }

    func updateNSView(_ nsView: FilePromiseDragSourceView, context: Context) {
        nsView.remoteFile = file
        nsView.ftpClient = ftpClient
        nsView.transferQueue = transferQueue
    }
}

import Foundation
import FTPClient

/// Recursive remote-download logic shared by the drag-to-Finder file-promise path
/// (`FilePromiseDragSourceView`) and the file browser's "Download" context-menu action
/// (`FileBrowserViewModel.downloadFiles`) — the two places a file or directory tree gets
/// downloaded to a chosen local destination.
@MainActor
enum RemoteDownloader {
    /// Downloads one file as a row in the transfer queue, tagged with `groupID` when it's part
    /// of a directory tree or multi-item download so it rolls up under one aggregate row instead
    /// of listing on its own. Falls back to an untracked download when no queue is attached (e.g.
    /// SwiftUI previews). `onBytes` receives the running byte count for callers that mirror it
    /// onto something else (Finder's `NSProgress` badge).
    static func downloadFile(
        _ file: RemoteFile,
        to localURL: URL,
        groupID: UUID? = nil,
        ftpClient: any FTPClientProtocol,
        transferQueue: TransferQueueViewModel?,
        onBytes: ((Int64) -> Void)? = nil
    ) async throws {
        guard let transferQueue else {
            try await ftpClient.downloadFile(named: file.path, to: localURL) { bytesTransferred, _ in
                onBytes?(bytesTransferred)
            }
            return
        }
        try await transferQueue.downloadAndWait(file: file, to: localURL, groupID: groupID) { bytesTransferred in
            onBytes?(bytesTransferred)
        }
    }

    /// Downloads an entire remote directory tree to a local URL, preserving structure. Each file
    /// downloads independently (via `downloadFile`) and streams to disk as bytes arrive.
    /// `onFileBytes` mirrors the in-flight file's running byte count and `onFileFinished` reports
    /// each file once it lands — both exist only for the Finder file-promise path, which folds
    /// them into the single `NSProgress` behind its download badge.
    static func downloadTree(
        remotePath: String,
        to localURL: URL,
        groupID: UUID?,
        ftpClient: any FTPClientProtocol,
        transferQueue: TransferQueueViewModel?,
        onFileBytes: ((Int64) -> Void)? = nil,
        onFileFinished: ((RemoteFile) -> Void)? = nil
    ) async throws {
        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)

        let entries = try await ftpClient.listDirectory(at: remotePath)
        for entry in entries {
            let childURL = localURL.appendingPathComponent(entry.name)
            if entry.isDirectory {
                try await downloadTree(
                    remotePath: entry.path,
                    to: childURL,
                    groupID: groupID,
                    ftpClient: ftpClient,
                    transferQueue: transferQueue,
                    onFileBytes: onFileBytes,
                    onFileFinished: onFileFinished
                )
            } else {
                try await downloadFile(entry, to: childURL, groupID: groupID, ftpClient: ftpClient, transferQueue: transferQueue, onBytes: onFileBytes)
                onFileFinished?(entry)
            }
        }
    }
}

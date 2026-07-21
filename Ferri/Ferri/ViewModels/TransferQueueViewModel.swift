import Foundation
import Combine
import FTPClient

@MainActor
final class TransferQueueViewModel: ObservableObject {
    @Published var transfers: [TransferItem] = []
    @Published var showCompleted = true
    @Published private(set) var groups: [UUID: TransferGroup] = [:]

    /// Top-level rows in display order — either a standalone file's id or a group's id.
    /// A file that belongs to a group is never listed here; it's only reached through the
    /// group's row (see `rows`).
    private var topLevelOrder: [UUID] = []

    private let ftpClient: any FTPClientProtocol

    /// Why a running download was asked to stop, so the task's `CancellationError`
    /// catch can resolve to `.paused` vs `.cancelled` instead of `.failed`.
    private enum StopReason { case pause, cancel }

    /// The in-flight download task per transfer id — the handle we cancel to interrupt.
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var stopReasons: [UUID: StopReason] = [:]

    /// Callers of `downloadAndWait(file:to:)` parked until their transfer reaches a terminal
    /// state. A pause isn't terminal, so a paused-then-resumed transfer keeps them waiting.
    private var completionWaiters: [UUID: [CheckedContinuation<Void, Error>]] = [:]

    /// Optional per-transfer byte-progress callback for `downloadAndWait(file:to:progress:)`
    /// callers (the Finder file-promise path) that need updates outside the published queue.
    private var progressHandlers: [UUID: (Int64) -> Void] = [:]

    init(ftpClient: any FTPClientProtocol = FTPClient.shared) {
        self.ftpClient = ftpClient
    }

    /// The queue as displayed: standalone file rows interleaved with one aggregate row per
    /// directory-drag group, in the order each was first added.
    var rows: [TransferQueueRow] {
        topLevelOrder.compactMap { id in
            if let group = groups[id] {
                let items = transfers.filter { $0.groupID == id }
                guard !items.isEmpty else { return nil }
                return .group(TransferGroupSummary(id: group.id, name: group.name, items: items, totalBytes: group.totalBytes))
            }
            if let item = transfers.first(where: { $0.id == id }) {
                return .file(item)
            }
            return nil
        }
    }

    var activeTransfers: [TransferQueueRow] {
        rows.filter { row in
            switch row {
            case .file(let item): return item.status == .inProgress || item.status == .queued || item.status == .paused
            case .group(let summary): return summary.status == .inProgress || summary.status == .queued || summary.status == .paused
            }
        }
    }

    var completedTransfers: [TransferQueueRow] {
        rows.filter { row in
            switch row {
            case .file(let item): return item.status == .completed || item.status == .failed || item.status == .cancelled
            case .group(let summary): return summary.status == .completed || summary.status == .failed || summary.status == .cancelled
            }
        }
    }

    var completedCount: Int {
        rows.filter { row in
            switch row {
            case .file(let item): return item.status == .completed
            case .group(let summary): return summary.status == .completed
            }
        }.count
    }

    var summaryText: String {
        "\(activeTransfers.count) active · \(completedCount) completed"
    }

    // MARK: - Queue state

    func addTransfer(_ item: TransferItem) {
        var newItem = item
        newItem.status = .inProgress
        transfers.append(newItem)
        if newItem.groupID == nil {
            topLevelOrder.append(newItem.id)
        }
    }

    /// Registers a directory drag as a new aggregate row and returns its id, to be passed as
    /// `groupID` to `startDownload`/`downloadAndWait` for every file under that directory.
    @discardableResult
    func startGroup(name: String) -> UUID {
        let group = TransferGroup(name: name)
        groups[group.id] = group
        topLevelOrder.append(group.id)
        return group.id
    }

    /// Called once the recursive sizing pass for a directory drag reports a tree total, so the
    /// aggregate progress bar can switch from indeterminate to a real fraction.
    func updateGroupTotalBytes(id: UUID, totalBytes: Int64) {
        groups[id]?.totalBytes = totalBytes
    }

    /// Drops a group that ended up with no files (e.g. an empty directory was dragged) — it
    /// would otherwise never appear in `rows` (empty groups are filtered out) yet linger in
    /// `groups`/`topLevelOrder` forever.
    func removeGroupIfEmpty(id: UUID) {
        guard groups[id] != nil, !transfers.contains(where: { $0.groupID == id }) else { return }
        groups.removeValue(forKey: id)
        topLevelOrder.removeAll { $0 == id }
    }

    func updateTransfer(id: UUID, status: TransferStatus? = nil, bytesTransferred: Int64? = nil, bytesPerSecond: Double? = nil, errorMessage: String? = nil) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }

        if let status = status {
            transfers[index].status = status
        }
        if let bytesTransferred = bytesTransferred {
            transfers[index].bytesTransferred = bytesTransferred
        }
        if let bytesPerSecond = bytesPerSecond {
            transfers[index].bytesPerSecond = bytesPerSecond
        }
        if let errorMessage = errorMessage {
            transfers[index].errorMessage = errorMessage
        }
    }

    func removeTransfer(id: UUID) {
        // Stop any running work before dropping the row; the task's finish handler
        // no-ops once the item is gone.
        stopReasons[id] = .cancel
        tasks[id]?.cancel()
        tasks[id] = nil
        stopReasons[id] = nil
        progressHandlers[id] = nil
        let groupID = transfers.first(where: { $0.id == id })?.groupID
        transfers.removeAll { $0.id == id }
        topLevelOrder.removeAll { $0 == id }
        resumeWaiters(id: id, with: CancellationError())
        // Once its last file is gone, the group's own aggregate row has nothing left to show.
        if let groupID {
            removeGroupIfEmpty(id: groupID)
        }
    }

    /// Removes every file in a directory-drag group (cancelling any still running) along with
    /// the group's aggregate row.
    func removeGroup(id: UUID) {
        for childID in transfers.filter({ $0.groupID == id }).map(\.id) {
            removeTransfer(id: childID)
        }
        groups.removeValue(forKey: id)
        topLevelOrder.removeAll { $0 == id }
    }

    func clearCompleted() {
        // A group only clears once every one of its files has landed in a terminal state —
        // otherwise its aggregate row would vanish while it's still partly active.
        let clearableGroupIDs = Set(groups.keys.filter { groupID in
            let items = transfers.filter { $0.groupID == groupID }
            return !items.isEmpty && items.allSatisfy { $0.status == .completed || $0.status == .failed || $0.status == .cancelled }
        })
        transfers.removeAll { item in
            guard item.status == .completed || item.status == .failed || item.status == .cancelled else { return false }
            return item.groupID == nil || clearableGroupIDs.contains(item.groupID!)
        }
        for groupID in clearableGroupIDs {
            groups.removeValue(forKey: groupID)
            topLevelOrder.removeAll { $0 == groupID }
        }
    }

    func cancelAll() {
        cancelTransfers { _ in true }
    }

    /// Cancels every still-running (or paused) file in a directory-drag group; the group's
    /// aggregate row then reads as cancelled/failed/completed once its files all settle.
    func cancelGroup(id: UUID) {
        cancelTransfers { $0.groupID == id }
    }

    private func cancelTransfers(matching predicate: (TransferItem) -> Bool) {
        for index in transfers.indices {
            let item = transfers[index]
            guard predicate(item), item.status == .inProgress || item.status == .queued || item.status == .paused else { continue }
            stopReasons[item.id] = .cancel
            tasks[item.id]?.cancel()
            transfers[index].status = .cancelled
            resumeWaiters(id: item.id, with: CancellationError())
        }
    }

    func retryTransfer(id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }),
              transfers[index].status == .failed || transfers[index].status == .cancelled else {
            return
        }

        // Cancel any lingering task (normally already finished) before resetting state.
        stopReasons[id] = .cancel
        tasks[id]?.cancel()
        tasks[id] = nil
        stopReasons[id] = nil

        transfers[index].status = .queued
        transfers[index].bytesTransferred = 0
        transfers[index].bytesPerSecond = nil
        transfers[index].errorMessage = nil
    }

    /// Retries every failed file in a directory-drag group.
    func retryGroupFailed(id: UUID) {
        for childID in transfers.filter({ $0.groupID == id && $0.status == .failed }).map(\.id) {
            retryTransfer(id: childID)
        }
    }

    /// Pauses every active file in a directory-drag group, or — once nothing's left active —
    /// resumes every paused one. Mirrors `togglePause`'s active/paused split at the group level.
    func toggleGroupPause(id: UUID) {
        let items = transfers.filter { $0.groupID == id }
        let active = items.filter { $0.status == .inProgress || $0.status == .queued }
        if !active.isEmpty {
            for item in active { togglePause(id: item.id) }
        } else {
            for item in items where item.status == .paused { togglePause(id: item.id) }
        }
    }

    // MARK: - Download orchestration

    /// Starts downloading `file` to `localURL`, enqueuing a transfer row and driving progress.
    /// `groupID`, when supplied, rolls this file up under that directory-drag's aggregate row
    /// (see `startGroup`) instead of listing it as its own top-level row.
    @discardableResult
    func startDownload(file: RemoteFile, to localURL: URL, groupID: UUID? = nil) -> UUID {
        let item = TransferItem(
            fileName: file.name,
            localPath: localURL.path,
            remotePath: file.path,
            direction: .download,
            fileSize: file.size,
            status: .queued,
            groupID: groupID
        )
        addTransfer(item)
        runDownload(id: item.id, resumeOffset: 0)
        return item.id
    }

    /// Downloads `file` as a tracked transfer row and waits for it to finish, throwing if it
    /// ends anywhere other than `.completed`.
    ///
    /// This is the entry point for AppKit file promises (drag to Finder): the promise's
    /// completion handler has to report an outcome back to Finder, but the transfer still
    /// belongs in the queue, so the queue owns the download task and the caller just waits.
    /// `groupID` rolls this file into a directory drag's aggregate row (see `startGroup`).
    /// `progress`, when supplied, is called with the running byte count so the caller can
    /// mirror it onto Finder's own progress UI (e.g. an `NSProgress` for a file promise).
    func downloadAndWait(file: RemoteFile, to localURL: URL, groupID: UUID? = nil, progress: ((Int64) -> Void)? = nil) async throws {
        let id = startDownload(file: file, to: localURL, groupID: groupID)
        if let progress {
            progressHandlers[id] = progress
        }
        try await withCheckedThrowingContinuation { continuation in
            completionWaiters[id, default: []].append(continuation)
        }
    }

    /// Pause an in-flight download, or resume a paused one from where it stopped.
    ///
    /// Pause cancels the download task; the SFTP layer drains its in-flight reads to a clean
    /// byte boundary, leaves the partial file on disk, and throws `CancellationError`. Resume
    /// starts a fresh download that seeks to the bytes already written.
    func togglePause(id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }

        switch transfers[index].status {
        case .inProgress, .queued:
            stopReasons[id] = .pause
            if tasks[id] != nil {
                // Cancel the live download; it drains to a clean offset and its finish
                // handler flips the row to `.paused` once fully unwound. Keeping the row
                // `.inProgress` until then means `.paused` reliably signals "safe to resume".
                tasks[id]?.cancel()
            } else {
                // No work in flight (e.g. a re-queued row) — reflect the pause immediately.
                transfers[index].status = .paused
            }
        case .paused:
            // `.paused` is only set once the prior task cleared `tasks[id]`, so this is safe.
            guard tasks[id] == nil else { return }
            transfers[index].status = .inProgress
            runDownload(id: id, resumeOffset: transfers[index].bytesTransferred)
        default:
            break
        }
    }

    private func runDownload(id: UUID, resumeOffset: Int64) {
        guard tasks[id] == nil, let item = transfers.first(where: { $0.id == id }) else { return }

        let remotePath = item.remotePath
        let localURL = URL(fileURLWithPath: item.localPath)
        let startTime = Date()
        // Bytes already on disk from a prior run don't count toward this run's speed.
        let baseBytes = resumeOffset
        stopReasons[id] = nil

        tasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            let client = self.ftpClient
            do {
                try await client.downloadFile(named: remotePath, to: localURL, resumeOffset: resumeOffset) { bytesTransferred, _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let elapsed = Date().timeIntervalSince(startTime)
                        let delta = Double(bytesTransferred - baseBytes)
                        let speed = (elapsed > 0 && delta > 0) ? delta / elapsed : nil
                        self.updateTransfer(id: id, bytesTransferred: bytesTransferred, bytesPerSecond: speed)
                        self.progressHandlers[id]?(bytesTransferred)
                    }
                }
                self.finishDownload(id: id, status: .completed, error: nil)
            } catch is CancellationError {
                let status: TransferStatus = (self.stopReasons[id] == .pause) ? .paused : .cancelled
                self.finishDownload(id: id, status: status, error: CancellationError())
            } catch {
                self.finishDownload(id: id, status: .failed, error: error)
            }
        }
    }

    private func finishDownload(id: UUID, status: TransferStatus, error: Error?) {
        tasks[id] = nil
        stopReasons[id] = nil
        if status != .paused {
            // Paused rows may resume into a fresh `runDownload` under the same id; anything
            // terminal should stop mirroring progress onto a (by then unpublished) NSProgress.
            progressHandlers[id] = nil
        }
        // No-ops if the row was already removed.
        updateTransfer(id: id, status: status, errorMessage: (status == .failed) ? error?.localizedDescription : nil)

        switch status {
        case .completed:
            resumeWaiters(id: id, with: nil)
        case .failed, .cancelled:
            resumeWaiters(id: id, with: error ?? CancellationError())
        case .paused, .queued, .inProgress:
            // Not terminal — a resume can still carry this transfer to completion.
            break
        }
    }

    /// Hands the outcome to anyone parked in `downloadAndWait(file:to:)` for this transfer.
    private func resumeWaiters(id: UUID, with error: Error?) {
        guard let waiters = completionWaiters.removeValue(forKey: id) else { return }
        for waiter in waiters {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume()
            }
        }
    }
}

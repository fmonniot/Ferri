import Foundation
import Combine
import FTPClient

@MainActor
final class TransferQueueViewModel: ObservableObject {
    @Published var transfers: [TransferItem] = []
    @Published var showCompleted = true

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

    init(ftpClient: any FTPClientProtocol = FTPClient.shared) {
        self.ftpClient = ftpClient
    }

    var activeTransfers: [TransferItem] {
        transfers.filter { $0.status == .inProgress || $0.status == .queued || $0.status == .paused }
    }

    var completedTransfers: [TransferItem] {
        transfers.filter { $0.status == .completed || $0.status == .failed || $0.status == .cancelled }
    }

    var completedCount: Int {
        transfers.filter { $0.status == .completed }.count
    }

    var summaryText: String {
        "\(activeTransfers.count) active · \(completedCount) completed"
    }

    // MARK: - Queue state

    func addTransfer(_ item: TransferItem) {
        var newItem = item
        newItem.status = .inProgress
        transfers.append(newItem)
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
        transfers.removeAll { $0.id == id }
        resumeWaiters(id: id, with: CancellationError())
    }

    func clearCompleted() {
        transfers.removeAll { $0.status == .completed || $0.status == .failed || $0.status == .cancelled }
    }

    func cancelAll() {
        for index in transfers.indices {
            let item = transfers[index]
            guard item.status == .inProgress || item.status == .queued || item.status == .paused else { continue }
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

    // MARK: - Download orchestration

    /// Starts downloading `file` to `localURL`, enqueuing a transfer row and driving progress.
    @discardableResult
    func startDownload(file: RemoteFile, to localURL: URL) -> UUID {
        let item = TransferItem(
            fileName: file.name,
            localPath: localURL.path,
            remotePath: file.path,
            direction: .download,
            fileSize: file.size,
            status: .queued
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
    func downloadAndWait(file: RemoteFile, to localURL: URL) async throws {
        let id = startDownload(file: file, to: localURL)
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

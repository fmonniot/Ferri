import Testing
import Foundation
@testable import Ferri
@testable import FTPClient

// MARK: - Mock FTPClient

final class MockFTPClient: FTPClientProtocol, @unchecked Sendable {

    // MARK: Configurable behavior

    var mockFiles: [RemoteFile] = []
    /// Per-path file listings for recursive directory tests.
    var mockFilesByPath: [String: [RemoteFile]] = [:]
    var shouldFailDownload = false
    var downloadError: Error = FTPClientError.notConnected
    var shouldFailListDirectory = false
    var listDirectoryError: Error = FTPClientError.notConnected
    /// Paths that fail regardless of `shouldFailListDirectory` - lets a test simulate one path
    /// failing (e.g. a misconfigured initial directory) while another (e.g. root) still succeeds.
    var failListDirectoryForPaths: Set<String> = []
    var mockCurrentPath = "/"
    var shouldFailConnect = false
    var connectError: Error = SFTPClientError.authenticationFailed("bad credentials")
    /// Simulates a real reconnect clearing up whatever made listDirectory fail (e.g. a dropped
    /// channel) — flips `shouldFailListDirectory` back off once `connect` succeeds.
    var clearListDirectoryFailureOnConnect = false

    /// When true, `downloadFile` streams progress slowly (in `slowChunk`-sized steps every
    /// `slowChunkDelayNanos`) up to `slowTotalBytes`, honoring task cancellation by throwing
    /// `CancellationError`. Lets VM tests observe pause/resume against a live-ish transfer.
    var simulateSlowDownload = false
    var slowTotalBytes: Int64 = 1_000_000
    var slowChunk: Int64 = 100_000
    var slowChunkDelayNanos: UInt64 = 20_000_000 // 20ms

    // MARK: Call tracking

    /// The real `SFTPClient` is an `actor`, so a directory download's sizing pass running
    /// concurrently alongside the actual download (see `FilePromiseDragSourceView.downloadDirectory`
    /// / `FileBrowserViewModel.downloadDirectoryIntoGroup`) never races in production. This mock
    /// is a plain class, though, so those two concurrent call chains both appending to the same
    /// tracking array is a genuine, unsynchronized data race — guard the ones exercised that way.
    private let callTrackingLock = NSLock()
    private var _downloadCalls: [(fileName: String, localURL: URL, resumeOffset: Int64)] = []
    private var _listDirectoryCalls: [String] = []

    var downloadCalls: [(fileName: String, localURL: URL, resumeOffset: Int64)] {
        callTrackingLock.lock()
        defer { callTrackingLock.unlock() }
        return _downloadCalls
    }
    var listDirectoryCalls: [String] {
        callTrackingLock.lock()
        defer { callTrackingLock.unlock() }
        return _listDirectoryCalls
    }

    private(set) var connectCalls: [FTPServer] = []
    private(set) var disconnectCallCount = 0
    private(set) var changeDirectoryCalls: [String] = []

    // MARK: FTPClientProtocol

    var isConnected: Bool = false
    var currentPath: String { mockCurrentPath }

    func connect(to server: FTPServer) async throws {
        if shouldFailConnect { throw connectError }
        connectCalls.append(server)
        isConnected = true
        if clearListDirectoryFailureOnConnect {
            shouldFailListDirectory = false
        }
    }

    func disconnect() {
        disconnectCallCount += 1
        isConnected = false
    }

    func listDirectory(at path: String) async throws -> [RemoteFile] {
        callTrackingLock.lock()
        _listDirectoryCalls.append(path)
        callTrackingLock.unlock()
        if shouldFailListDirectory || failListDirectoryForPaths.contains(path) { throw listDirectoryError }
        if let files = mockFilesByPath[path] { return files }
        return mockFiles
    }

    func changeDirectory(to path: String) async throws {
        changeDirectoryCalls.append(path)
        if path == ".." {
            // Simulate going up one level
            let components = mockCurrentPath.split(separator: "/")
            if components.count > 1 {
                mockCurrentPath = "/" + components.dropLast().joined(separator: "/")
            } else {
                mockCurrentPath = "/"
            }
        } else if path.hasPrefix("/") {
            mockCurrentPath = path
        } else {
            mockCurrentPath = mockCurrentPath == "/"
                ? "/\(path)"
                : "\(mockCurrentPath)/\(path)"
        }
    }

    func goToParentDirectory() async throws {
        try await changeDirectory(to: "..")
    }

    func downloadFile(named fileName: String, to localURL: URL, resumeOffset: Int64, progress: (@Sendable (Int64, Int64?) -> Void)?) async throws {
        callTrackingLock.lock()
        _downloadCalls.append((fileName, localURL, resumeOffset))
        callTrackingLock.unlock()
        if shouldFailDownload { throw downloadError }

        if simulateSlowDownload {
            // Report progress in steps until either the transfer completes or the task is
            // cancelled (pause / remove) — Task.sleep throws CancellationError on cancel.
            var written = resumeOffset
            while written < slowTotalBytes {
                written = min(written + slowChunk, slowTotalBytes)
                progress?(written, slowTotalBytes)
                try await Task.sleep(nanoseconds: slowChunkDelayNanos)
            }
            return
        }

        // Create a dummy file so tests can verify the file exists
        let content = "mock content"
        progress?(Int64(content.utf8.count), Int64(content.utf8.count))
        try content.write(to: localURL, atomically: true, encoding: .utf8)
    }

    func listDirectoryRecursively(at path: String) async throws -> [RemoteFile] {
        var result: [RemoteFile] = []
        let entries = try await listDirectory(at: path)
        for entry in entries {
            if entry.isDirectory {
                let children = try await listDirectoryRecursively(at: entry.path)
                result.append(contentsOf: children)
            } else {
                result.append(entry)
            }
        }
        return result
    }
}

// MARK: - TransferItem Model Tests

struct TransferItemTests {

    @Test
    func progressReturnsZeroWhenFileSizeIsZero() {
        let item = TransferItem(
            fileName: "file.txt",
            localPath: "/local/file.txt",
            remotePath: "/remote/file.txt",
            direction: .download,
            fileSize: 0,
            bytesTransferred: 100
        )
        #expect(item.progress == 0)
    }

    @Test
    func progressCalculatesCorrectly() {
        let item = TransferItem(
            fileName: "file.txt",
            localPath: "/local/file.txt",
            remotePath: "/remote/file.txt",
            direction: .download,
            fileSize: 200,
            bytesTransferred: 100
        )
        #expect(item.progress == 0.5)
    }

    @Test
    func progressAtComplete() {
        let item = TransferItem(
            fileName: "file.txt",
            localPath: "/local/file.txt",
            remotePath: "/remote/file.txt",
            direction: .download,
            fileSize: 1024,
            bytesTransferred: 1024
        )
        #expect(item.progress == 1.0)
    }

    @Test
    func formattedProgressProducesExpectedFormat() {
        let item = TransferItem(
            fileName: "file.txt",
            localPath: "/local/file.txt",
            remotePath: "/remote/file.txt",
            direction: .download,
            fileSize: 1024,
            bytesTransferred: 512
        )
        let formatted = item.formattedProgress
        #expect(formatted.contains("/"))
    }

    @Test
    func directionIconDownload() {
        let item = TransferItem(
            fileName: "file.txt",
            localPath: "/local/file.txt",
            remotePath: "/remote/file.txt",
            direction: .download
        )
        #expect(item.directionIcon == "arrow.down.circle")
    }

    @Test
    func directionIconUpload() {
        let item = TransferItem(
            fileName: "file.txt",
            localPath: "/local/file.txt",
            remotePath: "/remote/file.txt",
            direction: .upload
        )
        #expect(item.directionIcon == "arrow.up.circle")
    }
}

// MARK: - TransferQueueViewModel Tests

@MainActor
struct TransferQueueViewModelTests {

    private func makeItem(
        fileName: String = "file.txt",
        status: TransferStatus = .queued
    ) -> TransferItem {
        TransferItem(
            fileName: fileName,
            localPath: "/local/\(fileName)",
            remotePath: "/remote/\(fileName)",
            direction: .download,
            fileSize: 1024,
            status: status
        )
    }

    @Test
    func addTransferSetsStatusToInProgress() {
        let vm = TransferQueueViewModel()
        let item = makeItem(status: .queued)
        vm.addTransfer(item)

        #expect(vm.transfers.count == 1)
        #expect(vm.transfers[0].status == .inProgress)
    }

    @Test
    func updateTransferModifiesStatus() {
        let vm = TransferQueueViewModel()
        let item = makeItem()
        vm.addTransfer(item)

        vm.updateTransfer(id: item.id, status: .completed)
        #expect(vm.transfers[0].status == .completed)
    }

    @Test
    func updateTransferModifiesBytesTransferred() {
        let vm = TransferQueueViewModel()
        let item = makeItem()
        vm.addTransfer(item)

        vm.updateTransfer(id: item.id, bytesTransferred: 512)
        #expect(vm.transfers[0].bytesTransferred == 512)
    }

    @Test
    func updateTransferModifiesErrorMessage() {
        let vm = TransferQueueViewModel()
        let item = makeItem()
        vm.addTransfer(item)

        vm.updateTransfer(id: item.id, status: .failed, errorMessage: "Network error")
        #expect(vm.transfers[0].status == .failed)
        #expect(vm.transfers[0].errorMessage == "Network error")
    }

    @Test
    func updateTransferIgnoresUnknownId() {
        let vm = TransferQueueViewModel()
        let item = makeItem()
        vm.addTransfer(item)

        vm.updateTransfer(id: UUID(), status: .completed)
        #expect(vm.transfers[0].status == .inProgress)
    }

    @Test
    func removeTransfer() {
        let vm = TransferQueueViewModel()
        let item = makeItem()
        vm.addTransfer(item)

        vm.removeTransfer(id: item.id)
        #expect(vm.transfers.isEmpty)
    }

    @Test
    func removeTransferIgnoresUnknownId() {
        let vm = TransferQueueViewModel()
        let item = makeItem()
        vm.addTransfer(item)

        vm.removeTransfer(id: UUID())
        #expect(vm.transfers.count == 1)
    }

    @Test
    func activeTransfersFiltersCorrectly() {
        let vm = TransferQueueViewModel()

        let item1 = makeItem(fileName: "a.txt")
        let item2 = makeItem(fileName: "b.txt")
        vm.addTransfer(item1) // becomes .inProgress
        vm.addTransfer(item2) // becomes .inProgress
        vm.updateTransfer(id: item1.id, status: .completed)

        #expect(vm.activeTransfers.count == 1)
        #expect(vm.activeTransfers[0].id == item2.id)
    }

    @Test
    func completedTransfersFiltersCorrectly() {
        let vm = TransferQueueViewModel()

        let item1 = makeItem(fileName: "a.txt")
        let item2 = makeItem(fileName: "b.txt")
        let item3 = makeItem(fileName: "c.txt")
        vm.addTransfer(item1)
        vm.addTransfer(item2)
        vm.addTransfer(item3)
        vm.updateTransfer(id: item1.id, status: .completed)
        vm.updateTransfer(id: item2.id, status: .failed)

        #expect(vm.completedTransfers.count == 2)
    }

    @Test
    func clearCompletedRemovesFinishedItems() {
        let vm = TransferQueueViewModel()

        let item1 = makeItem(fileName: "a.txt")
        let item2 = makeItem(fileName: "b.txt")
        let item3 = makeItem(fileName: "c.txt")
        vm.addTransfer(item1)
        vm.addTransfer(item2)
        vm.addTransfer(item3)
        vm.updateTransfer(id: item1.id, status: .completed)
        vm.updateTransfer(id: item2.id, status: .failed)

        vm.clearCompleted()
        #expect(vm.transfers.count == 1)
        #expect(vm.transfers[0].id == item3.id)
    }

    @Test
    func cancelAllSetsActiveItemsToCancelled() {
        let vm = TransferQueueViewModel()

        let item1 = makeItem(fileName: "a.txt")
        let item2 = makeItem(fileName: "b.txt")
        vm.addTransfer(item1)
        vm.addTransfer(item2)
        vm.updateTransfer(id: item1.id, status: .completed)

        vm.cancelAll()
        #expect(vm.transfers[0].status == .completed) // unchanged
        #expect(vm.transfers[1].status == .cancelled)
    }

    @Test
    func retryTransferResetsFailedItemAndRestartsDownload() async throws {
        let mock = MockFTPClient()
        let vm = TransferQueueViewModel(ftpClient: mock)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("retry_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let id = vm.startDownload(file: RemoteFile(name: "file.txt", path: "/remote/file.txt", isDirectory: false, size: 1024), to: tempURL)
        await waitUntil { vm.transfers.first?.status == .completed }
        vm.updateTransfer(id: id, status: .failed, bytesTransferred: 256, errorMessage: "err")

        vm.retryTransfer(id: id)
        #expect(vm.transfers[0].status == .inProgress)
        #expect(vm.transfers[0].bytesTransferred == 0)
        #expect(vm.transfers[0].errorMessage == nil)

        // The retry actually restarts the download rather than leaving the row stuck queued.
        await waitUntil { vm.transfers.first?.status == .completed }
        #expect(mock.downloadCalls.count == 2)
        #expect(mock.downloadCalls[1].resumeOffset == 0)
    }

    @Test
    func retryTransferIgnoresNonFailedItem() {
        let vm = TransferQueueViewModel()
        let item = makeItem()
        vm.addTransfer(item) // status becomes .inProgress

        vm.retryTransfer(id: item.id)
        #expect(vm.transfers[0].status == .inProgress) // unchanged
    }

    // MARK: Pause / resume

    private func makeSlowFile() -> RemoteFile {
        RemoteFile(name: "big.bin", path: "/remote/big.bin", isDirectory: false, size: 1_000_000)
    }

    /// Polls until `condition` holds or a timeout elapses, letting async progress/finish
    /// callbacks hop back to the main actor between checks.
    private func waitUntil(timeoutMs: Int = 2000, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
    }

    @Test
    func pauseInterruptsDownloadAndResumeContinuesFromOffset() async throws {
        let mock = MockFTPClient()
        mock.simulateSlowDownload = true
        let vm = TransferQueueViewModel(ftpClient: mock)

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("pause_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        vm.startDownload(file: makeSlowFile(), to: tempURL)
        let id = vm.transfers[0].id

        // Let some bytes flow, then pause.
        await waitUntil { vm.transfers.first?.bytesTransferred ?? 0 > 0 }
        let bytesAtPause = vm.transfers[0].bytesTransferred
        #expect(bytesAtPause > 0)

        vm.togglePause(id: id)

        // The download task drains and settles on .paused (not .failed/.cancelled). The row
        // only reaches .paused once the task has fully unwound, so this is also the signal
        // that a resume can start cleanly.
        await waitUntil { vm.transfers.first?.status == .paused }
        #expect(vm.transfers[0].status == .paused)
        #expect(mock.downloadCalls.count == 1)

        let bytesWhilePaused = vm.transfers[0].bytesTransferred

        // Resume: a second download starts from the paused byte offset.
        vm.togglePause(id: id)
        #expect(vm.transfers[0].status == .inProgress)

        await waitUntil { mock.downloadCalls.count == 2 }
        #expect(mock.downloadCalls.count == 2)
        #expect(mock.downloadCalls[1].resumeOffset == bytesWhilePaused)
    }

    @Test
    func pausedDownloadCanRunToCompletionAfterResume() async throws {
        let mock = MockFTPClient()
        mock.simulateSlowDownload = true
        mock.slowTotalBytes = 300_000
        mock.slowChunk = 100_000
        let vm = TransferQueueViewModel(ftpClient: mock)

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("resume_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        vm.startDownload(file: makeSlowFile(), to: tempURL)
        let id = vm.transfers[0].id

        await waitUntil { vm.transfers.first?.bytesTransferred ?? 0 > 0 }
        vm.togglePause(id: id)
        await waitUntil { vm.transfers.first?.status == .paused }

        vm.togglePause(id: id)
        await waitUntil { vm.transfers.first?.status == .completed }
        #expect(vm.transfers[0].status == .completed)
    }

    // MARK: Directory-drag groups

    private func groupSummary(_ vm: TransferQueueViewModel, id: UUID) -> TransferGroupSummary? {
        for row in vm.rows {
            if case .group(let summary) = row, summary.id == id { return summary }
        }
        return nil
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("group_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test
    func groupAggregatesChildFilesIntoOneRow() async throws {
        let mock = MockFTPClient()
        let vm = TransferQueueViewModel(ftpClient: mock)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let groupID = vm.startGroup(name: "project")
        vm.startDownload(file: RemoteFile(name: "a.txt", path: "/project/a.txt", isDirectory: false, size: 12), to: tempDir.appendingPathComponent("a.txt"), groupID: groupID)
        vm.startDownload(file: RemoteFile(name: "b.txt", path: "/project/b.txt", isDirectory: false, size: 12), to: tempDir.appendingPathComponent("b.txt"), groupID: groupID)

        // One aggregate row, not one per file.
        #expect(vm.rows.count == 1)
        #expect(vm.transfers.count == 2)

        await waitUntil { groupSummary(vm, id: groupID)?.status == .completed }
        let summary = groupSummary(vm, id: groupID)
        #expect(summary?.filesTotal == 2)
        #expect(summary?.filesCompleted == 2)
    }

    @Test
    func groupRowDisappearsOnceAllChildrenRemoved() async throws {
        let mock = MockFTPClient()
        let vm = TransferQueueViewModel(ftpClient: mock)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let groupID = vm.startGroup(name: "project")
        let id = vm.startDownload(file: RemoteFile(name: "a.txt", path: "/project/a.txt", isDirectory: false, size: 12), to: tempDir.appendingPathComponent("a.txt"), groupID: groupID)

        await waitUntil { vm.transfers.first?.status == .completed }
        vm.removeTransfer(id: id)

        #expect(vm.rows.isEmpty)
        #expect(vm.groups.isEmpty)
    }

    @Test
    func removeGroupCancelsAndRemovesAllChildren() async throws {
        let mock = MockFTPClient()
        mock.simulateSlowDownload = true
        let vm = TransferQueueViewModel(ftpClient: mock)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let groupID = vm.startGroup(name: "project")
        vm.startDownload(file: makeSlowFile(), to: tempDir.appendingPathComponent("a.bin"), groupID: groupID)
        vm.startDownload(file: makeSlowFile(), to: tempDir.appendingPathComponent("b.bin"), groupID: groupID)

        await waitUntil { vm.transfers.allSatisfy { $0.bytesTransferred > 0 } }

        vm.removeGroup(id: groupID)

        #expect(vm.transfers.isEmpty)
        #expect(vm.rows.isEmpty)
        #expect(vm.groups.isEmpty)
    }

    @Test
    func toggleGroupPausePausesThenResumesAllChildren() async throws {
        let mock = MockFTPClient()
        mock.simulateSlowDownload = true
        let vm = TransferQueueViewModel(ftpClient: mock)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let groupID = vm.startGroup(name: "project")
        vm.startDownload(file: makeSlowFile(), to: tempDir.appendingPathComponent("a.bin"), groupID: groupID)
        vm.startDownload(file: makeSlowFile(), to: tempDir.appendingPathComponent("b.bin"), groupID: groupID)

        await waitUntil { vm.transfers.allSatisfy { $0.bytesTransferred > 0 } }

        vm.toggleGroupPause(id: groupID)
        await waitUntil { vm.transfers.allSatisfy { $0.status == .paused } }
        #expect(vm.transfers.allSatisfy { $0.status == .paused })
        #expect(groupSummary(vm, id: groupID)?.status == .paused)

        vm.toggleGroupPause(id: groupID)
        #expect(vm.transfers.allSatisfy { $0.status == .inProgress })

        await waitUntil { groupSummary(vm, id: groupID)?.status == .completed }
        #expect(groupSummary(vm, id: groupID)?.status == .completed)
    }

    @Test
    func retryGroupFailedRetriesOnlyFailedChildren() async throws {
        let mock = MockFTPClient()
        let vm = TransferQueueViewModel(ftpClient: mock)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let groupID = vm.startGroup(name: "project")
        let okID = vm.startDownload(file: RemoteFile(name: "ok.txt", path: "/project/ok.txt", isDirectory: false, size: 12), to: tempDir.appendingPathComponent("ok.txt"), groupID: groupID)
        await waitUntil { vm.transfers.first(where: { $0.id == okID })?.status == .completed }

        mock.shouldFailDownload = true
        let failID = vm.startDownload(file: RemoteFile(name: "bad.txt", path: "/project/bad.txt", isDirectory: false, size: 12), to: tempDir.appendingPathComponent("bad.txt"), groupID: groupID)
        await waitUntil { vm.transfers.first(where: { $0.id == failID })?.status == .failed }

        mock.shouldFailDownload = false
        vm.retryGroupFailed(id: groupID)

        // Mirrors `retryTransfer`'s own contract (see `retryTransferResetsFailedItemAndRestartsDownload`):
        // retrying restarts the failed child's download without touching its already-done sibling.
        #expect(vm.transfers.first(where: { $0.id == okID })?.status == .completed)
        await waitUntil { vm.transfers.first(where: { $0.id == failID })?.status == .completed }
        #expect(vm.transfers.first(where: { $0.id == failID })?.status == .completed)
    }

    @Test
    func clearCompletedLeavesPartiallyActiveGroupIntact() async throws {
        let mock = MockFTPClient()
        let vm = TransferQueueViewModel(ftpClient: mock)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let groupID = vm.startGroup(name: "project")
        let doneID = vm.startDownload(file: RemoteFile(name: "done.txt", path: "/project/done.txt", isDirectory: false, size: 12), to: tempDir.appendingPathComponent("done.txt"), groupID: groupID)
        await waitUntil { vm.transfers.first(where: { $0.id == doneID })?.status == .completed }

        mock.simulateSlowDownload = true
        let activeID = vm.startDownload(file: makeSlowFile(), to: tempDir.appendingPathComponent("active.bin"), groupID: groupID)
        await waitUntil { (vm.transfers.first(where: { $0.id == activeID })?.bytesTransferred ?? 0) > 0 }

        vm.clearCompleted()

        // The group still has an active file, so the aggregate row (and both children) stay.
        #expect(vm.transfers.count == 2)
        #expect(vm.rows.count == 1)

        vm.removeGroup(id: groupID) // cleanup: cancel the still-running child
    }

    @Test
    func removeGroupIfEmptyDropsGroupWithNoFiles() {
        let vm = TransferQueueViewModel()
        let groupID = vm.startGroup(name: "empty-folder")
        #expect(vm.groups[groupID] != nil)

        vm.removeGroupIfEmpty(id: groupID)

        #expect(vm.groups[groupID] == nil)
        #expect(vm.rows.isEmpty)
    }
}

// MARK: - FileBrowserViewModel Tests

@MainActor
struct FileBrowserViewModelTests {

    private func makeMockClient(files: [RemoteFile] = [], currentPath: String = "/home") -> MockFTPClient {
        let mock = MockFTPClient()
        mock.mockFiles = files
        mock.mockCurrentPath = currentPath
        return mock
    }

    private func sampleFiles() -> [RemoteFile] {
        [
            RemoteFile(name: "docs", path: "/home/docs", isDirectory: true, size: 4096),
            RemoteFile(name: "readme.txt", path: "/home/readme.txt", isDirectory: false, size: 1024),
            RemoteFile(name: "app.swift", path: "/home/app.swift", isDirectory: false, size: 2048),
        ]
    }

    @Test
    func loadDirectoryPopulatesFiles() async {
        let mock = makeMockClient(files: sampleFiles())
        let vm = FileBrowserViewModel(ftpClient: mock)

        await vm.loadDirectory(at: "/home")

        #expect(vm.files.count == 3)
        #expect(vm.currentPath == "/home")
        #expect(vm.errorMessage == nil)
        #expect(vm.isLoading == false)
    }

    @Test
    func loadDirectorySetsErrorOnFailure() async {
        let mock = makeMockClient()
        mock.shouldFailListDirectory = true
        let vm = FileBrowserViewModel(ftpClient: mock)

        await vm.loadDirectory(at: "/home")

        #expect(vm.files.isEmpty)
        #expect(vm.errorMessage != nil)
        #expect(vm.isLoading == false)
    }

    @Test
    func loadInitialDirectorySucceedsWithoutWarning() async {
        let mock = makeMockClient(files: sampleFiles(), currentPath: "/home")
        let vm = FileBrowserViewModel(ftpClient: mock)

        await vm.loadInitialDirectory(at: "/home")

        #expect(vm.files.count == 3)
        #expect(vm.currentPath == "/home")
        #expect(vm.initialDirectoryWarning == nil)
    }

    @Test
    func loadInitialDirectoryWithEmptyPathLoadsRootDirectly() async {
        let mock = makeMockClient(files: sampleFiles(), currentPath: "/")
        let vm = FileBrowserViewModel(ftpClient: mock)

        await vm.loadInitialDirectory(at: "")

        #expect(mock.listDirectoryCalls == ["/"])
        #expect(vm.initialDirectoryWarning == nil)
    }

    @Test
    func loadInitialDirectoryFallsBackToRootWhenConfiguredPathFails() async {
        let mock = makeMockClient(files: sampleFiles(), currentPath: "/")
        mock.failListDirectoryForPaths = ["/broken"]
        mock.listDirectoryError = SFTPClientError.requestFailed(3, "Permission denied")

        let vm = FileBrowserViewModel(ftpClient: mock)

        await vm.loadInitialDirectory(at: "/broken")

        #expect(mock.listDirectoryCalls == ["/broken", "/"])
        #expect(vm.currentPath == "/")
        #expect(vm.files.count == 3)
        #expect(vm.errorMessage == nil)
        #expect(vm.isPermissionDenied == false)
        #expect(vm.initialDirectoryWarning?.contains("/broken") == true)
    }

    @Test
    func dismissInitialDirectoryWarningClearsIt() async {
        let mock = makeMockClient(files: sampleFiles(), currentPath: "/")
        mock.failListDirectoryForPaths = ["/broken"]
        mock.listDirectoryError = SFTPClientError.requestFailed(3, "Permission denied")

        let vm = FileBrowserViewModel(ftpClient: mock)
        await vm.loadInitialDirectory(at: "/broken")
        #expect(vm.initialDirectoryWarning != nil)

        vm.dismissInitialDirectoryWarning()

        #expect(vm.initialDirectoryWarning == nil)
    }

    /// `MainView.connect` doesn't call `reset()` when switching to a different saved connection
    /// (only an explicit "Disconnect" does), so a warning from a previous connection's fallback
    /// must not survive into the next one just because the user never dismissed it.
    @Test
    func loadInitialDirectoryOnNewConnectionClearsStaleWarningWhenPathIsFine() async {
        let mock = makeMockClient(files: sampleFiles(), currentPath: "/")
        mock.failListDirectoryForPaths = ["/broken"]
        mock.listDirectoryError = SFTPClientError.requestFailed(3, "Permission denied")

        let vm = FileBrowserViewModel(ftpClient: mock)
        await vm.loadInitialDirectory(at: "/broken")
        #expect(vm.initialDirectoryWarning != nil)

        // Simulates connecting to a second, correctly-configured server without dismissing
        // the first warning.
        mock.failListDirectoryForPaths = []
        await vm.loadInitialDirectory(at: "/home")

        #expect(vm.initialDirectoryWarning == nil)
        #expect(vm.errorMessage == nil)
    }

    @Test
    func refreshReconnectsAndRetriesOnConnectionLostError() async {
        let mock = makeMockClient(files: sampleFiles())
        mock.shouldFailListDirectory = true
        mock.listDirectoryError = FTPClientError.notConnected
        mock.clearListDirectoryFailureOnConnect = true

        let vm = FileBrowserViewModel(ftpClient: mock)
        let connectionVM = ConnectionListViewModel()
        let server = FTPServer(name: "Test", host: "example.com", port: 22, username: "user", password: "pass")
        connectionVM.selectConnection(server)
        vm.setConnectionViewModel(connectionVM)

        await vm.refresh()

        #expect(mock.connectCalls.count == 1)
        #expect(vm.files.count == 3)
        #expect(vm.errorMessage == nil)
    }

    @Test
    func refreshSurfacesErrorWhenReconnectFails() async {
        let mock = makeMockClient()
        mock.shouldFailListDirectory = true
        mock.listDirectoryError = FTPClientError.notConnected
        mock.shouldFailConnect = true

        let vm = FileBrowserViewModel(ftpClient: mock)
        let connectionVM = ConnectionListViewModel()
        let server = FTPServer(name: "Test", host: "example.com", port: 22, username: "user", password: "pass")
        connectionVM.selectConnection(server)
        vm.setConnectionViewModel(connectionVM)

        await vm.refresh()

        #expect(mock.connectCalls.isEmpty)
        #expect(vm.errorMessage != nil)
    }

    @Test
    func refreshDoesNotReconnectOnPermissionDenied() async {
        let mock = makeMockClient()
        mock.shouldFailListDirectory = true
        mock.listDirectoryError = SFTPClientError.requestFailed(3, "Permission denied")

        let vm = FileBrowserViewModel(ftpClient: mock)
        let connectionVM = ConnectionListViewModel()
        let server = FTPServer(name: "Test", host: "example.com", port: 22, username: "user", password: "pass")
        connectionVM.selectConnection(server)
        vm.setConnectionViewModel(connectionVM)

        await vm.refresh()

        #expect(mock.connectCalls.isEmpty)
        #expect(vm.isPermissionDenied == true)
    }

    @Test
    func refreshWithoutConnectionViewModelJustSurfacesError() async {
        let mock = makeMockClient()
        mock.shouldFailListDirectory = true
        mock.listDirectoryError = FTPClientError.notConnected

        let vm = FileBrowserViewModel(ftpClient: mock)

        await vm.refresh()

        #expect(mock.connectCalls.isEmpty)
        #expect(vm.errorMessage != nil)
    }

    @Test
    func navigateToFolderOnlyNavigatesForDirectories() async {
        let mock = makeMockClient(files: sampleFiles())
        let vm = FileBrowserViewModel(ftpClient: mock)

        let file = RemoteFile(name: "readme.txt", path: "/home/readme.txt", isDirectory: false)
        await vm.navigateToFolder(file)

        // Should not have called listDirectory since it's not a directory
        #expect(mock.listDirectoryCalls.isEmpty)
    }

    @Test
    func navigateToFolderNavigatesForDirectories() async {
        let mock = makeMockClient(files: sampleFiles())
        let vm = FileBrowserViewModel(ftpClient: mock)

        let folder = RemoteFile(name: "docs", path: "/home/docs", isDirectory: true)
        await vm.navigateToFolder(folder)

        #expect(mock.listDirectoryCalls.count == 1)
        #expect(mock.listDirectoryCalls[0] == "/home/docs")
    }

    @Test
    func sortByNameDirectoriesFirst() async {
        let mock = makeMockClient(files: [
            RemoteFile(name: "zebra.txt", path: "/zebra.txt", isDirectory: false, size: 100),
            RemoteFile(name: "alpha", path: "/alpha", isDirectory: true, size: 4096),
            RemoteFile(name: "archive.txt", path: "/archive.txt", isDirectory: false, size: 200),
        ])
        let vm = FileBrowserViewModel(ftpClient: mock)

        await vm.loadDirectory(at: "/")

        // Default sort is by name ascending, directories first
        #expect(vm.files[0].name == "alpha")
        #expect(vm.files[0].isDirectory == true)
        #expect(vm.files[1].name == "archive.txt")
        #expect(vm.files[2].name == "zebra.txt")
    }

    @Test
    func sortByTogglesSortOrder() async {
        let mock = makeMockClient(files: sampleFiles())
        let vm = FileBrowserViewModel(ftpClient: mock)

        await vm.loadDirectory(at: "/home")

        // Default: name ascending
        #expect(vm.sortColumn == .name)
        #expect(vm.sortOrder == .ascending)

        // Toggle same column → descending
        vm.sortBy(.name)
        #expect(vm.sortOrder == .descending)

        // Toggle again → ascending
        vm.sortBy(.name)
        #expect(vm.sortOrder == .ascending)
    }

    @Test
    func sortByDifferentColumnResetsToAscending() async {
        let mock = makeMockClient(files: sampleFiles())
        let vm = FileBrowserViewModel(ftpClient: mock)

        await vm.loadDirectory(at: "/home")
        vm.sortBy(.name) // now descending

        vm.sortBy(.size) // switch column → ascending
        #expect(vm.sortColumn == .size)
        #expect(vm.sortOrder == .ascending)
    }

    @Test
    func navigationHistory() async {
        let mock = makeMockClient(files: sampleFiles(), currentPath: "/")
        let vm = FileBrowserViewModel(ftpClient: mock)

        #expect(vm.canGoBack == false)
        #expect(vm.canGoForward == false)

        await vm.loadDirectory(at: "/")
        mock.mockCurrentPath = "/home"
        await vm.loadDirectory(at: "/home")

        #expect(vm.canGoBack == true)
        #expect(vm.canGoForward == false)
    }

    @Test
    func downloadFileCreatesTransferItemAndCallsClient() async throws {
        let mock = makeMockClient(files: sampleFiles())
        let vm = FileBrowserViewModel(ftpClient: mock)
        // The queue owns the download, so it must talk to the same mock client.
        let queue = TransferQueueViewModel(ftpClient: mock)

        let file = RemoteFile(name: "readme.txt", path: "/home/readme.txt", isDirectory: false, size: 1024)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        vm.downloadFile(file, to: tempURL, transferQueue: queue)

        // TransferItem should be added to queue immediately
        #expect(queue.transfers.count == 1)
        #expect(queue.transfers[0].fileName == "readme.txt")
        #expect(queue.transfers[0].remotePath == "/home/readme.txt")
        #expect(queue.transfers[0].direction == .download)

        // Wait briefly for the background Task to call the mock
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        #expect(mock.downloadCalls.count == 1)
        // The download addresses the file by its absolute remote path.
        #expect(mock.downloadCalls[0].fileName == "/home/readme.txt")
        #expect(mock.downloadCalls[0].resumeOffset == 0)
    }

    @Test
    func goUpDoesNothingAtRoot() async {
        let mock = makeMockClient(currentPath: "/")
        let vm = FileBrowserViewModel(ftpClient: mock)
        vm.currentPath = "/"

        await vm.goUp()

        // canGoUp is false when currentPath == "/", so loadDirectory should not be called
        #expect(mock.listDirectoryCalls.isEmpty)
    }

    // MARK: Multi-item download

    private func groupSummary(_ queue: TransferQueueViewModel, id: UUID) -> TransferGroupSummary? {
        for row in queue.rows {
            if case .group(let summary) = row, summary.id == id { return summary }
        }
        return nil
    }

    private func waitUntil(timeoutMs: Int = 2000, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
    }

    @Test
    func downloadFilesGroupsMultiplePlainFiles() async throws {
        let mock = MockFTPClient()
        let vm = FileBrowserViewModel(ftpClient: mock)
        let queue = TransferQueueViewModel(ftpClient: mock)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("multi_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let files = [
            RemoteFile(name: "a.txt", path: "/home/a.txt", isDirectory: false, size: 100),
            RemoteFile(name: "b.txt", path: "/home/b.txt", isDirectory: false, size: 200),
        ]
        vm.downloadFiles(files, to: tempDir, transferQueue: queue)

        // `startGroup` registers the group synchronously, so its id is available immediately —
        // unlike `rows`, which only shows a group once it has at least one transfer item, and
        // for plain files (unlike directories) that happens synchronously too.
        let groupID = try #require(queue.groups.keys.first)
        #expect(queue.rows.count == 1)

        let initial = try #require(groupSummary(queue, id: groupID))
        #expect(initial.filesTotal == 2)
        #expect(initial.totalBytes == 300)

        await waitUntil { groupSummary(queue, id: groupID)?.status == .completed }
        #expect(groupSummary(queue, id: groupID)?.filesCompleted == 2)
    }

    @Test
    func downloadFilesGroupsSingleDirectory() async throws {
        let mock = MockFTPClient()
        mock.mockFilesByPath["/home/docs"] = [
            RemoteFile(name: "readme.md", path: "/home/docs/readme.md", isDirectory: false, size: 500),
            RemoteFile(name: "notes.txt", path: "/home/docs/notes.txt", isDirectory: false, size: 300),
        ]
        let vm = FileBrowserViewModel(ftpClient: mock)
        let queue = TransferQueueViewModel(ftpClient: mock)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("dir_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let docs = RemoteFile(name: "docs", path: "/home/docs", isDirectory: true, size: 4096)
        vm.downloadFiles([docs], to: tempDir, transferQueue: queue)

        // A directory-only download adds nothing to `transfers` synchronously (the recursive
        // walk runs in a spawned Task that hasn't executed yet), so `rows` is still empty here
        // — only the group itself, registered synchronously by `startGroup`, is available.
        let groupID = try #require(queue.groups.keys.first)

        // The directory's own listed size (4096) is never used — its total comes from the
        // recursive sizing pass over its actual contents once that finishes.
        await waitUntil { groupSummary(queue, id: groupID)?.totalBytes == 800 }
        #expect(groupSummary(queue, id: groupID)?.filesTotal == 2)

        await waitUntil { groupSummary(queue, id: groupID)?.status == .completed }
    }

    @Test
    func downloadFilesMixedFilesAndDirectoryAccumulatesTotal() async throws {
        let mock = MockFTPClient()
        mock.mockFilesByPath["/home/docs"] = [
            RemoteFile(name: "readme.md", path: "/home/docs/readme.md", isDirectory: false, size: 500),
        ]
        let vm = FileBrowserViewModel(ftpClient: mock)
        let queue = TransferQueueViewModel(ftpClient: mock)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mixed_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let plainFile = RemoteFile(name: "a.txt", path: "/home/a.txt", isDirectory: false, size: 100)
        let docs = RemoteFile(name: "docs", path: "/home/docs", isDirectory: true, size: 4096)
        vm.downloadFiles([plainFile, docs], to: tempDir, transferQueue: queue)

        let groupID = try #require(queue.groups.keys.first)
        #expect(queue.rows.count == 1)

        // The plain file's known size (100) lands immediately; the directory's (500) only
        // arrives once its sizing pass finishes, so the total grows from 100 to 600.
        #expect(groupSummary(queue, id: groupID)?.totalBytes == 100)
        await waitUntil { groupSummary(queue, id: groupID)?.totalBytes == 600 }
        #expect(groupSummary(queue, id: groupID)?.totalBytes == 600)

        await waitUntil { groupSummary(queue, id: groupID)?.filesCompleted == 2 }
    }
}

// MARK: - Drag-Source Download Logic Tests

struct DownloadLogicTests {

    @Test
    func singleFileDownload() async throws {
        let mock = MockFTPClient()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("drag_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("test.txt")
        try await mock.downloadFile(named: "/remote/test.txt", to: fileURL)

        #expect(mock.downloadCalls.count == 1)
        #expect(mock.downloadCalls[0].fileName == "/remote/test.txt")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test
    func singleFileDownloadFailure() async {
        let mock = MockFTPClient()
        mock.shouldFailDownload = true
        mock.downloadError = FTPClientError.notConnected

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("fail_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            try await mock.downloadFile(named: "/remote/fail.txt", to: tempURL)
            Issue.record("Expected download to throw")
        } catch {
            // Expected
            #expect(error is FTPClientError)
        }
    }

    @Test
    func recursiveDirectoryDownload() async throws {
        let mock = MockFTPClient()

        // Set up a directory tree: /project/src/main.swift, /project/README.md
        mock.mockFilesByPath["/project"] = [
            RemoteFile(name: "src", path: "/project/src", isDirectory: true),
            RemoteFile(name: "README.md", path: "/project/README.md", isDirectory: false, size: 100),
        ]
        mock.mockFilesByPath["/project/src"] = [
            RemoteFile(name: "main.swift", path: "/project/src/main.swift", isDirectory: false, size: 200),
        ]

        let allFiles = try await mock.listDirectoryRecursively(at: "/project")

        // Should have listed both /project and /project/src
        #expect(mock.listDirectoryCalls.contains("/project"))
        #expect(mock.listDirectoryCalls.contains("/project/src"))

        // Should return only files, not directories
        #expect(allFiles.count == 2)
        #expect(allFiles.contains { $0.name == "README.md" })
        #expect(allFiles.contains { $0.name == "main.swift" })
    }

    @Test
    func recursiveDirectoryDownloadWithError() async {
        let mock = MockFTPClient()
        mock.mockFilesByPath["/project"] = [
            RemoteFile(name: "src", path: "/project/src", isDirectory: true),
        ]
        // /project/src listing will fail because no entry + shouldFailListDirectory
        mock.shouldFailListDirectory = true
        mock.listDirectoryError = FTPClientError.notConnected

        do {
            // First call to listDirectory for /project will also fail
            _ = try await mock.listDirectoryRecursively(at: "/project")
            Issue.record("Expected error")
        } catch {
            #expect(error is FTPClientError)
        }
    }

    @Test
    func emptyDirectoryDownload() async throws {
        let mock = MockFTPClient()
        mock.mockFilesByPath["/empty"] = []

        let allFiles = try await mock.listDirectoryRecursively(at: "/empty")
        #expect(allFiles.isEmpty)
        #expect(mock.listDirectoryCalls.count == 1)
    }
}

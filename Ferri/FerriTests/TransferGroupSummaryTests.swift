import Testing
import Foundation
@testable import Ferri

// MARK: - TransferGroupSummary Tests

/// Directly unit-tests `TransferGroupSummary`'s computed properties, which are currently only
/// exercised indirectly through `TransferQueueViewModelTests` in `FerriTests.swift`.
struct TransferGroupSummaryTests {

    private func item(
        name: String = "file.txt",
        fileSize: Int64 = 1000,
        status: TransferStatus = .queued,
        bytesTransferred: Int64 = 0,
        bytesPerSecond: Double? = nil
    ) -> TransferItem {
        TransferItem(
            fileName: name,
            localPath: "/local/\(name)",
            remotePath: "/remote/\(name)",
            direction: .download,
            fileSize: fileSize,
            status: status,
            bytesTransferred: bytesTransferred,
            bytesPerSecond: bytesPerSecond
        )
    }

    // MARK: bytesTransferred

    @Test
    func bytesTransferredSumsChildren() {
        let items = [
            item(name: "a", bytesTransferred: 100),
            item(name: "b", bytesTransferred: 250),
            item(name: "c", bytesTransferred: 0),
        ]
        let summary = TransferGroupSummary(id: UUID(), name: "group", items: items, totalBytes: 1000)

        #expect(summary.bytesTransferred == 350)
    }

    // MARK: progress

    @Test
    func progressComputesFractionOfTotal() {
        let items = [item(bytesTransferred: 250)]
        let summary = TransferGroupSummary(id: UUID(), name: "group", items: items, totalBytes: 1000)

        #expect(summary.progress == 0.25)
    }

    @Test
    func progressIsZeroWhenTotalBytesIsNil() {
        let items = [item(bytesTransferred: 250)]
        let summary = TransferGroupSummary(id: UUID(), name: "group", items: items, totalBytes: nil)

        #expect(summary.progress == 0)
    }

    @Test
    func progressIsZeroWhenTotalBytesIsZero() {
        let items = [item(bytesTransferred: 0)]
        let summary = TransferGroupSummary(id: UUID(), name: "group", items: items, totalBytes: 0)

        #expect(summary.progress == 0)
    }

    // MARK: bytesPerSecond

    @Test
    func bytesPerSecondSumsOnlyInProgressChildren() {
        let items = [
            item(name: "a", status: .inProgress, bytesPerSecond: 100),
            item(name: "b", status: .inProgress, bytesPerSecond: 50),
            item(name: "c", status: .paused, bytesPerSecond: 999),
            item(name: "d", status: .completed, bytesPerSecond: 999),
        ]
        let summary = TransferGroupSummary(id: UUID(), name: "group", items: items, totalBytes: 1000)

        #expect(summary.bytesPerSecond == 150)
    }

    @Test
    func bytesPerSecondExcludesPausedChildSpeed() {
        let items = [
            item(name: "a", status: .paused, bytesPerSecond: 500),
        ]
        let summary = TransferGroupSummary(id: UUID(), name: "group", items: items, totalBytes: 1000)

        #expect(summary.bytesPerSecond == nil)
    }

    @Test
    func bytesPerSecondIsNilWhenNoInProgressItems() {
        let items = [
            item(name: "a", status: .completed, bytesPerSecond: nil),
            item(name: "b", status: .queued, bytesPerSecond: nil),
        ]
        let summary = TransferGroupSummary(id: UUID(), name: "group", items: items, totalBytes: 1000)

        #expect(summary.bytesPerSecond == nil)
    }

    @Test
    func bytesPerSecondIsNilWhenInProgressSpeedsAreAllNilOrZero() {
        let items = [
            item(name: "a", status: .inProgress, bytesPerSecond: nil),
            item(name: "b", status: .inProgress, bytesPerSecond: 0),
        ]
        let summary = TransferGroupSummary(id: UUID(), name: "group", items: items, totalBytes: 1000)

        #expect(summary.bytesPerSecond == nil)
    }

    // MARK: file counts

    @Test
    func fileCountsReflectChildStatuses() {
        let items = [
            item(name: "a", status: .completed),
            item(name: "b", status: .completed),
            item(name: "c", status: .failed),
            item(name: "d", status: .inProgress),
        ]
        let summary = TransferGroupSummary(id: UUID(), name: "group", items: items, totalBytes: 1000)

        #expect(summary.filesCompleted == 2)
        #expect(summary.filesFailed == 1)
        #expect(summary.filesTotal == 4)
    }

    // MARK: status priority

    @Test
    func statusIsInProgressWhenAnyChildIsInProgress() {
        let items = [
            item(name: "a", status: .completed),
            item(name: "b", status: .inProgress),
        ]
        let summary = TransferGroupSummary(id: UUID(), name: "group", items: items, totalBytes: 1000)

        #expect(summary.status == .inProgress)
    }

    @Test
    func statusIsInProgressWhenAnyChildIsQueued() {
        let items = [
            item(name: "a", status: .completed),
            item(name: "b", status: .queued),
        ]
        let summary = TransferGroupSummary(id: UUID(), name: "group", items: items, totalBytes: 1000)

        #expect(summary.status == .inProgress)
    }

    /// `inProgress` masks a `failed` sibling - the aggregate must still read as active.
    @Test
    func statusInProgressMasksFailedChild() {
        let items = [
            item(name: "a", status: .failed),
            item(name: "b", status: .inProgress),
        ]
        let summary = TransferGroupSummary(id: UUID(), name: "group", items: items, totalBytes: 1000)

        #expect(summary.status == .inProgress)
    }

    /// `paused` masks `failed`/`cancelled` siblings once nothing is active.
    @Test
    func statusPausedMasksFailedAndCancelledChildren() {
        let items = [
            item(name: "a", status: .failed),
            item(name: "b", status: .cancelled),
            item(name: "c", status: .paused),
        ]
        let summary = TransferGroupSummary(id: UUID(), name: "group", items: items, totalBytes: 1000)

        #expect(summary.status == .paused)
    }

    /// `failed` masks a `cancelled` sibling once nothing is active or paused.
    @Test
    func statusFailedMasksCancelledChild() {
        let items = [
            item(name: "a", status: .cancelled),
            item(name: "b", status: .failed),
        ]
        let summary = TransferGroupSummary(id: UUID(), name: "group", items: items, totalBytes: 1000)

        #expect(summary.status == .failed)
    }

    @Test
    func statusIsCancelledWhenOnlyCancelledAndCompletedChildren() {
        let items = [
            item(name: "a", status: .completed),
            item(name: "b", status: .cancelled),
        ]
        let summary = TransferGroupSummary(id: UUID(), name: "group", items: items, totalBytes: 1000)

        #expect(summary.status == .cancelled)
    }

    @Test
    func statusIsCompletedWhenAllChildrenCompleted() {
        let items = [
            item(name: "a", status: .completed),
            item(name: "b", status: .completed),
        ]
        let summary = TransferGroupSummary(id: UUID(), name: "group", items: items, totalBytes: 1000)

        #expect(summary.status == .completed)
    }

    // MARK: formattedProgress

    @Test
    func formattedProgressIncludesTotalWhenTotalBytesSet() {
        let items = [item(bytesTransferred: 500)]
        let summary = TransferGroupSummary(id: UUID(), name: "group", items: items, totalBytes: 1000)

        #expect(summary.formattedProgress.contains(" / "))
    }

    @Test
    func formattedProgressOmitsTotalWhenTotalBytesNil() {
        let items = [item(bytesTransferred: 500)]
        let summary = TransferGroupSummary(id: UUID(), name: "group", items: items, totalBytes: nil)

        #expect(!summary.formattedProgress.contains(" / "))
    }

    // MARK: formattedSpeed

    @Test
    func formattedSpeedIsNilWhenNoInProgressSpeed() {
        let items = [item(status: .completed, bytesPerSecond: nil)]
        let summary = TransferGroupSummary(id: UUID(), name: "group", items: items, totalBytes: 1000)

        #expect(summary.formattedSpeed == nil)
    }

    @Test
    func formattedSpeedIsNonNilStringWhenInProgressSpeedExists() {
        let items = [item(status: .inProgress, bytesPerSecond: 1024)]
        let summary = TransferGroupSummary(id: UUID(), name: "group", items: items, totalBytes: 1000)

        #expect(summary.formattedSpeed != nil)
        #expect(summary.formattedSpeed?.hasSuffix("/s") == true)
    }

    // MARK: filesSummary

    @Test
    func filesSummaryFormatsCompletedOverTotal() {
        let items = [
            item(name: "a", status: .completed),
            item(name: "b", status: .failed),
            item(name: "c", status: .inProgress),
        ]
        let summary = TransferGroupSummary(id: UUID(), name: "group", items: items, totalBytes: 1000)

        #expect(summary.filesSummary == "1/3 files")
    }

    // MARK: TransferQueueRow.id

    @Test
    func transferQueueRowIdReturnsItemIdForFileCase() {
        let file = item()
        let row = TransferQueueRow.file(file)

        #expect(row.id == file.id)
    }

    @Test
    func transferQueueRowIdReturnsSummaryIdForGroupCase() {
        let groupID = UUID()
        let summary = TransferGroupSummary(id: groupID, name: "group", items: [], totalBytes: nil)
        let row = TransferQueueRow.group(summary)

        #expect(row.id == groupID)
    }
}

import Foundation

/// A directory drag's queue entry: metadata for the aggregate row shown instead of one row
/// per file. The byte total starts unknown because it comes from a recursive listing pass
/// that runs concurrently with the download (see `FilePromiseDragSourceView.downloadDirectory`).
struct TransferGroup: Identifiable {
    let id: UUID
    let name: String
    var totalBytes: Int64?

    init(id: UUID = UUID(), name: String, totalBytes: Int64? = nil) {
        self.id = id
        self.name = name
        self.totalBytes = totalBytes
    }
}

/// Read-only rollup of a `TransferGroup`'s child `TransferItem`s, recomputed on demand by
/// `TransferQueueViewModel.rows` rather than stored — the children are the source of truth.
struct TransferGroupSummary: Identifiable {
    let id: UUID
    let name: String
    let items: [TransferItem]
    let totalBytes: Int64?

    var bytesTransferred: Int64 {
        items.reduce(0) { $0 + $1.bytesTransferred }
    }

    var progress: Double {
        guard let totalBytes, totalBytes > 0 else { return 0 }
        return Double(bytesTransferred) / Double(totalBytes)
    }

    var bytesPerSecond: Double? {
        let speed = items
            .filter { $0.status == .inProgress }
            .reduce(0.0) { $0 + ($1.bytesPerSecond ?? 0) }
        return speed > 0 ? speed : nil
    }

    var filesCompleted: Int { items.filter { $0.status == .completed }.count }
    var filesFailed: Int { items.filter { $0.status == .failed }.count }
    var filesTotal: Int { items.count }

    /// Priority order below mirrors what's actionable at the aggregate level: an active file
    /// anywhere means the row still reads as in-progress; once nothing's active, a paused file
    /// makes the row resumable, then a failed one makes it retryable, then cancelled — only
    /// once every file lands as `.completed` does the whole row.
    var status: TransferStatus {
        if items.contains(where: { $0.status == .inProgress || $0.status == .queued }) { return .inProgress }
        if items.contains(where: { $0.status == .paused }) { return .paused }
        if items.contains(where: { $0.status == .failed }) { return .failed }
        if items.contains(where: { $0.status == .cancelled }) { return .cancelled }
        return .completed
    }

    var formattedProgress: String {
        let transferred = ByteCountFormatter.string(fromByteCount: bytesTransferred, countStyle: .file)
        guard let totalBytes else { return transferred }
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(transferred) / \(total)"
    }

    var formattedSpeed: String? {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file)
        return "\(formatted)/s"
    }

    var filesSummary: String {
        "\(filesCompleted)/\(filesTotal) files"
    }
}

/// One row of the transfer queue as displayed: either a standalone file transfer, or the
/// aggregate row for a directory drag's group of file transfers.
enum TransferQueueRow: Identifiable {
    case file(TransferItem)
    case group(TransferGroupSummary)

    var id: UUID {
        switch self {
        case .file(let item): return item.id
        case .group(let summary): return summary.id
        }
    }
}

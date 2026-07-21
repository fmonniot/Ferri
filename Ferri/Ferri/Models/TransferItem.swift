import Foundation

enum TransferDirection: String, Codable {
    case upload
    case download
}

enum TransferStatus: String, Codable {
    case queued
    case inProgress
    case paused
    case completed
    case failed
    case cancelled
}

struct TransferItem: Identifiable, Codable {
    let id: UUID
    let fileName: String
    let localPath: String
    let remotePath: String
    let direction: TransferDirection
    let fileSize: Int64
    var status: TransferStatus
    var bytesTransferred: Int64
    var bytesPerSecond: Double?
    var errorMessage: String?
    /// Set when this file was downloaded as part of a directory drag — the queue displays
    /// such items rolled up under one `TransferGroup` row instead of individually.
    var groupID: UUID?

    init(
        id: UUID = UUID(),
        fileName: String,
        localPath: String,
        remotePath: String,
        direction: TransferDirection,
        fileSize: Int64 = 0,
        status: TransferStatus = .queued,
        bytesTransferred: Int64 = 0,
        bytesPerSecond: Double? = nil,
        errorMessage: String? = nil,
        groupID: UUID? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.localPath = localPath
        self.remotePath = remotePath
        self.direction = direction
        self.fileSize = fileSize
        self.status = status
        self.bytesTransferred = bytesTransferred
        self.bytesPerSecond = bytesPerSecond
        self.errorMessage = errorMessage
        self.groupID = groupID
    }
    
    var progress: Double {
        guard fileSize > 0 else { return 0 }
        return Double(bytesTransferred) / Double(fileSize)
    }
    
    var formattedProgress: String {
        let transferred = Self.byteFormatter.string(fromByteCount: bytesTransferred)
        let total = Self.byteFormatter.string(fromByteCount: fileSize)
        return "\(transferred) / \(total)"
    }

    var directionIcon: String {
        direction == .upload ? "arrow.up.circle" : "arrow.down.circle"
    }

    var formattedSpeed: String? {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        let formatted = Self.byteFormatter.string(fromByteCount: Int64(bytesPerSecond))
        return "\(formatted)/s"
    }

    /// `zeroPadsFractionDigits` keeps a consistent decimal-digit count (e.g. "500.0 MB" instead
    /// of "500 MB") so the text doesn't shrink and shift whenever a value rounds to a whole number.
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.zeroPadsFractionDigits = true
        return formatter
    }()
}

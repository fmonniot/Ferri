import Foundation

enum TransferDirection: String, Codable {
    case upload
    case download
}

enum TransferStatus: String, Codable {
    case queued
    case inProgress
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
        errorMessage: String? = nil
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
    }
    
    var progress: Double {
        guard fileSize > 0 else { return 0 }
        return Double(bytesTransferred) / Double(fileSize)
    }
    
    var formattedProgress: String {
        let transferred = ByteCountFormatter.string(fromByteCount: bytesTransferred, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        return "\(transferred) / \(total)"
    }
    
    var directionIcon: String {
        direction == .upload ? "arrow.up.circle" : "arrow.down.circle"
    }

    var formattedSpeed: String? {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file)
        return "\(formatted)/s"
    }
}

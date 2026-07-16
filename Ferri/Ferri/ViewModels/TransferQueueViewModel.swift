import Foundation
import Combine

@MainActor
final class TransferQueueViewModel: ObservableObject {
    @Published var transfers: [TransferItem] = []
    @Published var showCompleted = true
    
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
        transfers.removeAll { $0.id == id }
    }
    
    func clearCompleted() {
        transfers.removeAll { $0.status == .completed || $0.status == .failed || $0.status == .cancelled }
    }
    
    func cancelAll() {
        for index in transfers.indices {
            if transfers[index].status == .inProgress || transfers[index].status == .queued {
                transfers[index].status = .cancelled
            }
        }
    }
    
    func retryTransfer(id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }),
              transfers[index].status == .failed || transfers[index].status == .cancelled else {
            return
        }

        transfers[index].status = .queued
        transfers[index].bytesTransferred = 0
        transfers[index].errorMessage = nil
    }

    // TODO: stubbed for now — flips display state only. Actual SFTP stream
    // interruption/resume will be wired into the download path in a later session.
    func togglePause(id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }

        switch transfers[index].status {
        case .inProgress, .queued:
            transfers[index].status = .paused
        case .paused:
            transfers[index].status = .inProgress
        default:
            break
        }
    }
}

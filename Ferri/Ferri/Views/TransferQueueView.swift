import SwiftUI

struct TransferQueueView: View {
    @ObservedObject var viewModel: TransferQueueViewModel
    @Binding var isExpanded: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            
            HStack {
                Text("Transfers")
                    .font(.headline)
                
                Spacer()
                
                if !viewModel.completedTransfers.isEmpty {
                    Button("Clear Completed") {
                        viewModel.clearCompleted()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                
                if !viewModel.activeTransfers.isEmpty {
                    Button("Cancel All") {
                        viewModel.cancelAll()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                
                Button(action: {
                    withAnimation {
                        isExpanded.toggle()
                    }
                }) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            
            if isExpanded {
                if viewModel.transfers.isEmpty {
                    emptyView
                } else {
                    transferList
                }
            }
        }
        .frame(height: isExpanded ? 200 : 44)
    }
    
    private var emptyView: some View {
        VStack {
            Text("No transfers")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var transferList: some View {
        List {
            ForEach(viewModel.transfers) { transfer in
                TransferRow(transfer: transfer) {
                    viewModel.removeTransfer(id: transfer.id)
                } onRetry: {
                    viewModel.retryTransfer(id: transfer.id)
                }
            }
        }
        .listStyle(.plain)
    }
}

struct TransferRow: View {
    let transfer: TransferItem
    let onRemove: () -> Void
    let onRetry: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transfer.directionIcon)
                .foregroundColor(transfer.direction == .upload ? .blue : .green)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.fileName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                
                if transfer.status == .inProgress {
                    ProgressView(value: transfer.progress)
                        .progressViewStyle(.linear)

                    HStack(spacing: 4) {
                        Text(transfer.formattedProgress)
                        if let speed = transfer.formattedSpeed {
                            Text("·")
                            Text(speed)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                } else if let error = transfer.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(1)
                } else if transfer.status == .completed {
                    Text("Completed")
                        .font(.caption)
                        .foregroundColor(.green)
                } else if transfer.status == .cancelled {
                    Text("Cancelled")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            
            Spacer()
            
            if transfer.status == .failed {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Retry")
            }
            
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
        .padding(.vertical, 4)
    }
}

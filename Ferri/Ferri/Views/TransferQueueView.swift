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

                Text(viewModel.summaryText)
                    .font(.caption)
                    .foregroundColor(.secondary)

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
                if viewModel.rows.isEmpty {
                    emptyView
                } else {
                    transferList
                }
            }
        }
        // Collapsed: pinned to the 44pt header. Expanded: a resizable pane the enclosing
        // VSplitView divider can drag between a sensible minimum and the available height.
        .frame(
            minHeight: isExpanded ? 120 : 44,
            maxHeight: isExpanded ? .infinity : 44
        )
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
            ForEach(viewModel.rows) { row in
                switch row {
                case .file(let transfer):
                    TransferRow(transfer: transfer) {
                        viewModel.removeTransfer(id: transfer.id)
                    } onRetry: {
                        viewModel.retryTransfer(id: transfer.id)
                    } onTogglePause: {
                        viewModel.togglePause(id: transfer.id)
                    }
                case .group(let summary):
                    TransferGroupRow(summary: summary, viewModel: viewModel)
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
    let onTogglePause: () -> Void

    private var badgeColor: Color {
        switch transfer.status {
        case .failed: .red
        case .paused: .orange
        default: .accentColor
        }
    }

    private var canPause: Bool {
        transfer.status == .inProgress || transfer.status == .paused || transfer.status == .queued
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transfer.directionIcon)
                .foregroundColor(badgeColor)
                .frame(width: 22, height: 22)
                .background(badgeColor.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.fileName)
                    .font(.system(size: 13))
                    .lineLimit(1)

                if transfer.status == .inProgress || transfer.status == .paused {
                    ProgressView(value: transfer.progress)
                        .progressViewStyle(.linear)
                        .tint(badgeColor)

                    HStack(spacing: 4) {
                        Text(transfer.formattedProgress)
                            .monospacedDigit()
                            .frame(minWidth: 108, alignment: .leading)
                        if transfer.status == .paused {
                            Text("· Paused")
                                .foregroundColor(.orange)
                        } else if let speed = transfer.formattedSpeed {
                            Text("·")
                            Text(speed)
                                .monospacedDigit()
                                .frame(minWidth: 64, alignment: .leading)
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

            if canPause {
                Button(action: onTogglePause) {
                    Image(systemName: transfer.status == .paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.borderless)
                .help(transfer.status == .paused ? "Resume" : "Pause")
            }

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

/// The aggregate row for a directory drag: one line summarizing every file under it, with a
/// disclosure to drop down into the same per-file `TransferRow`s a standalone download gets —
/// pause/retry/remove on those rows still act on just that one file.
struct TransferGroupRow: View {
    let summary: TransferGroupSummary
    @ObservedObject var viewModel: TransferQueueViewModel
    @State private var isExpanded = false

    private var badgeColor: Color {
        switch summary.status {
        case .failed: .red
        case .paused: .orange
        default: .accentColor
        }
    }

    private var canPause: Bool {
        summary.status == .inProgress || summary.status == .paused || summary.status == .queued
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    withAnimation { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.borderless)

                Image(systemName: "folder.fill")
                    .foregroundColor(badgeColor)
                    .frame(width: 22, height: 22)
                    .background(badgeColor.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.name)
                        .font(.system(size: 13))
                        .lineLimit(1)

                    if summary.status == .inProgress || summary.status == .paused {
                        ProgressView(value: summary.progress)
                            .progressViewStyle(.linear)
                            .tint(badgeColor)

                        HStack(spacing: 4) {
                            Text(summary.formattedProgress)
                                .monospacedDigit()
                                .frame(minWidth: 108, alignment: .leading)
                            Text("·")
                            Text(summary.filesSummary)
                                .monospacedDigit()
                            if summary.status == .paused {
                                Text("· Paused")
                                    .foregroundColor(.orange)
                            } else if let speed = summary.formattedSpeed {
                                Text("·")
                                Text(speed)
                                    .monospacedDigit()
                                    .frame(minWidth: 64, alignment: .leading)
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    } else if summary.status == .failed {
                        Text("\(summary.filesFailed) of \(summary.filesTotal) files failed")
                            .font(.caption)
                            .foregroundColor(.red)
                    } else if summary.status == .completed {
                        Text("Completed · \(summary.filesSummary)")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else if summary.status == .cancelled {
                        Text("Cancelled")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }

                Spacer()

                if canPause {
                    Button {
                        viewModel.toggleGroupPause(id: summary.id)
                    } label: {
                        Image(systemName: summary.status == .paused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.borderless)
                    .help(summary.status == .paused ? "Resume All" : "Pause All")
                }

                if summary.status == .failed {
                    Button {
                        viewModel.retryGroupFailed(id: summary.id)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Retry Failed")
                }

                Button {
                    viewModel.removeGroup(id: summary.id)
                } label: {
                    Image(systemName: "xmark")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove")
            }
            .padding(.vertical, 4)

            if isExpanded {
                ForEach(summary.items) { transfer in
                    TransferRow(transfer: transfer) {
                        viewModel.removeTransfer(id: transfer.id)
                    } onRetry: {
                        viewModel.retryTransfer(id: transfer.id)
                    } onTogglePause: {
                        viewModel.togglePause(id: transfer.id)
                    }
                    .padding(.leading, 34)
                }
            }
        }
    }
}

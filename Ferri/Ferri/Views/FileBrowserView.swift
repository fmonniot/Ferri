import SwiftUI
import FTPClient

struct FileBrowserView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @ObservedObject var transferQueue: TransferQueueViewModel
    let isConnected: Bool
    let hostLabel: String

    @State private var selectedFiles: Set<RemoteFile.ID> = []
    @State private var infoFile: RemoteFile?
    @State private var sortComparators: [KeyPathComparator<RemoteFile>] = [
        KeyPathComparator(\.name, order: .forward)
    ]

    var body: some View {
        VStack(spacing: 0) {
            if isConnected {
                pathBar
            }
            if !isConnected {
                emptyStateView
            } else if viewModel.isLoading {
                loadingView
            } else if viewModel.isPermissionDenied {
                permissionDeniedView
            } else if let error = viewModel.errorMessage {
                errorView(error)
            } else if viewModel.files.isEmpty {
                emptyDirectoryView
            } else {
                fileTableView
            }
        }
        .navigationTitle(hostLabel.isEmpty ? "Ferri" : hostLabel)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: { viewModel.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!viewModel.canGoBack)

                Button(action: { viewModel.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!viewModel.canGoForward)

                Button(action: { Task { await viewModel.goUp() } }) {
                    Image(systemName: "arrow.up")
                }
                .disabled(!viewModel.canGoUp)

                Button(action: { Task { await viewModel.refresh() } }) {
                    Image(systemName: "arrow.clockwise")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Refresh") {
                        Task { await viewModel.refresh() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $infoFile) { file in
            GetInfoView(file: file)
        }
    }

    // MARK: - Path bar

    private var pathBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "server.rack")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                Button {
                    navigateBreadcrumb(to: crumb.path)
                } label: {
                    Text(crumb.label)
                        .font(.system(size: 12, weight: index == breadcrumbs.count - 1 ? .semibold : .medium))
                        .foregroundColor(index == breadcrumbs.count - 1 ? .primary : .secondary)
                }
                .buttonStyle(.plain)

                if index < breadcrumbs.count - 1 {
                    Text("›")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }

            Spacer(minLength: 8)

            if !viewModel.isLoading && viewModel.errorMessage == nil && !viewModel.isPermissionDenied {
                Text(itemCountText)
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var breadcrumbs: [(label: String, path: String)] {
        var result: [(label: String, path: String)] = [(hostLabel.isEmpty ? "Server" : hostLabel, "/")]

        let parts = viewModel.currentPath.split(separator: "/").map(String.init)
        var accumulated = ""
        for part in parts {
            accumulated += "/" + part
            result.append((part, accumulated))
        }
        return result
    }

    private var itemCountText: String {
        let count = viewModel.files.count
        return "\(count) item\(count == 1 ? "" : "s")"
    }

    private func navigateBreadcrumb(to path: String) {
        Task { await viewModel.loadDirectory(at: path) }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("Not Connected")
                .font(.title2)
                .fontWeight(.medium)
            Text("Select a connection from the sidebar to browse files")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.red)
            Text("Error")
                .font(.title2)
                .fontWeight(.medium)
            Text(error)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Button("Retry") {
                Task { await viewModel.refresh() }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("Permission Denied")
                .font(.title2)
                .fontWeight(.medium)
            Text("You don't have permission to access this folder")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Go Back") {
                Task { await viewModel.goUp() }
            }
            .disabled(!viewModel.canGoUp)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyDirectoryView: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("Empty Folder")
                .font(.title2)
                .fontWeight(.medium)
            Text("This folder is empty")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileTableView: some View {
        Table(filesTableItems, selection: $selectedFiles, sortOrder: $sortComparators) {
            TableColumn("Name", value: \.name) { file in
                rowCell(isSelected: selectedFiles.contains(file.id)) {
                    HStack(spacing: 8) {
                        fileIcon(for: file)
                        Text(file.name)
                    }
                }
                .overlay {
                    FilePromiseDragSource(file: file)
                }
            }
            .width(min: 200, ideal: 300)

            TableColumn("Size", value: \.size) { file in
                rowCell(isSelected: selectedFiles.contains(file.id), unselectedColor: .secondary) {
                    Text(file.formattedSize)
                        .monospacedDigit()
                }
            }
            .width(80)

            TableColumn("Date Modified", value: \.sortDate) { file in
                rowCell(isSelected: selectedFiles.contains(file.id), unselectedColor: .secondary) {
                    Text(file.formattedDate)
                }
            }
            .width(150)

            TableColumn("Permissions", value: \.permissions) { file in
                rowCell(isSelected: selectedFiles.contains(file.id), unselectedColor: .secondary) {
                    Text(file.permissions)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .width(100)
        }
        .onChange(of: sortComparators) { _, comparators in
            applySort(comparators)
        }
        .contextMenu(forSelectionType: RemoteFile.ID.self) { items in
            if let fileId = items.first,
               let file = viewModel.files.first(where: { $0.id == fileId }) {
                if !file.isDirectory {
                    Button("Download") {
                        downloadFile(file)
                    }
                }
                Button("Get Info") {
                    infoFile = file
                }
                Divider()
                Button("Copy Path") {
                    copyPath(file)
                }
            }
        } primaryAction: { items in
            if let fileId = items.first,
               let file = viewModel.files.first(where: { $0.id == fileId }),
               file.isDirectory {
                Task {
                    await viewModel.navigateToFolder(file)
                }
            }
        }
    }

    @ViewBuilder
    private func rowCell<Content: View>(
        isSelected: Bool,
        unselectedColor: Color = .primary,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .foregroundColor(isSelected ? .white : unselectedColor)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor : Color.clear)
    }

    @ViewBuilder
    private func fileIcon(for file: RemoteFile) -> some View {
        if file.isDirectory {
            Image(systemName: "folder.fill")
                .foregroundColor(.blue)
        } else {
            let meta = FileTypeMeta(fileName: file.name)
            Text(meta.label)
                .font(.system(size: 8, weight: .heavy))
                .foregroundColor(.white)
                .padding(.horizontal, 3)
                .frame(minWidth: 24, minHeight: 14)
                .background(meta.color)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }

    private var filesTableItems: [RemoteFile] {
        viewModel.files
    }

    private func downloadFile(_ file: RemoteFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name

        if panel.runModal() == .OK, let url = panel.url {
            viewModel.downloadFile(file, to: url, transferQueue: transferQueue)
        }
    }

    private func copyPath(_ file: RemoteFile) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.path, forType: .string)
    }

    /// Translate the table's native sort comparator into a VM sort so the view model stays the
    /// single source of truth (it keeps directories sorted before files regardless of column).
    private func applySort(_ comparators: [KeyPathComparator<RemoteFile>]) {
        guard let comparator = comparators.first else { return }

        let column: SortColumn
        switch comparator.keyPath {
        case \RemoteFile.name: column = .name
        case \RemoteFile.size: column = .size
        case \RemoteFile.sortDate: column = .date
        case \RemoteFile.permissions: column = .permissions
        default: return
        }

        viewModel.applySort(column: column, ascending: comparator.order == .forward)
    }
}

private extension RemoteFile {
    /// A non-optional sort key for the "Date Modified" column; `KeyPathComparator` needs a
    /// `Comparable` key path and `Date?` is not comparable. Missing dates sort oldest-first.
    var sortDate: Date { modificationDate ?? .distantPast }
}

// MARK: - File type badge

private struct FileTypeMeta {
    let label: String
    let color: Color

    private static let map: [String: (label: String, hex: String)] = [
        "sh": ("SH", "#8e44ad"), "md": ("MD", "#3b6fb5"), "txt": ("TXT", "#7a7a80"),
        "png": ("PNG", "#e07b39"), "jpg": ("JPG", "#e07b39"), "sql": ("SQL", "#c0562b"),
        "gz": ("GZ", "#5a6b7a"), "html": ("HTML", "#e0603a"), "css": ("CSS", "#2f77c4"),
        "js": ("JS", "#c9a227"), "json": ("JSON", "#c9a227"), "log": ("LOG", "#5a6b7a"),
        "htaccess": ("CFG", "#7a7a80"), "bashrc": ("CFG", "#7a7a80"), "tmp": ("TMP", "#7a7a80"),
    ]

    init(fileName: String) {
        let lower = fileName.lowercased()
        let ext: String
        if let dotIndex = lower.lastIndex(of: "."), dotIndex != lower.startIndex {
            ext = String(lower[lower.index(after: dotIndex)...])
        } else if lower.hasPrefix(".") {
            ext = String(lower.dropFirst())
        } else {
            ext = "txt"
        }

        if let entry = Self.map[ext] {
            label = entry.label
            color = Color(hex: entry.hex)
        } else {
            label = String(ext.prefix(3)).uppercased()
            color = Color(hex: "#7a7a80")
        }
    }
}

private extension Color {
    init(hex: String) {
        var hexValue = UInt64()
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&hexValue)
        let r = Double((hexValue & 0xFF0000) >> 16) / 255
        let g = Double((hexValue & 0x00FF00) >> 8) / 255
        let b = Double(hexValue & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Get Info

private struct GetInfoView: View {
    let file: RemoteFile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: file.icon)
                    .font(.system(size: 28))
                    .foregroundColor(file.isDirectory ? .blue : .secondary)
                Text(file.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                infoRow("Path", file.path)
                infoRow("Size", file.formattedSize)
                infoRow("Modified", file.formattedDate)
                infoRow("Permissions", file.permissions)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340, height: 220)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.system(size: 12.5))
    }
}

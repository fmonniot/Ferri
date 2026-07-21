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
    /// Persists per-column widths and show/hide state to UserDefaults automatically; the
    /// show/hide and reorder UI is the native right-click-on-header menu Table provides for free.
    @AppStorage("FileBrowserView.columnCustomization") private var columnCustomization: TableColumnCustomization<RemoteFile>

    var body: some View {
        VStack(spacing: 0) {
            if isConnected {
                pathBar
            }
            if let warning = viewModel.initialDirectoryWarning {
                initialDirectoryWarningBanner(warning)
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
                .accessibilityIdentifier("nav.back")

                Button(action: { viewModel.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!viewModel.canGoForward)
                .accessibilityIdentifier("nav.forward")

                Button(action: { Task { await viewModel.goUp() } }) {
                    Image(systemName: "arrow.up")
                }
                .disabled(!viewModel.canGoUp)
                .accessibilityIdentifier("nav.up")

                Button(action: { Task { await viewModel.refresh() } }) {
                    Image(systemName: "arrow.clockwise")
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

    private func initialDirectoryWarningBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(.yellow)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("initialDirectoryWarning.message")
            Spacer(minLength: 8)
            Button {
                viewModel.dismissInitialDirectoryWarning()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("initialDirectoryWarning.dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.12))
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

    /// Uses the `of:columns:rows:` Table form with a per-row `.contextMenu` for the Download/Get
    /// Info/Copy Path menu, rather than `.contextMenu(forSelectionType:menu:primaryAction:)`'s
    /// `menu:` closure - the latter swallows secondary clicks on the column headers too, which
    /// blocks the native header menu that shows/hides columns via `columnCustomization`. The
    /// table-level modifier is kept only for its `primaryAction:` (double-click/Return to open a
    /// folder), which doesn't have that conflict since it's not a secondary-click affordance.
    private var fileTableView: some View {
        Table(of: RemoteFile.self, selection: $selectedFiles, sortOrder: $sortComparators, columnCustomization: $columnCustomization) {
            TableColumn("Name", value: \.name) { file in
                rowCell(isSelected: selectedFiles.contains(file.id)) {
                    HStack(spacing: 8) {
                        fileIcon(for: file)
                        Text(file.name)
                            .accessibilityIdentifier("file.\(file.name)")
                    }
                }
                .overlay {
                    FilePromiseDragSource(file: file, selectedFiles: selectedRemoteFiles, transferQueue: transferQueue)
                }
            }
            .width(min: 200, ideal: 300)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Size", value: \.size) { file in
                rowCell(isSelected: selectedFiles.contains(file.id), unselectedColor: .secondary) {
                    Text(file.formattedSize)
                        .monospacedDigit()
                }
            }
            .width(min: 50, ideal: 80, max: 150)
            .customizationID("size")

            TableColumn("Date Modified", value: \.sortDate) { file in
                rowCell(isSelected: selectedFiles.contains(file.id), unselectedColor: .secondary) {
                    Text(file.formattedDate)
                }
            }
            .width(min: 100, ideal: 150, max: 260)
            .customizationID("date")

            TableColumn("Permissions", value: \.permissions) { file in
                rowCell(isSelected: selectedFiles.contains(file.id), unselectedColor: .secondary) {
                    Text(file.permissions)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .width(min: 70, ideal: 100, max: 160)
            .customizationID("permissions")
        } rows: {
            ForEach(filesTableItems) { file in
                TableRow(file)
                    .contextMenu {
                        let selection = effectiveSelection(for: file)
                        Button(selection.count > 1 ? "Download \(selection.count) Items" : "Download") {
                            downloadSelection(selection)
                        }
                        if selection.count == 1 {
                            Button("Get Info") {
                                infoFile = file
                            }
                            Divider()
                            Button("Copy Path") {
                                copyPath(file)
                            }
                        }
                    }
            }
        }
        .onChange(of: sortComparators) { _, comparators in
            applySort(comparators)
        }
        // Empty `menu:` closure so this only supplies double-click/Return-to-open via
        // `primaryAction:` (native NSTableView doubleAction) - the row's own `.contextMenu`
        // above supplies the actual right-click menu, since attaching real content here
        // was found to swallow secondary clicks on the column headers too, blocking the
        // native header menu that shows/hides columns via `columnCustomization`.
        .contextMenu(forSelectionType: RemoteFile.ID.self) { _ in
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

    /// The right-clicked row's siblings to act on: the whole current selection when the row is
    /// part of a multi-item selection, or just that one row otherwise — the standard Finder
    /// convention for right-clicking within vs. outside a selection.
    private func effectiveSelection(for file: RemoteFile) -> [RemoteFile] {
        guard selectedFiles.contains(file.id), selectedFiles.count > 1 else { return [file] }
        return viewModel.files.filter { selectedFiles.contains($0.id) }
    }

    /// The current selection resolved to `RemoteFile`s, handed to each row's drag source so a drag
    /// begun on a selected row promises every selected item (the drag equivalent of the context
    /// menu's "Download N Items"). The drag source itself decides whether the grabbed row is
    /// actually part of this selection.
    private var selectedRemoteFiles: [RemoteFile] {
        viewModel.files.filter { selectedFiles.contains($0.id) }
    }

    /// A lone plain file keeps the existing NSSavePanel flow (choose the exact destination file,
    /// optionally renaming it). Anything else — multiple items, or a single directory — needs a
    /// destination *folder* instead, since every item keeps its remote name.
    private func downloadSelection(_ files: [RemoteFile]) {
        guard !files.isEmpty else { return }

        if files.count == 1, let file = files.first, !file.isDirectory {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = file.name
            if panel.runModal() == .OK, let url = panel.url {
                viewModel.downloadFile(file, to: url, transferQueue: transferQueue)
            }
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Download"
        panel.message = files.count == 1
            ? "Choose where to download “\(files[0].name)”"
            : "Choose where to download \(files.count) items"

        if panel.runModal() == .OK, let destinationDir = panel.url {
            viewModel.downloadFiles(files, to: destinationDir, transferQueue: transferQueue)
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

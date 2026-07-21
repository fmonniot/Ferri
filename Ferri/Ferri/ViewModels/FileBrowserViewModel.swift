import Foundation
import Combine
import FTPClient

enum SortOrder {
    case ascending
    case descending
}

enum SortColumn {
    case name
    case size
    case date
    case permissions
}

@MainActor
final class FileBrowserViewModel: ObservableObject {
    @Published var files: [RemoteFile] = []
    @Published var currentPath: String = "/"
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isPermissionDenied = false
    @Published var sortColumn: SortColumn = .name
    @Published var sortOrder: SortOrder = .ascending

    /// Set when `loadInitialDirectory` had to fall back to `/` because the connection's
    /// configured starting folder failed to load. Dismissible rather than a hard error, since
    /// the browser recovers on its own by showing root instead.
    @Published var initialDirectoryWarning: String?
    
    @Published var pathHistory: [String] = []
    @Published var historyIndex: Int = -1
    
    private let ftpClient: any FTPClientProtocol
    private weak var connectionViewModel: ConnectionListViewModel?
    
    var canGoBack: Bool {
        historyIndex > 0
    }
    
    var canGoForward: Bool {
        historyIndex < pathHistory.count - 1
    }
    
    var canGoUp: Bool {
        currentPath != "/"
    }
    
    init(ftpClient: any FTPClientProtocol = FTPClient.shared, connectionViewModel: ConnectionListViewModel? = nil) {
        self.ftpClient = ftpClient
        self.connectionViewModel = connectionViewModel
    }
    
    func setConnectionViewModel(_ viewModel: ConnectionListViewModel) {
        self.connectionViewModel = viewModel
    }
    
    func loadDirectory(at path: String = "") async {
        await performLoad(at: path)
        addToHistory(currentPath)
    }

    /// Loads a saved connection's configured starting folder right after connecting. Unlike
    /// plain `loadDirectory`, a failure here (misconfigured `initialDirectoryPath` - nonexistent
    /// or unreadable on the server) falls back to `/` instead of leaving the browser stuck on a
    /// hard error, and surfaces the reason as a dismissible `initialDirectoryWarning` instead.
    func loadInitialDirectory(at path: String) async {
        // Connecting to a different server doesn't call `reset()` (see `MainView.connect`), so
        // without this a warning left over from a previous connection's fallback would still be
        // showing even though this connection's starting folder loaded fine.
        initialDirectoryWarning = nil

        let target = path.isEmpty ? "/" : path
        await performLoad(at: target)

        if target != "/", errorMessage != nil || isPermissionDenied {
            let reason = isPermissionDenied
                ? "You don't have permission to access it."
                : (errorMessage ?? "It could not be opened.")
            errorMessage = nil
            isPermissionDenied = false
            await performLoad(at: "/")
            initialDirectoryWarning = "Couldn't open the configured starting folder \"\(target)\": \(reason) Showing the root directory instead."
        }

        addToHistory(currentPath)
    }

    func dismissInitialDirectoryWarning() {
        initialDirectoryWarning = nil
    }

    func refresh() async {
        await loadDirectory(at: currentPath)
    }

    func navigateToFolder(_ folder: RemoteFile) async {
        guard folder.isDirectory else { return }
        await loadDirectory(at: folder.path)
    }

    func goUp() async {
        guard canGoUp else { return }
        await loadDirectory(at: "..")
    }

    /// Moves within the existing `pathHistory` stack rather than pushing a new entry -
    /// unlike `loadDirectory`, this must not call `addToHistory` or it would truncate
    /// the forward/back entries it's supposed to be navigating through.
    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        let path = pathHistory[historyIndex]
        Task {
            await performLoad(at: path)
        }
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        let path = pathHistory[historyIndex]
        Task {
            await performLoad(at: path)
        }
    }

    private func performLoad(at path: String) async {
        isLoading = true
        errorMessage = nil
        isPermissionDenied = false

        do {
            let result = try await ftpClient.listDirectory(at: path)
            files = sortFiles(result)
            currentPath = ftpClient.currentPath
        } catch {
            // A dropped connection (laptop sleep, network blip) surfaces as some non-protocol
            // error from listDirectory rather than a clean "not connected" signal, since the dead
            // channel is only ever detected on next use. Reconnecting is the one recovery worth
            // attempting automatically; anything the server itself rejected (SFTPClientError
            // .requestFailed, e.g. permission denied) is not a connection problem and reconnecting
            // wouldn't help.
            if isReconnectWorthy(error), let server = connectionViewModel?.selectedConnection {
                await reconnectAndRetry(server: server, path: path)
            } else {
                applyLoadError(error)
            }
        }

        isLoading = false
    }

    private func isReconnectWorthy(_ error: Error) -> Bool {
        if case SFTPClientError.requestFailed = error { return false }
        return true
    }

    private func reconnectAndRetry(server: FTPServer, path: String) async {
        do {
            try await ftpClient.connect(to: server)
            let result = try await ftpClient.listDirectory(at: path)
            files = sortFiles(result)
            currentPath = ftpClient.currentPath
        } catch {
            errorMessage = "The connection was lost and could not be re-established: \(error.localizedDescription)"
        }
    }

    private func applyLoadError(_ error: Error) {
        // SFTP status code 3 is SSH_FX_PERMISSION_DENIED (SFTPv3 spec).
        if case SFTPClientError.requestFailed(let code, _) = error, code == 3 {
            isPermissionDenied = true
        } else {
            errorMessage = error.localizedDescription
        }
    }
    
    func sortBy(_ column: SortColumn) {
        if sortColumn == column {
            sortOrder = sortOrder == .ascending ? .descending : .ascending
        } else {
            sortColumn = column
            sortOrder = .ascending
        }
        files = sortFiles(files)
    }

    /// Apply an explicit column + direction (as opposed to `sortBy`'s toggle-on-repeat behavior).
    /// Used by the file table's native sortable headers, which already carry their own direction.
    func applySort(column: SortColumn, ascending: Bool) {
        sortColumn = column
        sortOrder = ascending ? .ascending : .descending
        files = sortFiles(files)
    }
    
    private func sortFiles(_ files: [RemoteFile]) -> [RemoteFile] {
        let sorted = files.sorted { file1, file2 in
            if file1.isDirectory != file2.isDirectory {
                return file1.isDirectory
            }
            
            let result: Bool
            switch sortColumn {
            case .name:
                result = file1.name.localizedCaseInsensitiveCompare(file2.name) == .orderedAscending
            case .size:
                result = file1.size < file2.size
            case .date:
                let date1 = file1.modificationDate ?? Date.distantPast
                let date2 = file2.modificationDate ?? Date.distantPast
                result = date1 < date2
            case .permissions:
                result = file1.permissions < file2.permissions
            }
            
            return sortOrder == .ascending ? result : !result
        }
        
        return sorted
    }
    
    private func addToHistory(_ path: String) {
        if historyIndex < pathHistory.count - 1 {
            pathHistory.removeSubrange((historyIndex + 1)...)
        }
        
        if pathHistory.last != path {
            pathHistory.append(path)
            historyIndex = pathHistory.count - 1
        }
    }
    
    func reset() {
        files = []
        currentPath = "/"
        isLoading = false
        errorMessage = nil
        isPermissionDenied = false
        initialDirectoryWarning = nil
        pathHistory = []
        historyIndex = -1
    }

    func downloadFile(_ file: RemoteFile, to localURL: URL, transferQueue: TransferQueueViewModel) {
        // The transfer queue owns the download lifecycle (progress, speed, pause/resume),
        // so it can interrupt and resume the underlying SFTP stream.
        transferQueue.startDownload(file: file, to: localURL)
    }

    /// Downloads every item in `files` into `destinationDir`, each keeping its remote name. A
    /// lone plain file is exempted from this (see `FileBrowserView.downloadSelection`, which
    /// routes that case through `downloadFile` with a user-chosen destination file instead) —
    /// everything else (multiple items, or any directory) rolls up under one aggregate
    /// `TransferGroup` row instead of flooding the queue with one row per file.
    func downloadFiles(_ files: [RemoteFile], to destinationDir: URL, transferQueue: TransferQueueViewModel) {
        guard !files.isEmpty else { return }

        let groupName = files.count == 1 ? files[0].name : "\(files.count) items"
        let groupID = transferQueue.startGroup(name: groupName)

        // Plain files' sizes are already known from the directory listing; a selected
        // directory's own size only lands once its sizing pass (in `downloadDirectoryIntoGroup`)
        // finishes, so the group's total starts from just what's known now.
        let knownBytes = files.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
        if knownBytes > 0 {
            transferQueue.addToGroupTotalBytes(id: groupID, bytes: knownBytes)
        }

        for file in files {
            let destinationURL = destinationDir.appendingPathComponent(file.name)
            if file.isDirectory {
                downloadDirectoryIntoGroup(file, to: destinationURL, groupID: groupID, transferQueue: transferQueue)
            } else {
                transferQueue.startDownload(file: file, to: destinationURL, groupID: groupID)
            }
        }
    }

    /// Sizes and recursively downloads one directory selected alongside other items, adding its
    /// total to the shared group once known. Mirrors `FilePromiseDragSourceView.downloadDirectory`'s
    /// concurrent sizing pass, minus the Finder-badge plumbing that path needs and this one doesn't.
    private func downloadDirectoryIntoGroup(_ file: RemoteFile, to localURL: URL, groupID: UUID, transferQueue: TransferQueueViewModel) {
        let ftpClient = self.ftpClient
        Task { @MainActor in
            let sizing = Task { @MainActor in
                guard let sized = try? await ftpClient.listDirectoryRecursively(at: file.path) else { return }
                let total = sized.reduce(Int64(0)) { $0 + $1.size }
                transferQueue.addToGroupTotalBytes(id: groupID, bytes: total)
            }
            defer { sizing.cancel() }

            try? await RemoteDownloader.downloadTree(remotePath: file.path, to: localURL, groupID: groupID, ftpClient: ftpClient, transferQueue: transferQueue)

            // An empty directory never downloads a file to hang the group's aggregate off of;
            // harmless no-op otherwise since other items in the group are still present.
            transferQueue.removeGroupIfEmpty(id: groupID)
        }
    }
}

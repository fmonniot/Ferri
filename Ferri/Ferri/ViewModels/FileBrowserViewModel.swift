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
            // SFTP status code 3 is SSH_FX_PERMISSION_DENIED (SFTPv3 spec).
            if case SFTPClientError.requestFailed(let code, _) = error, code == 3 {
                isPermissionDenied = true
            } else {
                errorMessage = error.localizedDescription
            }
        }

        isLoading = false
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
        pathHistory = []
        historyIndex = -1
    }

    func downloadFile(_ file: RemoteFile, to localURL: URL, transferQueue: TransferQueueViewModel) {
        // The transfer queue owns the download lifecycle (progress, speed, pause/resume),
        // so it can interrupt and resume the underlying SFTP stream.
        transferQueue.startDownload(file: file, to: localURL)
    }
}

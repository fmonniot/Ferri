import Foundation
import Combine

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
    @Published var sortColumn: SortColumn = .name
    @Published var sortOrder: SortOrder = .ascending
    
    @Published var pathHistory: [String] = []
    @Published var historyIndex: Int = -1
    
    private let ftpClient = FTPClient.shared
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
    
    init(connectionViewModel: ConnectionListViewModel? = nil) {
        self.connectionViewModel = connectionViewModel
    }
    
    func setConnectionViewModel(_ viewModel: ConnectionListViewModel) {
        self.connectionViewModel = viewModel
    }
    
    func loadDirectory(at path: String = "") async {
        isLoading = true
        errorMessage = nil
        
        do {
            let result = try await ftpClient.listDirectory(at: path)
            files = sortFiles(result)
            currentPath = ftpClient.currentPath
            
            addToHistory(currentPath)
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
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
    
    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        let path = pathHistory[historyIndex]
        Task {
            await loadDirectory(at: path)
        }
    }
    
    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        let path = pathHistory[historyIndex]
        Task {
            await loadDirectory(at: path)
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
    
    func createFolder(named name: String) async throws {
        try await ftpClient.createDirectory(named: name)
        await refresh()
    }
    
    func deleteFile(_ file: RemoteFile) async throws {
        if file.isDirectory {
            try await ftpClient.deleteDirectory(named: file.name)
        } else {
            try await ftpClient.deleteFile(named: file.name)
        }
        await refresh()
    }
    
    func renameFile(_ file: RemoteFile, to newName: String) async throws {
        try await ftpClient.rename(from: file.name, to: newName)
        await refresh()
    }
    
    func downloadFile(_ file: RemoteFile, to localURL: URL, transferQueue: TransferQueueViewModel) {
        let item = TransferItem(
            fileName: file.name,
            localPath: localURL.path,
            remotePath: file.path,
            direction: .download,
            fileSize: file.size,
            status: .queued
        )
        transferQueue.addTransfer(item)
        
        Task {
            do {
                try await ftpClient.downloadFile(named: file.name, to: localURL)
            } catch {
                print("Download failed: \(error)")
            }
        }
    }
}

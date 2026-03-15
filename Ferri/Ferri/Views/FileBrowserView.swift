import SwiftUI
import UniformTypeIdentifiers
import FTPClient

struct FileBrowserView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @ObservedObject var transferQueue: TransferQueueViewModel
    let isConnected: Bool
    
    @State private var selectedFiles: Set<RemoteFile.ID> = []
    @State private var showingNewFolderSheet = false
    @State private var newFolderName = ""
    @State private var showingRenameAlert = false
    @State private var renameFile: RemoteFile?
    @State private var newFileName = ""
    @State private var showingDeleteAlert = false
    @State private var deleteFile: RemoteFile?
    
    var body: some View {
        VStack(spacing: 0) {
            if !isConnected {
                emptyStateView
            } else if viewModel.isLoading {
                loadingView
            } else if let error = viewModel.errorMessage {
                errorView(error)
            } else if viewModel.files.isEmpty {
                emptyDirectoryView
            } else {
                fileTableView
            }
        }
        .navigationTitle(viewModel.currentPath)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: { Task { await viewModel.goBack() } }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!viewModel.canGoBack)
                
                Button(action: { Task { await viewModel.goForward() } }) {
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
                    Button("New Folder") {
                        showingNewFolderSheet = true
                    }
                    Button("Refresh") {
                        Task { await viewModel.refresh() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .alert("New Folder", isPresented: $showingNewFolderSheet) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) {
                newFolderName = ""
            }
            Button("Create") {
                Task {
                    try? await viewModel.createFolder(named: newFolderName)
                    newFolderName = ""
                }
            }
        }
        .alert("Rename", isPresented: $showingRenameAlert) {
            TextField("New name", text: $newFileName)
            Button("Cancel", role: .cancel) {
                renameFile = nil
                newFileName = ""
            }
            Button("Rename") {
                if let file = renameFile {
                    Task {
                        try? await viewModel.renameFile(file, to: newFileName)
                        renameFile = nil
                        newFileName = ""
                    }
                }
            }
        }
        .alert("Delete", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) {
                deleteFile = nil
            }
            Button("Delete", role: .destructive) {
                if let file = deleteFile {
                    Task {
                        try? await viewModel.deleteFile(file)
                        deleteFile = nil
                    }
                }
            }
        } message: {
            if let file = deleteFile {
                Text("Are you sure you want to delete \"\(file.name)\"?")
            }
        }
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
        Table(filesTableItems, selection: $selectedFiles) {
            TableColumn("Name") { file in
                HStack(spacing: 8) {
                    Image(systemName: file.icon)
                        .foregroundColor(file.isDirectory ? .blue : .secondary)
                    Text(file.name)
                }
            }
            .width(min: 200, ideal: 300)
            
            TableColumn("Size") { file in
                Text(file.formattedSize)
                    .monospacedDigit()
            }
            .width(80)
            
            TableColumn("Date Modified") { file in
                Text(file.formattedDate)
            }
            .width(150)
            
            TableColumn("Permissions") { file in
                Text(file.permissions)
                    .font(.system(.body, design: .monospaced))
            }
            .width(100)
        }
        .contextMenu(forSelectionType: RemoteFile.ID.self) { items in
            if let fileId = items.first,
               let file = viewModel.files.first(where: { $0.id == fileId }) {
                if !file.isDirectory {
                    Button("Download") {
                        downloadFile(file)
                    }
                }
                Divider()
                Button("Rename") {
                    renameFile = file
                    newFileName = file.name
                    showingRenameAlert = true
                }
                Button("Delete", role: .destructive) {
                    deleteFile = file
                    showingDeleteAlert = true
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
    
    private var filesTableItems: [RemoteFile] {
        viewModel.files
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard isConnected else { return false }
        
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    return
                }
                
                let fileName = url.lastPathComponent
                let destinationPath = viewModel.currentPath.hasSuffix("/")
                    ? viewModel.currentPath + fileName
                    : viewModel.currentPath + "/" + fileName
                
                var attributes: [FileAttributeKey: Any]?
                do {
                    attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                } catch {
                    print("Error getting file attributes: \(error)")
                }
                
                let fileSize = (attributes?[.size] as? Int64) ?? 0
                
                let transferItem = TransferItem(
                    fileName: fileName,
                    localPath: url.path,
                    remotePath: destinationPath,
                    direction: .upload,
                    fileSize: fileSize,
                    status: .failed
                )
                
                DispatchQueue.main.async {
                    transferQueue.addTransfer(transferItem)
                }
            }
        }
        
        return true
    }
    
    private func downloadFile(_ file: RemoteFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.downloadFile(file, to: url, transferQueue: transferQueue)
        }
    }
}

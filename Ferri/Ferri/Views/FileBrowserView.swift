import SwiftUI
import FTPClient

struct FileBrowserView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @ObservedObject var transferQueue: TransferQueueViewModel
    let isConnected: Bool

    @State private var selectedFiles: Set<RemoteFile.ID> = []

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
                .overlay {
                    FilePromiseDragSource(file: file)
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
    
    private func downloadFile(_ file: RemoteFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.downloadFile(file, to: url, transferQueue: transferQueue)
        }
    }
}

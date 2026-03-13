import SwiftUI

struct MainView: View {
    @StateObject private var connectionViewModel = ConnectionListViewModel()
    @StateObject private var fileBrowserViewModel = FileBrowserViewModel()
    @StateObject private var transferQueueViewModel = TransferQueueViewModel()
    
    @State private var showingConnectionSheet = false
    @State private var editingConnection: FTPServer?
    @State private var isTransferQueueExpanded = true
    @State private var isConnected = false
    
    var body: some View {
        NavigationSplitView {
            SidebarView(
                viewModel: connectionViewModel,
                showingConnectionSheet: $showingConnectionSheet,
                editingConnection: $editingConnection
            )
        } detail: {
            VStack(spacing: 0) {
                FileBrowserView(
                    viewModel: fileBrowserViewModel,
                    transferQueue: transferQueueViewModel,
                    isConnected: isConnected
                )
                
                TransferQueueView(
                    viewModel: transferQueueViewModel,
                    isExpanded: $isTransferQueueExpanded
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showingConnectionSheet) {
            ConnectionSheet(
                server: $editingConnection,
                isEditing: editingConnection != nil
            ) { server in
                if editingConnection != nil {
                    connectionViewModel.updateConnection(server)
                } else {
                    connectionViewModel.addConnection(server)
                }
                editingConnection = nil
            }
        }
        .onChange(of: connectionViewModel.selectedConnection) { _, newValue in
            if let connection = newValue {
                connect(to: connection)
            }
        }
        .onAppear {
            fileBrowserViewModel.setConnectionViewModel(connectionViewModel)
        }
    }
    
    private func connect(to server: FTPServer) {
        connectionViewModel.setConnectionStatus(.connecting, for: server.id)
        
        Task {
            do {
                try await FTPClient.shared.connect(to: server)
                isConnected = true
                connectionViewModel.setConnectionStatus(.connected, for: server.id)
                await fileBrowserViewModel.loadDirectory()
            } catch {
                isConnected = false
                connectionViewModel.setConnectionStatus(.error(error.localizedDescription), for: server.id)
            }
        }
    }
}

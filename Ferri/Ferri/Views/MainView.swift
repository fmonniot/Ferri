import SwiftUI
import FTPClient

struct MainView: View {
    @StateObject private var connectionViewModel = ConnectionListViewModel()
    @StateObject private var fileBrowserViewModel = FileBrowserViewModel()
    @StateObject private var transferQueueViewModel = TransferQueueViewModel()
    
    @State private var showingConnectionSheet = false
    @State private var editingConnection: FTPServer?
    @State private var isTransferQueueExpanded = false
    @State private var isConnected = false
    
    @State private var showingError = false
    @State private var errorMessage = ""
    
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
                    isConnected: isConnected,
                    hostLabel: connectionViewModel.selectedConnection?.displayName ?? ""
                )
                
                TransferQueueView(
                    viewModel: transferQueueViewModel,
                    isExpanded: $isTransferQueueExpanded
                )
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        withAnimation {
                            isTransferQueueExpanded.toggle()
                        }
                    }) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "arrow.up.arrow.down.circle")
                            if transferQueueViewModel.activeTransfers.count > 0 {
                                Text("\(transferQueueViewModel.activeTransfers.count)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(3)
                                    .frame(minWidth: 15, minHeight: 15)
                                    .background(Circle().fill(Color.accentColor))
                                    .offset(x: 8, y: -8)
                            }
                        }
                    }
                    .help("Transfers")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showingConnectionSheet) {
            ConnectionSheet(
                server: $editingConnection
            ) { server in
                if editingConnection != nil {
                    connectionViewModel.updateConnection(server)
                } else {
                    connectionViewModel.addConnection(server)
                }
                editingConnection = nil
            }
        }
        .alert("Connection Error", isPresented: $showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        .onChange(of: connectionViewModel.selectedConnection) { _, newValue in
            if let connection = newValue {
                connect(to: connection)
            }
        }
        .onAppear {
            fileBrowserViewModel.setConnectionViewModel(connectionViewModel)
            if let server = connectionViewModel.connections.first(where: { $0.autoConnect }) {
                connectionViewModel.selectConnection(server)
            }
        }
    }
    
    private func connect(to server: FTPServer) {
        Task { @MainActor in
            connectionViewModel.setConnectionStatus(.connecting, for: server.id)
            do {
                try await FTPClient.shared.connect(to: server)
                isConnected = true
                connectionViewModel.setConnectionStatus(.connected, for: server.id)
                await fileBrowserViewModel.loadDirectory(at: server.initialDirectoryPath ?? "")
            } catch {
                isConnected = false
                errorMessage = error.localizedDescription
                showingError = true
                connectionViewModel.setConnectionStatus(.error(error.localizedDescription), for: server.id)
            }
        }
    }
}

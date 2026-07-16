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
    @State private var failedServer: FTPServer?
    @State private var connectingServer: FTPServer?

    var body: some View {
        NavigationSplitView {
            SidebarView(
                viewModel: connectionViewModel,
                showingConnectionSheet: $showingConnectionSheet,
                editingConnection: $editingConnection,
                onConnect: connect,
                onDisconnect: disconnect
            )
        } detail: {
            VStack(spacing: 0) {
                ZStack {
                    FileBrowserView(
                        viewModel: fileBrowserViewModel,
                        transferQueue: transferQueueViewModel,
                        isConnected: isConnected,
                        hostLabel: connectionViewModel.selectedConnection?.displayName ?? ""
                    )

                    if let connectingServer {
                        connectingOverlay(host: connectingServer.displayName)
                    }
                }

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
            Button("Retry") {
                if let server = failedServer {
                    connect(to: server)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            fileBrowserViewModel.setConnectionViewModel(connectionViewModel)
            if let server = connectionViewModel.connections.first(where: { $0.autoConnect }) {
                connectionViewModel.selectConnection(server)
                connect(to: server)
            }
        }
    }

    private func connectingOverlay(host: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.3)
            Text("Connecting to \(host)…")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private func connect(to server: FTPServer) {
        Task { @MainActor in
            connectingServer = server
            connectionViewModel.setConnectionStatus(.connecting, for: server.id)
            do {
                try await FTPClient.shared.connect(to: server)
                isConnected = true
                connectingServer = nil
                connectionViewModel.setConnectionStatus(.connected, for: server.id)
                await fileBrowserViewModel.loadDirectory(at: server.initialDirectoryPath ?? "")
            } catch {
                isConnected = false
                connectingServer = nil
                errorMessage = error.localizedDescription
                failedServer = server
                showingError = true
                connectionViewModel.setConnectionStatus(.error(error.localizedDescription), for: server.id)
            }
        }
    }

    private func disconnect(_ server: FTPServer) {
        FTPClient.shared.disconnect()
        isConnected = false
        fileBrowserViewModel.reset()
        connectionViewModel.setConnectionStatus(.disconnected, for: server.id)
        if connectingServer?.id == server.id {
            connectingServer = nil
        }
    }
}

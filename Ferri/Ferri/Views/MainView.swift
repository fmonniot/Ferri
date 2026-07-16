import SwiftUI
import FTPClient

struct MainView: View {
    @StateObject private var connectionViewModel = ConnectionListViewModel()
    @StateObject private var fileBrowserViewModel: FileBrowserViewModel
    @StateObject private var transferQueueViewModel: TransferQueueViewModel

    @State private var showingConnectionSheet = false
    @State private var editingConnection: FTPServer?
    @State private var isTransferQueueExpanded = false
    @State private var isConnected = false

    init() {
        #if DEBUG
        if UITestSupport.isActive {
            // One mock shared by both view models, so a drag-started download resolves against
            // the same fake tree the browser is listing.
            let mock = UITestMockFTPClient()
            _fileBrowserViewModel = StateObject(wrappedValue: FileBrowserViewModel(ftpClient: mock))
            _transferQueueViewModel = StateObject(wrappedValue: TransferQueueViewModel(ftpClient: mock))
            return
        }
        #endif
        _fileBrowserViewModel = StateObject(wrappedValue: FileBrowserViewModel())
        _transferQueueViewModel = StateObject(wrappedValue: TransferQueueViewModel())
    }

    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var failedServer: FTPServer?
    @State private var connectingServer: FTPServer?

    #if DEBUG
    @State private var uiTestLastDragStartedFile = "none"
    #endif

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
            VSplitView {
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

                    #if DEBUG
                    if UITestSupport.isActive {
                        // Surfaces FilePromiseDragSourceView's drag-start notification as an
                        // accessibility-readable text so FerriUITests can assert a drag gesture
                        // reached beginDraggingSession without driving a real Finder drop.
                        Text(uiTestLastDragStartedFile)
                            .accessibilityIdentifier("debug.lastDragStartedFile")
                            .opacity(0.01)
                            .allowsHitTesting(false)
                            .onReceive(NotificationCenter.default.publisher(for: .uiTestDragSessionStarted)) { notification in
                                uiTestLastDragStartedFile = notification.userInfo?["file"] as? String ?? "unknown"
                            }
                    }
                    #endif
                }
                .frame(minHeight: 200, maxHeight: .infinity)

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
            #if DEBUG
            if UITestSupport.isActive {
                isConnected = true
                Task { await fileBrowserViewModel.loadDirectory() }
                return
            }
            #endif
            if let server = connectionViewModel.connections.first(where: { $0.autoConnect }) {
                connectionViewModel.selectConnection(server)
                connect(to: server)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newConnection)) { _ in
            editingConnection = nil
            showingConnectionSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .refresh)) { _ in
            guard isConnected else { return }
            Task { await fileBrowserViewModel.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateBack)) { _ in
            guard isConnected else { return }
            fileBrowserViewModel.goBack()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateForward)) { _ in
            guard isConnected else { return }
            fileBrowserViewModel.goForward()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateUp)) { _ in
            guard isConnected else { return }
            Task { await fileBrowserViewModel.goUp() }
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
                let message = friendlyConnectionError(error)
                errorMessage = message
                failedServer = server
                showingError = true
                connectionViewModel.setConnectionStatus(.error(message), for: server.id)
            }
        }
    }

    /// Map low-level SFTP errors to the short, cause-specific copy the design calls for
    /// (timeout vs. authentication) instead of surfacing a raw `localizedDescription`.
    private func friendlyConnectionError(_ error: Error) -> String {
        guard let sftpError = error as? SFTPClientError else {
            return error.localizedDescription
        }
        switch sftpError {
        case .authenticationFailed:
            return "Authentication failed. Check your username, password, or key."
        case .timeout, .connectionFailed, .channelClosed:
            return "Couldn't connect to the server. Check the host and port, then try again."
        case .notConnected:
            return "The connection was lost. Try connecting again."
        case .subsystemOpenFailed, .requestFailed, .invalidResponse:
            return sftpError.description
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

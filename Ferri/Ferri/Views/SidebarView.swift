import SwiftUI
import FTPClient

struct SidebarView: View {
    @ObservedObject var viewModel: ConnectionListViewModel
    @Binding var showingConnectionSheet: Bool
    @Binding var editingConnection: FTPServer?
    
    var body: some View {
        List(selection: $viewModel.selectedConnection) {
            ForEach(viewModel.connections) { connection in
                ConnectionRow(
                    connection: connection,
                    status: viewModel.connectionStatus[connection.id] ?? .disconnected
                )
                .tag(connection)
                .contextMenu {
                    Button("Connect") {
                        // Connect action handled by parent
                    }
                    Button("Edit") {
                        editingConnection = connection
                        showingConnectionSheet = true
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        viewModel.deleteConnection(connection)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    editingConnection = nil
                    showingConnectionSheet = true
                }) {
                    Image(systemName: "plus")
                }
                .help("Add Connection")
            }
        }
    }
}

struct ConnectionRow: View {
    let connection: FTPServer
    let status: ConnectionStatus
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.displayName)
                    .font(.system(size: 13))
                    .fontWeight(.medium)
                
                Text(connection.host)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(.vertical, 2)
    }
    
    var statusColor: Color {
        switch status {
        case .disconnected:
            return .gray
        case .connecting:
            return .orange
        case .connected:
            return .green
        case .error:
            return .red
        }
    }
}

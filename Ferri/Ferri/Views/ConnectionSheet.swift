import SwiftUI
import FTPClient

struct ConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    @Binding var server: FTPServer?
    let onSave: (FTPServer) -> Void
    
    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "22"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var privateKeyPath: String = ""
    @State private var keyPassphrase: String = ""
    @State private var initialDirectoryPath: String = ""
    
    private var isEditing: Bool { server != nil }
    
    var body: some View {
        VStack(spacing: 0) {
            Text(isEditing ? "Edit Connection" : "New Connection")
                .font(.headline)
                .padding()
            
            Divider()
            
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                    
                    TextField("Host", text: $host)
                        .textFieldStyle(.roundedBorder)
                    
                    TextField("Port", text: $port)
                        .textFieldStyle(.roundedBorder)
                } header: {
                    Text("Server")
                }
                
                Section {
                    TextField("Username", text: $username)
                        .textFieldStyle(.roundedBorder)
                    
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                    
                    HStack {
                        TextField("Private Key (optional)", text: $privateKeyPath)
                            .textFieldStyle(.roundedBorder)
                        
                        Button("Browse...") {
                            selectPrivateKey()
                        }
                    }
                    
                    SecureField("Key Passphrase (optional)", text: $keyPassphrase)
                        .textFieldStyle(.roundedBorder)
                } header: {
                    Text("Authentication")
                }
                
                Section {
                    TextField("Initial Directory (optional)", text: $initialDirectoryPath)
                        .textFieldStyle(.roundedBorder)
                } header: {
                    Text("Options")
                }
            }
            .formStyle(.grouped)
            .padding()
            
            Divider()
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Save") {
                    saveConnection()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 450, height: 480)
        .onAppear {
            loadServerData()
        }
    }
    
    private var isValid: Bool {
        !host.isEmpty && !username.isEmpty && Int(port) != nil
    }
    
    private func loadServerData() {
        if let existingServer = server {
            name = existingServer.name
            host = existingServer.host
            port = String(existingServer.port)
            username = existingServer.username
            password = existingServer.password
            privateKeyPath = existingServer.privateKeyPath ?? ""
            keyPassphrase = existingServer.keyPassphrase ?? ""
            initialDirectoryPath = existingServer.initialDirectoryPath ?? ""
        }
    }
    
    private func selectPrivateKey() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.message = "Select Private Key File"
        
        if panel.runModal() == .OK, let url = panel.url {
            privateKeyPath = url.path
        }
    }
    
    private func saveConnection() {
        let serverToSave: FTPServer
        if let existing = server {
            serverToSave = FTPServer(
                id: existing.id,
                name: name,
                host: host,
                port: Int(port) ?? 22,
                username: username,
                password: password,
                privateKeyPath: privateKeyPath.isEmpty ? nil : privateKeyPath,
                keyPassphrase: keyPassphrase.isEmpty ? nil : keyPassphrase,
                initialDirectoryPath: initialDirectoryPath.isEmpty ? nil : initialDirectoryPath
            )
        } else {
            serverToSave = FTPServer(
                name: name,
                host: host,
                port: Int(port) ?? 22,
                username: username,
                password: password,
                privateKeyPath: privateKeyPath.isEmpty ? nil : privateKeyPath,
                keyPassphrase: keyPassphrase.isEmpty ? nil : keyPassphrase,
                initialDirectoryPath: initialDirectoryPath.isEmpty ? nil : initialDirectoryPath
            )
        }
        
        onSave(serverToSave)
        dismiss()
    }
}

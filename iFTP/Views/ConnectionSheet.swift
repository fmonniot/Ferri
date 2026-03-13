import SwiftUI

struct ConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    @Binding var server: FTPServer?
    let onSave: (FTPServer) -> Void
    
    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "21"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var privateKeyPath: String = ""
    @State private var useTLS: Bool = false
    @State private var allowInsecureTLS: Bool = false
    
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
                } header: {
                    Text("Authentication")
                }
                
                Section {
                    Toggle("Use TLS/SSL (FTPS)", isOn: $useTLS)
                    
                    if useTLS {
                        Toggle("Allow invalid TLS certificates", isOn: $allowInsecureTLS)
                        
                        Text("Enable this if the server uses an expired or self-signed certificate")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Connection")
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
        .frame(width: 450, height: 450)
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
            useTLS = existingServer.useTLS
            allowInsecureTLS = existingServer.allowInsecureTLS
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
                port: Int(port) ?? 21,
                username: username,
                password: password,
                privateKeyPath: privateKeyPath.isEmpty ? nil : privateKeyPath,
                useTLS: useTLS,
                allowInsecureTLS: allowInsecureTLS
            )
        } else {
            serverToSave = FTPServer(
                name: name,
                host: host,
                port: Int(port) ?? 21,
                username: username,
                password: password,
                privateKeyPath: privateKeyPath.isEmpty ? nil : privateKeyPath,
                useTLS: useTLS,
                allowInsecureTLS: allowInsecureTLS
            )
        }
        
        onSave(serverToSave)
        dismiss()
    }
}

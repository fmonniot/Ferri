import Foundation

struct FTPServer: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var password: String
    var privateKeyPath: String?
    
    init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 21,
        username: String = "",
        password: String = "",
        privateKeyPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.privateKeyPath = privateKeyPath
    }
    
    var displayName: String {
        name.isEmpty ? host : name
    }
}

import Foundation

struct FTPServer: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var password: String
    var privateKeyPath: String?
    var keyPassphrase: String?
    
    init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 22,
        username: String = "",
        password: String = "",
        privateKeyPath: String? = nil,
        keyPassphrase: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.privateKeyPath = privateKeyPath
        self.keyPassphrase = keyPassphrase
    }
    
    var displayName: String {
        name.isEmpty ? host : name
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, password, privateKeyPath, keyPassphrase
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try container.decode(String.self, forKey: .username)
        password = try container.decode(String.self, forKey: .password)
        privateKeyPath = try container.decodeIfPresent(String.self, forKey: .privateKeyPath)
        keyPassphrase = try container.decodeIfPresent(String.self, forKey: .keyPassphrase)
    }
}

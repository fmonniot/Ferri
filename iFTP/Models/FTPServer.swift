import Foundation

struct FTPServer: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var password: String
    var privateKeyPath: String?
    var allowInsecureTLS: Bool
    
    init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 21,
        username: String = "",
        password: String = "",
        privateKeyPath: String? = nil,
        allowInsecureTLS: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.privateKeyPath = privateKeyPath
        self.allowInsecureTLS = allowInsecureTLS
    }
    
    var displayName: String {
        name.isEmpty ? host : name
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, password, privateKeyPath, allowInsecureTLS
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        password = try container.decode(String.self, forKey: .password)
        privateKeyPath = try container.decodeIfPresent(String.self, forKey: .privateKeyPath)
        allowInsecureTLS = try container.decodeIfPresent(Bool.self, forKey: .allowInsecureTLS) ?? false
    }
}

import Foundation

public struct FTPServer: Identifiable, Codable, Hashable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var privateKeyPath: String?
    public var keyPassphrase: String?
    public var initialDirectoryPath: String?

    public init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 22,
        username: String = "",
        password: String = "",
        privateKeyPath: String? = nil,
        keyPassphrase: String? = nil,
        initialDirectoryPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.privateKeyPath = privateKeyPath
        self.keyPassphrase = keyPassphrase
        self.initialDirectoryPath = initialDirectoryPath
    }
    
    public var displayName: String {
        name.isEmpty ? host : name
    }
    
    public enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, password, privateKeyPath, keyPassphrase, initialDirectoryPath
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try container.decode(String.self, forKey: .username)
        password = try container.decode(String.self, forKey: .password)
        privateKeyPath = try container.decodeIfPresent(String.self, forKey: .privateKeyPath)
        keyPassphrase = try container.decodeIfPresent(String.self, forKey: .keyPassphrase)
        initialDirectoryPath = try container.decodeIfPresent(String.self, forKey: .initialDirectoryPath)
    }
}

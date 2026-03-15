import Foundation

public struct RemoteFile: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int64
    public let modificationDate: Date?
    public let permissions: String

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        isDirectory: Bool,
        size: Int64 = 0,
        modificationDate: Date? = nil,
        permissions: String = ""
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
        self.permissions = permissions
    }
    
    public var formattedSize: String {
        guard !isDirectory else { return "--" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    
    public var formattedDate: String {
        guard let date = modificationDate else { return "--" }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }
    
    public var icon: String {
        if isDirectory {
            return "folder.fill"
        } else {
            return "doc.fill"
        }
    }
}

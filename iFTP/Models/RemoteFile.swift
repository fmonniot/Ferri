import Foundation

struct RemoteFile: Identifiable, Hashable {
    let id: UUID
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modificationDate: Date?
    let permissions: String
    
    init(
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
    
    var formattedSize: String {
        guard !isDirectory else { return "--" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    
    var formattedDate: String {
        guard let date = modificationDate else { return "--" }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }
    
    var icon: String {
        if isDirectory {
            return "folder.fill"
        } else {
            return "doc.fill"
        }
    }
}

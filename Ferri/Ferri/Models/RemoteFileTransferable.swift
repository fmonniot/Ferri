import Foundation
import CoreTransferable
import UniformTypeIdentifiers
import FTPClient

struct DraggableRemoteFile: Transferable, Codable {
    let file: RemoteFile

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { draggable in
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let localURL = tempDir.appendingPathComponent(draggable.file.name)

            try await FTPClient.shared.downloadFile(named: draggable.file.path, to: localURL)

            return SentTransferredFile(localURL)
        }
        .suggestedFileName { $0.file.name }
    }
}

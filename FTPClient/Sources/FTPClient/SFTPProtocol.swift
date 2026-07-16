import Foundation
import NIOCore
import NIO
import Logging

private let logger = Logger(label: "com.ftpclient.sftp.protocol")

enum SFTPMessageType: UInt8 {
    case initVersion = 1
    case version = 2
    case open = 3
    case close = 4
    case read = 5
    case write = 6
    case lstat = 7
    case fstat = 8
    case setstat = 9
    case fsetstat = 10
    case opendir = 11
    case readdir = 12
    case remove = 13
    case mkdir = 14
    case rmdir = 15
    case realpath = 16
    case stat = 17
    case rename = 18
    case readlink = 19
    case symlink = 20
    case status = 101
    case handle = 102
    case data = 103
    case name = 104
    case attrs = 105
}

enum SFTPError: Error, CustomStringConvertible, Sendable {
    case invalidMessage
    case invalidHandle
    case encodingFailed(String)
    case decodingFailed(String)
    case protocolError(UInt32, String)
    case eof
    case noSuchFile
    case permissionDenied
    case failure
    case badMessage
    case unknown(UInt32)

    var description: String {
        switch self {
        case .invalidMessage: return "Invalid message"
        case .invalidHandle: return "Invalid handle"
        case .encodingFailed(let msg): return "Encoding failed: \(msg)"
        case .decodingFailed(let msg): return "Decoding failed: \(msg)"
        case .protocolError(let code, let msg): return "Protocol error \(code): \(msg)"
        case .eof: return "End of file"
        case .noSuchFile: return "No such file"
        case .permissionDenied: return "Permission denied"
        case .failure: return "Operation failed"
        case .badMessage: return "Bad message"
        case .unknown(let code): return "Unknown error code: \(code)"
        }
    }
}

struct SFTPFileAttributes: Hashable, Sendable {
    var size: UInt64?
    var permissions: UInt32?
    var uid: UInt32?
    var gid: UInt32?
    var accessTime: UInt32?
    var modifyTime: UInt32?
    var isDirectory: Bool { (permissions ?? 0) & 0o40000 != 0 }
    var isSymlink: Bool { (permissions ?? 0) & 0o120000 == 0o120000 }
    var isRegularFile: Bool { (permissions ?? 0) & 0o170000 == 0o100000 }

    static let empty = SFTPFileAttributes()
}

struct SFTPDirectoryEntry: Sendable {
    let filename: String
    let longname: String
    var attributes: SFTPFileAttributes

    var isDirectory: Bool { attributes.isDirectory }
    var isSymlink: Bool { attributes.isSymlink }
}

struct SFTPHandle: Sendable {
    let bytes: ByteBuffer

    var string: String {
        guard let bytes = bytes.getBytes(at: 0, length: bytes.readableBytes) else { return "" }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
}

enum SFTPResponse: Sendable {
    case version(version: UInt32, extensionData: [(String, String)])
    case status(id: UInt32, code: UInt32, message: String, language: String)
    case handle(id: UInt32, handle: SFTPHandle)
    case data(id: UInt32, data: ByteBuffer)
    case name(id: UInt32, entries: [SFTPDirectoryEntry], count: UInt32)
    case attrs(id: UInt32, attributes: SFTPFileAttributes)
}

func writeString(_ buffer: inout ByteBuffer, _ string: String) throws {
    let data = string.utf8
    guard data.count <= UInt32.max else {
        throw SFTPError.encodingFailed("String too long")
    }
    buffer.writeInteger(UInt32(data.count), as: UInt32.self)
    buffer.writeBytes(data)
}

func writeHandle(_ buffer: inout ByteBuffer, _ handle: SFTPHandle) {
    buffer.writeInteger(UInt32(handle.bytes.readableBytes), as: UInt32.self)
    buffer.writeBytes(handle.bytes.readableBytesView)
}

func encodeAttributes(_ buffer: inout ByteBuffer, attrs: SFTPFileAttributes) {
    var flags: UInt32 = 0
    if attrs.size != nil { flags |= 0x00000001 }
    if attrs.permissions != nil { flags |= 0x00000004 }
    if attrs.uid != nil || attrs.gid != nil { flags |= 0x00000002 }
    if attrs.accessTime != nil || attrs.modifyTime != nil { flags |= 0x00000008 }

    buffer.writeInteger(flags, as: UInt32.self)

    if let size = attrs.size {
        buffer.writeInteger(size, as: UInt64.self)
    }
    if let uid = attrs.uid, let gid = attrs.gid {
        buffer.writeInteger(uid, as: UInt32.self)
        buffer.writeInteger(gid, as: UInt32.self)
    }
    if let permissions = attrs.permissions {
        buffer.writeInteger(permissions, as: UInt32.self)
    }
    if let atime = attrs.accessTime {
        buffer.writeInteger(atime, as: UInt32.self)
    }
    if let mtime = attrs.modifyTime {
        buffer.writeInteger(mtime, as: UInt32.self)
    }
}

protocol SFTPRequest {
    var id: UInt32 { get }
    var type: SFTPMessageType { get }
    func encode(into buffer: inout ByteBuffer) throws
}

struct SFTPInitRequest: SFTPRequest {
    let id: UInt32
    let version: UInt32 = 3
    let type: SFTPMessageType = .initVersion

    func encode(into buffer: inout ByteBuffer) throws {
        buffer.writeInteger(type.rawValue, as: UInt8.self)
        buffer.writeInteger(version, as: UInt32.self)
    }
}

struct SFTPOpenRequest: SFTPRequest {
    let id: UInt32
    let path: String
    let pflags: UInt32
    let attrs: SFTPFileAttributes
    let type: SFTPMessageType = .open

    func encode(into buffer: inout ByteBuffer) throws {
        buffer.writeInteger(type.rawValue, as: UInt8.self)
        buffer.writeInteger(id, as: UInt32.self)
        try writeString(&buffer, path)
        buffer.writeInteger(pflags, as: UInt32.self)
        encodeAttributes(&buffer, attrs: attrs)
    }
}

struct SFTPCloseRequest: SFTPRequest {
    let id: UInt32
    let handle: SFTPHandle
    let type: SFTPMessageType = .close

    func encode(into buffer: inout ByteBuffer) throws {
        buffer.writeInteger(type.rawValue, as: UInt8.self)
        buffer.writeInteger(id, as: UInt32.self)
        writeHandle(&buffer, handle)
    }
}

struct SFTPReadRequest: SFTPRequest {
    let id: UInt32
    let handle: SFTPHandle
    let offset: UInt64
    let length: UInt32
    let type: SFTPMessageType = .read

    func encode(into buffer: inout ByteBuffer) throws {
        buffer.writeInteger(type.rawValue, as: UInt8.self)
        buffer.writeInteger(id, as: UInt32.self)
        writeHandle(&buffer, handle)
        buffer.writeInteger(offset, as: UInt64.self)
        buffer.writeInteger(length, as: UInt32.self)
    }
}

struct SFTPWriteRequest: SFTPRequest {
    let id: UInt32
    let handle: SFTPHandle
    let offset: UInt64
    let data: ByteBuffer
    let type: SFTPMessageType = .write

    func encode(into buffer: inout ByteBuffer) throws {
        buffer.writeInteger(type.rawValue, as: UInt8.self)
        buffer.writeInteger(id, as: UInt32.self)
        writeHandle(&buffer, handle)
        buffer.writeInteger(offset, as: UInt64.self)
        buffer.writeInteger(UInt32(data.readableBytes), as: UInt32.self)
        var data = data
        buffer.writeBuffer(&data)
    }
}

struct SFTPLstatRequest: SFTPRequest {
    let id: UInt32
    let path: String
    let type: SFTPMessageType = .lstat

    func encode(into buffer: inout ByteBuffer) throws {
        buffer.writeInteger(type.rawValue, as: UInt8.self)
        buffer.writeInteger(id, as: UInt32.self)
        try writeString(&buffer, path)
    }
}

struct SFTPStatRequest: SFTPRequest {
    let id: UInt32
    let path: String
    let type: SFTPMessageType = .stat

    func encode(into buffer: inout ByteBuffer) throws {
        buffer.writeInteger(type.rawValue, as: UInt8.self)
        buffer.writeInteger(id, as: UInt32.self)
        try writeString(&buffer, path)
    }
}

struct SFTPFstatRequest: SFTPRequest {
    let id: UInt32
    let handle: SFTPHandle
    let type: SFTPMessageType = .fstat

    func encode(into buffer: inout ByteBuffer) throws {
        buffer.writeInteger(type.rawValue, as: UInt8.self)
        buffer.writeInteger(id, as: UInt32.self)
        writeHandle(&buffer, handle)
    }
}

struct SFTPSetstatRequest: SFTPRequest {
    let id: UInt32
    let path: String
    let attrs: SFTPFileAttributes
    let type: SFTPMessageType = .setstat

    func encode(into buffer: inout ByteBuffer) throws {
        buffer.writeInteger(type.rawValue, as: UInt8.self)
        buffer.writeInteger(id, as: UInt32.self)
        try writeString(&buffer, path)
        encodeAttributes(&buffer, attrs: attrs)
    }
}

struct SFTPFsetstatRequest: SFTPRequest {
    let id: UInt32
    let handle: SFTPHandle
    let attrs: SFTPFileAttributes
    let type: SFTPMessageType = .fsetstat

    func encode(into buffer: inout ByteBuffer) throws {
        buffer.writeInteger(type.rawValue, as: UInt8.self)
        buffer.writeInteger(id, as: UInt32.self)
        writeHandle(&buffer, handle)
        encodeAttributes(&buffer, attrs: attrs)
    }
}

struct SFTPOpendirRequest: SFTPRequest {
    let id: UInt32
    let path: String
    let type: SFTPMessageType = .opendir

    func encode(into buffer: inout ByteBuffer) throws {
        buffer.writeInteger(type.rawValue, as: UInt8.self)
        buffer.writeInteger(id, as: UInt32.self)
        try writeString(&buffer, path)
    }
}

struct SFTPReaddirRequest: SFTPRequest {
    let id: UInt32
    let handle: SFTPHandle
    let type: SFTPMessageType = .readdir

    func encode(into buffer: inout ByteBuffer) throws {
        buffer.writeInteger(type.rawValue, as: UInt8.self)
        buffer.writeInteger(id, as: UInt32.self)
        writeHandle(&buffer, handle)
    }
}

struct SFTPRemoveRequest: SFTPRequest {
    let id: UInt32
    let path: String
    let type: SFTPMessageType = .remove

    func encode(into buffer: inout ByteBuffer) throws {
        buffer.writeInteger(type.rawValue, as: UInt8.self)
        buffer.writeInteger(id, as: UInt32.self)
        try writeString(&buffer, path)
    }
}

struct SFTPMkdirRequest: SFTPRequest {
    let id: UInt32
    let path: String
    let attrs: SFTPFileAttributes
    let type: SFTPMessageType = .mkdir

    func encode(into buffer: inout ByteBuffer) throws {
        buffer.writeInteger(type.rawValue, as: UInt8.self)
        buffer.writeInteger(id, as: UInt32.self)
        try writeString(&buffer, path)
        encodeAttributes(&buffer, attrs: attrs)
    }
}

struct SFTPRmdirRequest: SFTPRequest {
    let id: UInt32
    let path: String
    let type: SFTPMessageType = .rmdir

    func encode(into buffer: inout ByteBuffer) throws {
        buffer.writeInteger(type.rawValue, as: UInt8.self)
        buffer.writeInteger(id, as: UInt32.self)
        try writeString(&buffer, path)
    }
}

struct SFTPRealpathRequest: SFTPRequest {
    let id: UInt32
    let path: String
    let type: SFTPMessageType = .realpath

    func encode(into buffer: inout ByteBuffer) throws {
        buffer.writeInteger(type.rawValue, as: UInt8.self)
        buffer.writeInteger(id, as: UInt32.self)
        try writeString(&buffer, path)
    }
}

struct SFTPRenameRequest: SFTPRequest {
    let id: UInt32
    let oldPath: String
    let newPath: String
    let type: SFTPMessageType = .rename

    func encode(into buffer: inout ByteBuffer) throws {
        buffer.writeInteger(type.rawValue, as: UInt8.self)
        buffer.writeInteger(id, as: UInt32.self)
        try writeString(&buffer, oldPath)
        try writeString(&buffer, newPath)
    }
}

struct SFTPReadlinkRequest: SFTPRequest {
    let id: UInt32
    let path: String
    let type: SFTPMessageType = .readlink

    func encode(into buffer: inout ByteBuffer) throws {
        buffer.writeInteger(type.rawValue, as: UInt8.self)
        buffer.writeInteger(id, as: UInt32.self)
        try writeString(&buffer, path)
    }
}

struct SFTPSymlinkRequest: SFTPRequest {
    let id: UInt32
    let linkPath: String
    let targetPath: String
    let type: SFTPMessageType = .symlink

    func encode(into buffer: inout ByteBuffer) throws {
        buffer.writeInteger(type.rawValue, as: UInt8.self)
        buffer.writeInteger(id, as: UInt32.self)
        try writeString(&buffer, targetPath)
        try writeString(&buffer, linkPath)
    }
}

/// Stateless SFTP wire-format encoder/decoder. Request IDs are owned by
/// `SFTPClient`'s actor-isolated state, not by this type, so it has no
/// mutable state and is safely `Sendable` across the actor / NIO-event-loop
/// boundary without `@unchecked`.
final class SFTPProtocol: Sendable {
    func encodeRequest(_ request: SFTPRequest) throws -> ByteBuffer {
        var payloadBuffer = ByteBufferAllocator().buffer(capacity: 256)

        logger.debug("Encoding \(request.type) request id=\(request.id)")

        try request.encode(into: &payloadBuffer)

        var result = ByteBufferAllocator().buffer(capacity: payloadBuffer.readableBytes + 4)
        result.writeInteger(UInt32(payloadBuffer.readableBytes), as: UInt32.self)
        result.writeBuffer(&payloadBuffer)
        return result
    }

    func decodeResponse(_ buffer: inout ByteBuffer) throws -> (id: UInt32, response: SFTPResponse)? {
        guard let length = buffer.readInteger(as: UInt32.self) else {
            return nil
        }
        
        guard buffer.readableBytes >= Int(length) else {
            buffer.moveReaderIndex(to: buffer.readerIndex - 4)
            return nil
        }
        
        guard let typeByte = buffer.readInteger(as: UInt8.self) else {
            throw SFTPError.decodingFailed("Missing message type")
        }
        
        guard let messageType = SFTPMessageType(rawValue: typeByte) else {
            logger.warning("Unknown message type: \(typeByte)")
            throw SFTPError.decodingFailed("Unknown message type: \(typeByte)")
        }

        logger.debug("Decoding \(messageType) response")

        switch messageType {
        case .version:
            guard let version = buffer.readInteger(as: UInt32.self) else {
                throw SFTPError.decodingFailed("Missing version")
            }
            logger.debug("  version = \(version)")
            var extensionData: [(String, String)] = []
            while buffer.readableBytes > 0 {
                if let name = readString(&buffer), let value = readString(&buffer) {
                    extensionData.append((name, value))
                }
            }
            return (0, .version(version: version, extensionData: extensionData))

        case .status:
            guard let id = buffer.readInteger(as: UInt32.self),
                  let code = buffer.readInteger(as: UInt32.self) else {
                throw SFTPError.decodingFailed("Missing id or code")
            }
            let message = readString(&buffer) ?? ""
            let language = readString(&buffer) ?? "en"
            return (id, .status(id: id, code: code, message: message, language: language))

        case .handle:
            guard let id = buffer.readInteger(as: UInt32.self) else {
                throw SFTPError.decodingFailed("Missing id")
            }
            let handle = try readHandle(&buffer)
            return (id, .handle(id: id, handle: handle))

        case .data:
            guard let id = buffer.readInteger(as: UInt32.self) else {
                throw SFTPError.decodingFailed("Missing id")
            }
            guard let dataLength = buffer.readInteger(as: UInt32.self),
                  let dataSlice = buffer.readSlice(length: Int(dataLength)) else {
                throw SFTPError.decodingFailed("Missing data payload")
            }
            return (id, .data(id: id, data: dataSlice))

        case .name:
            guard let id = buffer.readInteger(as: UInt32.self),
                  let count = buffer.readInteger(as: UInt32.self) else {
                throw SFTPError.decodingFailed("Missing id or count")
            }
            var entries: [SFTPDirectoryEntry] = []
            for _ in 0..<count {
                guard let filename = readString(&buffer) else { break }
                let longname = readString(&buffer) ?? filename
                let attrs = try decodeAttributes(&buffer)
                entries.append(SFTPDirectoryEntry(
                    filename: filename,
                    longname: longname,
                    attributes: attrs
                ))
            }
            return (id, .name(id: id, entries: entries, count: count))

        case .attrs:
            guard let id = buffer.readInteger(as: UInt32.self) else {
                throw SFTPError.decodingFailed("Missing id")
            }
            let attrs = try decodeAttributes(&buffer)
            return (id, .attrs(id: id, attributes: attrs))

        default:
            throw SFTPError.decodingFailed("Unexpected message type: \(typeByte)")
        }
    }

    private func readHandle(_ buffer: inout ByteBuffer) throws -> SFTPHandle {
        guard let length = buffer.readInteger(as: UInt32.self),
              let handleData = buffer.readBytes(length: Int(length)) else {
            throw SFTPError.decodingFailed("Missing handle data")
        }
        var handleBuffer = ByteBufferAllocator().buffer(capacity: handleData.count)
        handleBuffer.writeBytes(handleData)
        return SFTPHandle(bytes: handleBuffer)
    }

    private func readString(_ buffer: inout ByteBuffer) -> String? {
        guard let length = buffer.readInteger(as: UInt32.self),
              let data = buffer.readBytes(length: Int(length)) else {
            return nil
        }
        return String(bytes: data, encoding: .utf8)
    }

    private func decodeAttributes(_ buffer: inout ByteBuffer) throws -> SFTPFileAttributes {
        let flags = buffer.readInteger(as: UInt32.self) ?? 0
        var attrs = SFTPFileAttributes.empty

        if flags & 0x00000001 != 0 {
            attrs.size = buffer.readInteger(as: UInt64.self)
        }
        if flags & 0x00000002 != 0 {
            attrs.uid = buffer.readInteger(as: UInt32.self)
            attrs.gid = buffer.readInteger(as: UInt32.self)
        }
        if flags & 0x00000004 != 0 {
            attrs.permissions = buffer.readInteger(as: UInt32.self)
        }
        if flags & 0x00000008 != 0 {
            attrs.accessTime = buffer.readInteger(as: UInt32.self)
            attrs.modifyTime = buffer.readInteger(as: UInt32.self)
        }

        return attrs
    }
}

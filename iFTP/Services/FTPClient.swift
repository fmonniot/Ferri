import Foundation

enum FTPError: LocalizedError {
    case connectionFailed(String)
    case authenticationFailed
    case notConnected
    case transferFailed(String)
    case fileNotFound
    case permissionDenied
    case timeout
    
    var errorDescription: String? {
        switch self {
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        case .authenticationFailed:
            return "Authentication failed"
        case .notConnected:
            return "Not connected to server"
        case .transferFailed(let message):
            return "Transfer failed: \(message)"
        case .fileNotFound:
            return "File not found"
        case .permissionDenied:
            return "Permission denied"
        case .timeout:
            return "Connection timed out"
        }
    }
}

protocol FTPClientDelegate: AnyObject {
    func ftpClient(_ client: FTPClient, didChangeDirectoryTo path: String)
    func ftpClient(_ client: FTPClient, didListFiles files: [RemoteFile])
    func ftpClient(_ client: FTPClient, didUpdateProgress bytesTransferred: Int64, for file: String)
    func ftpClient(_ client: FTPClient, didCompleteTransfer file: String, success: Bool, error: Error?)
    func ftpClientDidConnect(_ client: FTPClient)
    func ftpClientDidDisconnect(_ client: FTPClient, error: Error?)
}

final class FTPClient: NSObject {
    static let shared = FTPClient()
    
    weak var delegate: FTPClientDelegate?
    
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var readBuffer = [UInt8](repeating: 0, count: 32768)
    
    private(set) var isConnected = false
    private(set) var currentPath = "/"
    private(set) var server: FTPServer?
    
    private var responseBuffer = ""
    private var dataConnection: DataConnection?
    
    private override init() {
        super.init()
    }
    
    func connect(to server: FTPServer) async throws {
        self.server = server
        
        print("Connecting to \(server.host):\(server.port) as \(server.username)")
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: FTPError.connectionFailed("Client deallocated"))
                    return
                }
                
                do {
                    try self.establishControlConnection(server: server)
                    try self.login(server: server)
                    self.isConnected = true
                    self.currentPath = try self.pwd()
                    
                    DispatchQueue.main.async {
                        self.delegate?.ftpClientDidConnect(self)
                    }
                    continuation.resume()
                } catch {
                    print("Connection error: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func disconnect() {
        guard isConnected else { return }
        
        sendCommand("QUIT")
        closeStreams()
        isConnected = false
        currentPath = "/"
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.ftpClientDidDisconnect(self, error: nil)
        }
    }
    
    func listDirectory(at path: String = "") async throws -> [RemoteFile] {
        guard isConnected else { throw FTPError.notConnected }
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[RemoteFile], Error>) in
            DispatchQueue.global().async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: FTPError.connectionFailed("Client deallocated"))
                    return
                }
                
                do {
                    let files = try self.listFiles(at: path)
                    let targetPath = path.isEmpty ? self.currentPath : path
                    
                    DispatchQueue.main.async {
                        self.delegate?.ftpClient(self, didChangeDirectoryTo: targetPath)
                        self.delegate?.ftpClient(self, didListFiles: files)
                    }
                    continuation.resume(returning: files)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func changeDirectory(to path: String) async throws {
        guard isConnected else { throw FTPError.notConnected }
        
        let response = sendCommand("CWD \(path)")
        try checkResponse(response, expectedCode: 250)
        
        currentPath = try pwd()
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.ftpClient(self, didChangeDirectoryTo: self.currentPath)
        }
    }
    
    func goToParentDirectory() async throws {
        try await changeDirectory(to: "..")
    }
    
    func createDirectory(named name: String) async throws {
        guard isConnected else { throw FTPError.notConnected }
        
        let response = sendCommand("MKD \(name)")
        try checkResponse(response, expectedCode: 257)
    }
    
    func deleteFile(named name: String) async throws {
        guard isConnected else { throw FTPError.notConnected }
        
        let response = sendCommand("DELE \(name)")
        try checkResponse(response, expectedCode: 250)
    }
    
    func deleteDirectory(named name: String) async throws {
        guard isConnected else { throw FTPError.notConnected }
        
        let response = sendCommand("RMD \(name)")
        try checkResponse(response, expectedCode: 250)
    }
    
    func rename(from oldName: String, to newName: String) async throws {
        guard isConnected else { throw FTPError.notConnected }
        
        let rnfrResponse = sendCommand("RNFR \(oldName)")
        try checkResponse(rnfrResponse, expectedCode: 350)
        
        let rntoResponse = sendCommand("RNTO \(newName)")
        try checkResponse(rntoResponse, expectedCode: 250)
    }
    
    func downloadFile(named fileName: String, to localURL: URL) async throws {
        guard isConnected else { throw FTPError.notConnected }
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: FTPError.transferFailed("Client deallocated"))
                    return
                }
                
                do {
                    try self.retrieveFile(named: fileName, to: localURL) { bytesTransferred in
                        DispatchQueue.main.async {
                            self.delegate?.ftpClient(self, didUpdateProgress: bytesTransferred, for: fileName)
                        }
                    }
                    
                    DispatchQueue.main.async {
                        self.delegate?.ftpClient(self, didCompleteTransfer: fileName, success: true, error: nil)
                    }
                    continuation.resume()
                } catch {
                    DispatchQueue.main.async {
                        self.delegate?.ftpClient(self, didCompleteTransfer: fileName, success: false, error: error)
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func uploadFile(from localURL: URL, to remotePath: String) async throws {
        guard isConnected else { throw FTPError.notConnected }
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: FTPError.transferFailed("Client deallocated"))
                    return
                }
                
                do {
                    let fileName = localURL.lastPathComponent
                    try self.storeFile(from: localURL, to: remotePath) { bytesTransferred in
                        DispatchQueue.main.async {
                            self.delegate?.ftpClient(self, didUpdateProgress: bytesTransferred, for: fileName)
                        }
                    }
                    
                    DispatchQueue.main.async {
                        self.delegate?.ftpClient(self, didCompleteTransfer: fileName, success: true, error: nil)
                    }
                    continuation.resume()
                } catch {
                    DispatchQueue.main.async {
                        self.delegate?.ftpClient(self, didCompleteTransfer: localURL.lastPathComponent, success: false, error: error)
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func establishControlConnection(server: FTPServer) throws {
        print("Creating stream to \(server.host):\(server.port)")
        
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        
        CFStreamCreatePairWithSocketToHost(
            nil,
            server.host as CFString,
            UInt32(server.port),
            &readStream,
            &writeStream
        )
        
        guard let input = readStream?.takeRetainedValue(),
              let output = writeStream?.takeRetainedValue() else {
            throw FTPError.connectionFailed("Failed to create streams")
        }
        
        inputStream = input as InputStream
        outputStream = output as OutputStream
        
        print("Opening streams...")
        inputStream?.open()
        outputStream?.open()
        
        let inputStatus = inputStream?.streamStatus.rawValue ?? 999
        print("Waiting for input stream... status: \(inputStatus)")
        guard waitForStream(inputStream, timeout: 10.0) else {
            print("Input stream timeout, status: \(inputStream?.streamStatus.rawValue ?? 999)")
            throw FTPError.timeout
        }
        
        print("Waiting for output stream...")
        guard waitForStream(outputStream, timeout: 10.0) else {
            throw FTPError.timeout
        }
        
        print("Reading welcome response...")
        let welcome = readResponse()
        print("Welcome: \(welcome)")
        
        guard !welcome.isEmpty else {
            throw FTPError.connectionFailed("No response from server")
        }
        
        let response = sendCommand("USER \(server.username)")
        if response.hasPrefix("331") {
            let passResponse = sendCommand("PASS \(server.password)")
            if passResponse.hasPrefix("530") {
                throw FTPError.authenticationFailed
            }
        } else if response.hasPrefix("530") {
            throw FTPError.authenticationFailed
        }
    }
    
    private func waitForStream(_ stream: InputStream?, timeout: TimeInterval) -> Bool {
        guard let stream = stream else { return false }
        
        let startTime = Date()
        while stream.streamStatus == .opening {
            if Date().timeIntervalSince(startTime) > timeout {
                return false
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return stream.streamStatus == .open
    }
    
    private func waitForStream(_ stream: OutputStream?, timeout: TimeInterval) -> Bool {
        guard let stream = stream else { return false }
        
        let startTime = Date()
        while stream.streamStatus == .opening {
            if Date().timeIntervalSince(startTime) > timeout {
                return false
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return stream.streamStatus == .open
    }
    
    private func login(server: FTPServer) throws {
        let response = sendCommand("TYPE I")
        try checkResponse(response, expectedCode: 200)
    }
    
    private func closeStreams() {
        inputStream?.close()
        outputStream?.close()
        inputStream = nil
        outputStream = nil
    }
    
    private func sendCommand(_ command: String) -> String {
        let commandWithNewline = command + "\r\n"
        guard let data = commandWithNewline.data(using: .utf8),
              let output = outputStream else {
            return ""
        }
        
        data.withUnsafeBytes { ptr in
            output.write(ptr.bindMemory(to: UInt8.self).baseAddress!, maxLength: data.count)
        }
        return readResponse()
    }
    
    private func readResponse() -> String {
        responseBuffer = ""
        
        guard let input = inputStream else { return "" }
        
        let deadline = Date().addingTimeInterval(30)
        
        while Date() < deadline {
            if input.hasBytesAvailable {
                let bytesRead = input.read(&readBuffer, maxLength: readBuffer.count)
                if bytesRead > 0 {
                    if let chunk = String(bytes: readBuffer[0..<bytesRead], encoding: .utf8) {
                        responseBuffer += chunk
                        if responseBuffer.hasSuffix("\r\n") {
                            break
                        }
                    }
                } else if bytesRead < 0 {
                    break
                }
            } else {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        
        return responseBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func checkResponse(_ response: String, expectedCode: Int) throws {
        guard let code = Int(response.prefix(3)) else {
            throw FTPError.transferFailed("Invalid response: \(response)")
        }
        
        if code != expectedCode {
            let message = response.count > 3 ? String(response.dropFirst(4)) : "Unknown error"
            
            if code == 530 {
                throw FTPError.permissionDenied
            } else if code == 550 {
                throw FTPError.fileNotFound
            } else {
                throw FTPError.transferFailed("\(message) (code: \(code))")
            }
        }
    }
    
    private func pwd() throws -> String {
        let response = sendCommand("PWD")
        try checkResponse(response, expectedCode: 257)
        
        if let startIndex = response.firstIndex(of: "\""),
           let endIndex = response.lastIndex(of: "\""),
           startIndex != endIndex {
            let pathStart = response.index(after: startIndex)
            return String(response[pathStart..<endIndex])
        }
        return "/"
    }
    
    private func listFiles(at path: String) throws -> [RemoteFile] {
        dataConnection = try createDataConnection(mode: .passive)
        
        let listCommand = path.isEmpty ? "LIST" : "LIST \(path)"
        let response = sendCommand(listCommand)
        
        guard response.hasPrefix("150") || response.hasPrefix("125") else {
            throw FTPError.transferFailed("Failed to list files: \(response)")
        }
        
        let data = dataConnection?.readData() ?? Data()
        _ = readResponse()
        
        dataConnection?.close()
        dataConnection = nil
        
        return parseDirectoryListing(data)
    }
    
    private func createDataConnection(mode: DataConnectionMode) throws -> DataConnection {
        let command = mode == .passive ? "PASV" : "PORT"
        let response = sendCommand(command)
        
        if mode == .passive {
            try checkResponse(response, expectedCode: 227)
            let (host, port) = parsePassiveResponse(response)
            return DataConnection(host: host, port: port)
        } else {
            try checkResponse(response, expectedCode: 200)
            return DataConnection(host: "127.0.0.1", port: 0)
        }
    }
    
    private func parsePassiveResponse(_ response: String) -> (String, Int) {
        guard let startParen = response.firstIndex(of: "("),
              let endParen = response.firstIndex(of: ")") else {
            return ("", 0)
        }
        
        let numbersString = String(response[response.index(after: startParen)..<endParen])
        let numbers = numbersString.split(separator: ",").compactMap { Int($0) }
        
        guard numbers.count == 6 else { return ("", 0) }
        
        let host = "\(numbers[0]).\(numbers[1]).\(numbers[2]).\(numbers[3])"
        let port = numbers[4] * 256 + numbers[5]
        
        return (host, port)
    }
    
    private func parseDirectoryListing(_ data: Data) -> [RemoteFile] {
        guard let listing = String(data: data, encoding: .utf8) else { return [] }
        
        var files: [RemoteFile] = []
        let lines = listing.components(separatedBy: "\n")
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            
            if let file = parseDirectoryLine(trimmed) {
                files.append(file)
            }
        }
        
        return files.sorted { file1, file2 in
            if file1.isDirectory != file2.isDirectory {
                return file1.isDirectory
            }
            return file1.name.localizedCaseInsensitiveCompare(file2.name) == .orderedAscending
        }
    }
    
    private func parseDirectoryLine(_ line: String) -> RemoteFile? {
        let components = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        
        guard components.count >= 9 else { return nil }
        
        let permissions = String(components[0])
        let isDirectory = permissions.hasPrefix("d")
        
        let size: Int64 = Int64(components[4]) ?? 0
        
        let name = components[8...].joined(separator: " ")
        
        var path = currentPath
        if path.hasSuffix("/") {
            path += name
        } else {
            path += "/" + name
        }
        
        return RemoteFile(
            name: name,
            path: path,
            isDirectory: isDirectory,
            size: size,
            modificationDate: nil,
            permissions: permissions
        )
    }
    
    private func retrieveFile(named fileName: String, to localURL: URL, progress: @escaping (Int64) -> Void) throws {
        dataConnection = try createDataConnection(mode: .passive)
        
        let response = sendCommand("RETR \(fileName)")
        try checkResponse(response, expectedCode: 150)
        
        try dataConnection?.writeToFile(localURL, progress: progress)
        
        _ = readResponse()
        dataConnection?.close()
        dataConnection = nil
    }
    
    private func storeFile(from localURL: URL, to remotePath: String, progress: @escaping (Int64) -> Void) throws {
        dataConnection = try createDataConnection(mode: .passive)
        
        let response = sendCommand("STOR \(remotePath)")
        try checkResponse(response, expectedCode: 150)
        
        try dataConnection?.readFromFile(localURL, progress: progress)
        
        _ = readResponse()
        dataConnection?.close()
        dataConnection = nil
    }
}

enum DataConnectionMode {
    case passive
    case active
}

final class DataConnection {
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private let host: String
    private let port: Int
    
    init(host: String, port: Int) {
        self.host = host
        self.port = port
        connect()
    }
    
    private func connect() {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        
        CFStreamCreatePairWithSocketToHost(nil, host as CFString, UInt32(port), &readStream, &writeStream)
        
        inputStream = readStream?.takeRetainedValue()
        outputStream = writeStream?.takeRetainedValue()
        
        inputStream?.open()
        outputStream?.open()
    }
    
    func readData() -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 32768)
        
        guard let input = inputStream else { return data }
        
        while input.hasBytesAvailable {
            let bytesRead = input.read(&buffer, maxLength: buffer.count)
            if bytesRead > 0 {
                data.append(contentsOf: buffer[0..<bytesRead])
            } else {
                break
            }
        }
        
        return data
    }
    
    func writeToFile(_ url: URL, progress: @escaping (Int64) -> Void) throws {
        guard let input = inputStream else { return }
        
        let fileManager = FileManager.default
        fileManager.createFile(atPath: url.path, contents: nil)
        
        guard let fileHandle = FileHandle(forWritingAtPath: url.path) else {
            throw FTPError.transferFailed("Cannot create file at \(url.path)")
        }
        
        defer { try? fileHandle.close() }
        
        var buffer = [UInt8](repeating: 0, count: 32768)
        var totalBytes: Int64 = 0
        
        while input.hasBytesAvailable {
            let bytesRead = input.read(&buffer, maxLength: buffer.count)
            if bytesRead > 0 {
                try fileHandle.write(contentsOf: buffer[0..<bytesRead])
                totalBytes += Int64(bytesRead)
                progress(totalBytes)
            } else {
                break
            }
        }
    }
    
    func readFromFile(_ url: URL, progress: @escaping (Int64) -> Void) throws {
        guard let fileHandle = FileHandle(forReadingAtPath: url.path) else {
            throw FTPError.fileNotFound
        }
        
        defer { try? fileHandle.close() }
        
        guard let output = outputStream else { return }
        
        var buffer = [UInt8](repeating: 0, count: 32768)
        var totalBytes: Int64 = 0
        
        while true {
            let data = fileHandle.readData(ofLength: buffer.count)
            if data.isEmpty { break }
            
            _ = data.withUnsafeBytes { ptr in
                output.write(ptr.bindMemory(to: UInt8.self).baseAddress!, maxLength: data.count)
            }
            
            totalBytes += Int64(data.count)
            progress(totalBytes)
        }
    }
    
    func close() {
        inputStream?.close()
        outputStream?.close()
        inputStream = nil
        outputStream = nil
    }
}

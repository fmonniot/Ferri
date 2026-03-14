# FTPClient Requirements

## Dependencies
- SwiftNIO (apple/swift-nio)
- SwiftNIO SSH (apple/swift-nio-ssh)  
- SwiftCrypto (apple/swift-crypto)
- SwiftLog (apple/swift-log)

## Constraints
- **DO NOT USE Citadel library** - This is not an option under any circumstances
- Must implement SFTP client from scratch using NIOSSH

## Required Features
1. Connect to SFTP servers using password authentication
2. Connect to SFTP servers using private key authentication
3. List directory contents
4. Change directory
5. Download files
6. Upload files (optional, nice to have)
7. Handle connection errors gracefully

## Technical Requirements
- Use Swift Concurrency (async/await)
- Target macOS 10.15+
- Follow existing code style in the project

## Architecture
- `FTPClient` - High-level API for the app
- `SFTPClient` - Actor managing the SFTP connection
- `SFTPProtocol` - SFTP message encoding/decoding
- `RemoteFile` - Model for remote file metadata
- `FTPServer` - Server configuration model

## Testing
- Tests run against Docker container (atmoz/sftp)
- Tests must pass for all defined test cases

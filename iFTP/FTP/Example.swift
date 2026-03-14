// Usage.swift — example call site
//
// swift run example:
//
//   let client = try FTPSClient(host: "ftp.example.com")
//   try await client.connect(user: "alice", password: "s3cr3t")
//   let data = try await client.download(remotePath: "/pub/large.zip", resumeFrom: 1024 * 1024)
//   try await client.quit()

import Foundation

struct Example {
    static func main() async throws {
        let client = try FTPSClient(host: "ftp.example.com")

        try await client.connect(user: "alice", password: "s3cr3t")
        print("Connected and authenticated")

        // First download — no resume
        let data = try await client.download(remotePath: "/pub/file.bin")
        print("Downloaded \(data.count) bytes")

        // Resume an interrupted transfer from 512 KB in
        let partial = try await client.download(
            remotePath: "/pub/large.zip",
            resumeFrom: 512 * 1024
        )
        print("Resumed: got \(partial.count) bytes")

        try await client.quit()
    }
}

import Foundation

/// A validated, absolute SFTP remote path.
///
/// Plain `String` let malformed input (a NUL byte, which no POSIX path component can
/// legally contain) flow silently through `resolvePath` and into the wire encoding,
/// which is length-prefixed rather than NUL-terminated and would happily smuggle the
/// byte along. `SFTPPath` centralizes resolution (the "."/".."/relative-name rules a
/// shell `cd` follows) and that one validation rule in a single place instead of
/// leaving every call site to reimplement `resolvePath`-style string surgery.
struct SFTPPath: Hashable, Sendable, CustomStringConvertible {
    let string: String

    static let root = SFTPPath(string: "/")

    private init(string: String) {
        self.string = string
    }

    var description: String { string }

    /// Resolves `input` against `self` as the current directory: absolute inputs
    /// replace it outright, `"."`/`""` mean "stay here", `".."` means "go up one
    /// component", and anything else is appended as a relative path/name.
    func resolving(_ input: String) throws -> SFTPPath {
        guard !input.utf8.contains(0) else {
            throw SFTPPathError.invalidPath(input)
        }

        if input.hasPrefix("/") {
            return SFTPPath(string: input)
        }
        if input.isEmpty || input == "." {
            return self
        }
        if input == ".." {
            guard string != "/" else { return self }
            return SFTPPath(string: (string as NSString).deletingLastPathComponent)
        }

        return SFTPPath(string: string.hasSuffix("/") ? string + input : string + "/" + input)
    }
}

enum SFTPPathError: Error, CustomStringConvertible, Sendable {
    case invalidPath(String)

    var description: String {
        switch self {
        case .invalidPath(let raw): return "Invalid remote path: \(raw)"
        }
    }
}

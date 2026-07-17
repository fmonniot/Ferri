import Logging
import os

/// Bridges swift-log to macOS unified logging (`os.Logger`), so entries stay
/// retrievable via Console.app or `log show`/`log stream` even when the app
/// was launched by double-clicking and has no attached stderr.
struct OSLogHandler: LogHandler {
    private let log: os.Logger

    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .info

    init(label: String, subsystem: String) {
        self.log = os.Logger(subsystem: subsystem, category: label)
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        metadata explicitMetadata: Logging.Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let merged = metadata.merging(explicitMetadata ?? [:]) { _, new in new }
        let suffix = merged.isEmpty ? "" : " " + merged.sorted { $0.key < $1.key }.map { "\($0)=\($1)" }.joined(separator: " ")
        log.log(level: level.osLogType, "\(message.description, privacy: .public)\(suffix, privacy: .public)")
    }
}

private extension Logging.Logger.Level {
    var osLogType: OSLogType {
        switch self {
        case .trace, .debug: return .debug
        case .info, .notice: return .info
        case .warning: return .default
        case .error: return .error
        case .critical: return .fault
        }
    }
}

public enum FerriLogging {
    /// Routes all `Logger(label:)` output through macOS unified logging instead of
    /// swift-log's default stderr handler. Must be called once, before any logger
    /// is used — call it as early as possible during app launch (e.g. from
    /// `FerriApp.init()`), since a `Logger` created before this runs keeps using
    /// the default handler.
    public static func bootstrap(subsystem: String = "eu.monniot.Ferri") {
        LoggingSystem.bootstrap { label in
            OSLogHandler(label: label, subsystem: subsystem)
        }
    }
}

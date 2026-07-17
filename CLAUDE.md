# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project scope

Ferri (spec name "iFTP") is a macOS SFTP client built with SwiftUI. It is **not** a general-purpose FTP/SFTP toolkit and does **not** support operations that modify remote objects (no delete/rename/mkdir on the remote — see the stubbed methods in `FileBrowserViewModel` that intentionally throw "not supported"). The two supported flows are: browse a remote server, and download files/folders (drag to Finder, or programmatic download). Keep new work inside that scope unless the user asks to expand it.

See `SPEC.md` for the original UI/UX spec and `TODO.md` for known open issues.

## Repository layout

Two components, tied together by `Ferri.xcworkspace`:

- **`FTPClient/`** — a standalone Swift package implementing the SFTP protocol from scratch on top of SwiftNIO + NIOSSH (Swift Testing framework `swift-tools-version: 6.2`). **Do not use the Citadel library** — this constraint is explicit in `FTPClient/REQUIREMENTS.md` and must not be reconsidered without the user asking.
- **`Ferri/`** — the Xcode app project (SwiftUI, MVVM) that consumes `FTPClient` as a local package dependency.

## Commands

### FTPClient package (SFTP protocol + unit tests, no Xcode needed)

```sh
cd FTPClient
swift build
swift test                                   # runs protocol/model unit tests; integration tests auto-skip without Docker
swift test --filter SFTPProtocolTests        # single suite
swift test --filter "SFTPProtocolTests/encodesReadRequest"   # single test
```

### FTPClient integration tests (require Docker Compose)

The `SFTPIntegrationTests` suite (in `FTPClient/Tests/FTPClientTests/FTPClientTests.swift`, `@Suite(.serialized)`) talks to a real SFTP server and skips itself if the stack isn't already running — tests never start/stop containers themselves.

```sh
cd FTPClient
docker compose up -d      # starts sftp (2222) + toxiproxy (2223 proxy, 8474 REST API)
swift test
docker compose down
```

- Credentials: `testuser` / `testpass123`; writable dir on the server is `/upload`.
- Both containers run under `platform: linux/amd64` for Apple Silicon compatibility.
- The latency/throughput test drives toxiproxy's REST API (port 8474) to inject ~40ms RTT — this exists because `tc netem` doesn't work on Docker for Mac.
- Config: `FTPClient/docker-compose.yml`, `FTPClient/toxiproxy.json`.

### Ferri app (Xcode workspace)

```sh
xcodebuild -workspace Ferri.xcworkspace -scheme Ferri build
xcodebuild -workspace Ferri.xcworkspace -scheme Ferri test
```

`FerriTests` are mock-based (no Docker/network access — the app runs sandboxed) and use `MockFTPClient`, a hand-written conformer of `FTPClientProtocol` defined at the top of `Ferri/FerriTests/FerriTests.swift`.

**Prefer the Xcode MCP tooling over raw `xcodebuild`/`swift` CLI invocations when available** — it avoids known Swift Package resolution issues that the CLI hits in this workspace.

## Architecture

### FTPClient package internals

- `FTPClient.swift` — the public facade (`FTPClient.shared`, a singleton `final class`) conforming to `FTPClientProtocol`. The app talks to SFTP only through this protocol, never through `SFTPClient` directly — this is what makes `MockFTPClient` possible in app tests.
- `SFTPClient.swift` — an `actor` owning the actual NIOSSH channel, auth, and file-transfer logic (connect, listDirectory, downloadToFile, etc.).
- `SFTPProtocol.swift` — SFTP wire-format encoding/decoding (request/response types, `SFTPFileAttributes`) independent of NIO channel plumbing.
- `RemoteFile.swift` / `FTPServer.swift` — plain value-type models (remote directory entry; saved server connection incl. credentials).

Known open issues for this package (mixed actor/NIO-event-loop concurrency model, `is/as` request-type dispatch, etc.) live in the top-level `TODO.md`, not a separate file — check it before touching `SFTPClient.swift`/`SFTPProtocol.swift`.

### Ferri app (MVVM)

- **Models**: `TransferItem` (transfer-queue entry); `RemoteFile`/`FTPServer` come from `FTPClient`.
- **ViewModels** (`@MainActor`, `ObservableObject`): `ConnectionListViewModel` (saved connections + active connection), `FileBrowserViewModel` (directory listing/navigation/sort, holds `any FTPClientProtocol` — swappable for tests), `TransferQueueViewModel` (download queue state).
- **Services**: `ConnectionStorage` — persists `[FTPServer]` as a property list under Application Support (`~/Library/Application Support/iFTP/connections.plist`).
- **Views**: SwiftUI (`MainView`, `SidebarView`, `FileBrowserView`, `TransferQueueView`, `ConnectionSheet`).
- **`FilePromiseDragSource.swift`**: the drag-to-Finder-download mechanism. It's an `NSViewRepresentable` wrapping an `NSView` that implements `NSDraggingSource` + `NSFilePromiseProviderDelegate`, because SwiftUI has no native support for `NSFilePromiseProvider`. Directory drags recurse (`downloadDirectoryRecursively`) by walking `listDirectory` and downloading each file promise-fulfillment-side; single-file drags download directly. Both paths publish an `NSProgress` (`publishFinderProgress`) to drive Finder's download badge on the dropped item — note the destination file/folder must be created *before* `publish()`, since Finder only attaches a published progress to something it can already see and never retries. This is the app's most AppKit-bridging-heavy file — read it fully before modifying drag/download behavior.

### Testability pattern

Both the app and the package hide SFTP behind `FTPClientProtocol` (`FTPClient/Sources/FTPClient/FTPClientProtocol.swift`). Anything that needs to talk to a server — ViewModels, `FilePromiseDragSourceView` — takes `any FTPClientProtocol` (defaulting to `FTPClient.shared`) rather than a concrete type, so tests can inject `MockFTPClient`.

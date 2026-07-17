# Ferri

Ferri is a lightweight, native macOS SFTP client built with SwiftUI. Connect to a server, browse its files, and drag them straight to Finder to download.

Ferri is intentionally narrow in scope: it's a **browser + downloader**, not a general-purpose FTP toolkit. It does not create, rename, delete, or otherwise modify anything on the remote server.

## Features

- Connect to SFTP servers with password or private key authentication
- Manage a sidebar of saved connections
- Browse remote directories in a sortable, resizable table view
- Download files and folders by dragging them onto Finder (with a live Finder progress badge), or via a transfer queue
- Track downloads in a collapsible transfer queue panel

## Repository layout

This repo is a single Xcode workspace, [`Ferri.xcworkspace`](Ferri.xcworkspace), made of two components:

- [`FTPClient/`](FTPClient) — a standalone Swift package that implements the SFTP protocol from scratch on top of SwiftNIO and NIOSSH (no Citadel). It owns the wire protocol, the connection actor, and the file-transfer logic.
- [`Ferri/`](Ferri) — the SwiftUI app (MVVM) that consumes `FTPClient` as a local package dependency and provides the UI: connection list, file browser, and transfer queue.

See [`SPEC.md`](SPEC.md) for the original UI/UX spec and [`TODO.md`](TODO.md) for known open issues.

## Building

### The app

Open [`Ferri.xcworkspace`](Ferri.xcworkspace) in Xcode and build/run the `Ferri` scheme, or from the command line:

```sh
xcodebuild -workspace Ferri.xcworkspace -scheme Ferri build
```

To produce a standalone `Ferri.app` and copy it out of Derived Data:

```sh
scripts/build.sh [Debug|Release]   # defaults to Release, output at ./build/Ferri.app
```

To build and install it straight into `/Applications` (quitting any running instance first):

```sh
scripts/install.sh
```

### The FTPClient package on its own

```sh
cd FTPClient
swift build
swift test
```

## Testing

```sh
# FTPClient protocol/model unit tests (integration tests auto-skip without Docker)
cd FTPClient && swift test

# FTPClient integration tests against a real SFTP server, via Docker Compose
cd FTPClient
docker compose up -d      # sftp on :2222, toxiproxy on :2223 (proxy) / :8474 (REST API)
swift test
docker compose down

# Ferri app tests (mock-based, no Docker/network needed)
xcodebuild -workspace Ferri.xcworkspace -scheme Ferri test
```

## Logs

Ferri logs through macOS unified logging (subsystem `eu.monniot.Ferri`), so logs are retrievable even when the app is launched by double-clicking it in Finder. View them in Console.app (filter by subsystem), or from a terminal:

```sh
log show --predicate 'subsystem == "eu.monniot.Ferri"' --last 1h
log stream --predicate 'subsystem == "eu.monniot.Ferri"'
```

## License

Ferri is available under the [MIT license](LICENSE).

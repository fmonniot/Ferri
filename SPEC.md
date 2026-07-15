# Ferri - macOS FTP Client Specification

## 1. Project Overview

- **Project Name**: Ferri
- **Type**: macOS Native Application (Xcode)
- **Purpose**: A lightweight SFTP client for macOS allowing users to connect to SFTP servers, browse remote files, and transfer files via drag & drop from Finder.

## 2. UI/UX Specification

### 2.1 Window Structure

- **Main Window**: Single window with slip view layout
  - Left: Sidebar (220pt min width) for connections
  - Center: Remote file browser (table view)
  - Bottom: Transfer queue panel (collapsible, 150pt default height)
- **Connection Sheet**: Modal sheet for adding/editing connections

### 2.2 Visual Design

- **Color Palette**:
  - Primary: System colors (adaptive to light/dark mode)
  - Accent: System accent color
  - Sidebar background: `NSColor.controlBackgroundColor`
  - Selection: `NSColor.selectedContentBackgroundColor`

- **Typography**:
  - Headings: System font, 13pt semibold
  - Body: System font, 13pt regular
  - Captions: System font, 11pt regular

- **Spacing**: 8pt grid system (8, 16, 24pt margins)

### 2.3 Components

#### Sidebar
- Flat list of saved connections
- Each row shows: status indicator (green/red dot), connection name, host
- Add button (+) at bottom
- Context menu: Connect, Edit, Delete

#### Toolbar
- Quick Connect: Text field + Connect button
- Navigation: Back, Forward, Up one level, Refresh buttons

#### Remote File Browser
- Table columns: Icon, Name, Size, Date Modified, Permissions
- Sortable columns
- Context menu: Download

#### Transfer Queue Panel
- Collapsible (toggle button in divider)
- Table: File name, Direction (↑/↓), Progress bar, Status, Speed
- Buttons: Clear completed, Cancel all

#### Connection Sheet
- Fields: Name, Host, Port (default 22), Username, Password, Private Key (optional), Key Passphrase (optional)
- Buttons: Cancel, Save (or Connect)

## 3. Functionality Specification

### 3.1 Core Features

1. **Connection Management** (Priority: High)
   - Add, edit, delete saved connections
   - Store connections in Property List file
   - Quick connect with inline toolbar field

2. **Remote File Browser** (Priority: High)
   - List remote files/folders in table view
   - Navigate into folders
   - Navigate to parent directory
   - Sort by any column
   - Refresh current directory

3. **File Transfer** (Priority: High)
   - Drag files from Finder to upload
   - Drag files from browser to Finder to download
   - Transfer queue with progress
   - Transfer history

### 3.2 User Flows

1. **Quick Connect Flow**:
   - Enter host/username/password in toolbar → Click Connect → Browse files

2. **Saved Connection Flow**:
   - Select saved connection in sidebar → Click/double-click → Connect → Browse

3. **Upload Flow**:
   - Select folder in browser → Drag files from Finder → Show in transfer queue → Complete

4. **Download Flow**:
   - Select files in browser → Drag to Finder → Show in transfer queue → Complete

### 3.3 Architecture (MVVM)

- **Models**: `FTPServer`, `RemoteFile`, `TransferItem`
- **ViewModels**: `ConnectionListViewModel`, `FileBrowserViewModel`, `TransferQueueViewModel`
- **Views**: SwiftUI views for all UI components

### 3.4 Edge Cases & Error Handling

- Connection timeout/failure: Show alert, update status indicator
- Permission denied: Show error message in browser
- Transfer failure: Show error in queue, allow retry
- Invalid credentials: Show specific error message

## 4. Technical Specification

### 4.1 Dependencies

No third-party socket libraries. The SFTP protocol is implemented from scratch as a standalone Swift package (`FTPClient/`) on top of Apple's own networking/crypto stack:

- **SwiftNIO** (`apple/swift-nio`): async networking / channel pipeline
- **SwiftNIO SSH** (`apple/swift-nio-ssh`): SSH transport, key exchange, auth
- **SwiftCrypto** (`apple/swift-crypto`): cryptographic primitives
- **swift-log** (`apple/swift-log`): structured logging

`Citadel` is explicitly excluded (see `FTPClient/REQUIREMENTS.md`) — do not add it as a dependency.

### 4.2 Storage

- **Connections**: Property list file at `~/Library/Application Support/iFTP/connections.plist`, read/written by `ConnectionStorage` (`Ferri/Ferri/Services/ConnectionStorage.swift`) via `PropertyListEncoder`/`Decoder`.
- **Preferences**: none currently persisted (no `UserDefaults` usage in the app).

### 4.3 File Structure

Two-module workspace (`Ferri.xcworkspace`): the SwiftUI app and the SFTP package are separate build products joined by a local Swift package dependency.

```
Ferri.xcworkspace
├── Ferri/                          # Xcode app project
│   └── Ferri/
│       ├── FerriApp.swift
│       ├── ContentView.swift
│       ├── Models/
│       │   └── TransferItem.swift  # RemoteFile/FTPServer live in FTPClient
│       ├── ViewModels/
│       │   ├── ConnectionListViewModel.swift
│       │   ├── FileBrowserViewModel.swift
│       │   └── TransferQueueViewModel.swift
│       ├── Views/
│       │   ├── MainView.swift
│       │   ├── SidebarView.swift
│       │   ├── FileBrowserView.swift
│       │   ├── TransferQueueView.swift
│       │   ├── ConnectionSheet.swift
│       │   └── FilePromiseDragSource.swift   # NSFilePromiseProvider drag-to-Finder bridge
│       ├── Services/
│       │   └── ConnectionStorage.swift
│       └── Assets.xcassets
└── FTPClient/                      # Swift package, the SFTP client library
    └── Sources/FTPClient/
        ├── FTPClient.swift         # public facade (FTPClient.shared)
        ├── FTPClientProtocol.swift # protocol the app codes against (enables mocking)
        ├── SFTPClient.swift        # actor: connection/auth/transfer logic (NIOSSH)
        ├── SFTPProtocol.swift      # SFTP wire-format encode/decode
        ├── RemoteFile.swift
        └── FTPServer.swift
```

### 4.4 Supported Protocols

SFTP only. Read/browse/download operations only — no remote mutation (delete/rename/create-folder are intentionally unimplemented in `FileBrowserViewModel`, whose corresponding methods throw "not supported").

## 5. System Integration

- **Light/Dark Mode**: Full support via system colors
- **Menu Bar**: Standard Edit, View, Window, Help menus
- **Keyboard Shortcuts**:
  - Cmd+N: New connection
  - Cmd+R: Refresh
  - Cmd+[: Go back
  - Cmd+]: Go forward
  - Cmd+↑: Go to parent

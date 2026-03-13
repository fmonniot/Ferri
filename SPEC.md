# iFTP - macOS FTP Client Specification

## 1. Project Overview

- **Project Name**: iFTP
- **Type**: macOS Native Application (Xcode)
- **Purpose**: A lightweight FTP client for macOS allowing users to connect to FTP servers, browse remote files, and transfer files via drag & drop from Finder.

## 2. UI/UX Specification

### 2.1 Window Structure

- **Main Window**: Single window with `NSSplitView` layout
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
- Context menu: Download, Delete, Rename, New Folder

#### Transfer Queue Panel
- Collapsible (toggle button in divider)
- Table: File name, Direction (↑/↓), Progress bar, Status, Speed
- Buttons: Clear completed, Cancel all

#### Connection Sheet
- Fields: Name, Host, Port (default 21), Username, Password, Private Key (optional)
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

4. **File Operations** (Priority: Medium)
   - Delete remote files/folders
   - Rename remote files/folders
   - Create new remote folder

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

- **BlueSocket** or similar: For low-level socket/FTP communication
- Alternative: Use Foundation's `URLSession` with FTP (limited)
- Consider: **CFNetwork** framework for FTP

### 4.2 Storage

- **Connections**: Property List file in Application Support directory
- **Preferences**: UserDefaults

### 4.3 File Structure

```
iFTP/
├── App/
│   └── iFTPApp.swift
├── Models/
│   ├── FTPServer.swift
│   ├── RemoteFile.swift
│   └── TransferItem.swift
├── ViewModels/
│   ├── ConnectionListViewModel.swift
│   ├── FileBrowserViewModel.swift
│   └── TransferQueueViewModel
├── Views/
│   ├── MainView.swift
│   ├── SidebarView.swift
│   ├── FileBrowserView.swift
│   ├── TransferQueueView.swift
│   └── ConnectionSheet.swift
├── Services/
│   ├── FTPClient.swift
│   └── ConnectionStorage.swift
└── Resources/
    └── Assets.xcassets
```

### 4.4 Supported Protocols

- **Initial**: FTP (plain, not FTPS)
- **Future**: SFTP, FTPS

## 5. System Integration

- **Light/Dark Mode**: Full support via system colors
- **Menu Bar**: Standard Edit, View, Window, Help menus
- **Keyboard Shortcuts**:
  - Cmd+N: New connection
  - Cmd+R: Refresh
  - Cmd+[: Go back
  - Cmd+]: Go forward
  - Cmd+↑: Go to parent

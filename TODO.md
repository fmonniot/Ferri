# TODO

Open issues, written to be actionable by a future session without extra context-gathering. This is now the single source of tasks for the repo — the old `FTPClient/TODO.md` audit doc has been folded in below and removed; anything marked resolved there was dropped, same as the app-side items resolved since the last pass (data-channel timeout, folder download, transfer-pane wiring, VSplitView layout, refresh-preserves-path, double-click-to-open, file selection highlight). See git history for the old wording if needed.

## FTPClient package

- **Revisit `SFTPClient.isConnectedFlag`'s `nonisolated(unsafe)` read.** It was previously made properly synchronized but reverted because the test suite needed the synchronous unsafe read — see git history around `SFTPClient.swift` for that revert. Reads of `isConnected` from outside the actor aren't ordering-guaranteed against actor-isolated writes. Revisit with either an atomic (`swift-atomics`) or by making the tests tolerate an `async` `isConnected` property, rather than leaving the unsafe read in place indefinitely.
- **Use a stronger type than `String` for remote paths** (low priority). Plain `String` throughout lets invalid/empty paths pass silently. A lightweight `SFTPPath` wrapper, or at minimum validation in `resolvePath`, would catch malformed input earlier.

## Ferri app

- **Wire the Finder file-promise completion status icon.** `FilePromiseDragSourceView` (`Ferri/Ferri/Views/FilePromiseDragSource.swift`) fulfills promises but doesn't report incremental progress back to `NSFilePromiseProvider`/Finder, so Finder's progress/completion badge on the destination file never updates during a drag-drop download. Best tested against a large remote file, since small test files finish before the badge would visibly update.
- **Expand Ferri app test coverage.** `Ferri/FerriTests/FerriTests.swift` already has 36 mock-based tests (`MockFTPClient`, no Docker/network needed — works fine under App Sandbox, contrary to the old note here). Audit for gaps: `FilePromiseDragSourceView`'s drag/download logic and `TransferQueueViewModel`'s pause/resume/cancel paths look under-tested relative to the other ViewModels.

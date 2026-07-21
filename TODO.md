# TODO

Open issues, written to be actionable by a future session without extra context-gathering. This is now the single source of tasks for the repo — the old `FTPClient/TODO.md` audit doc has been folded in below and removed; anything marked resolved there was dropped, same as the app-side items resolved since the last pass (data-channel timeout, folder download, transfer-pane wiring, VSplitView layout, refresh-preserves-path, double-click-to-open, file selection highlight). See git history for the old wording if needed.

## Ferri app

- **Expand Ferri app test coverage.** `Ferri/FerriTests/FerriTests.swift` already has 53 mock-based tests (`MockFTPClient`, no Docker/network needed — works fine under App Sandbox, contrary to the old note here). Audit for gaps: `FilePromiseDragSourceView`'s drag-gesture/promise-fulfillment plumbing itself (as opposed to the shared `RemoteDownloader` recursion it now delegates to, which is covered via `FileBrowserViewModel.downloadFiles` tests) looks under-tested relative to the other ViewModels.


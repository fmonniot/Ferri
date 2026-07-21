# TODO

Open issues, written to be actionable by a future session without extra context-gathering. This is now the single source of tasks for the repo — the old `FTPClient/TODO.md` audit doc has been folded in below and removed; anything marked resolved there was dropped, same as the app-side items resolved since the last pass (data-channel timeout, folder download, transfer-pane wiring, VSplitView layout, refresh-preserves-path, double-click-to-open, file selection highlight). See git history for the old wording if needed.

## Ferri app

- **Expand Ferri app test coverage.** `Ferri/FerriTests/FerriTests.swift` already has 53 mock-based tests (`MockFTPClient`, no Docker/network needed — works fine under App Sandbox, contrary to the old note here). Audit for gaps: `FilePromiseDragSourceView`'s drag-gesture/promise-fulfillment plumbing itself (as opposed to the shared `RemoteDownloader` recursion it now delegates to, which is covered via `FileBrowserViewModel.downloadFiles` tests) looks under-tested relative to the other ViewModels.

# To be triaged

- **`retryTransfer` (`Ferri/Ferri/ViewModels/TransferQueueViewModel.swift`) doesn't actually restart the download.** It resets a failed/cancelled row's status to `.queued` and clears its bytes/error, but never calls `runDownload` — so clicking "Retry" in the transfer queue just leaves the row stuck at `.queued` forever. Compare with `togglePause`'s resume branch, which does call `runDownload(id:resumeOffset:)` after flipping status. Found while adding group-retry support (`retryGroupFailed`), which inherits the same gap since it delegates to `retryTransfer` per failed child.


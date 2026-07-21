# TODO

Open issues, written to be actionable by a future session without extra context-gathering. This is now the single source of tasks for the repo — the old `FTPClient/TODO.md` audit doc has been folded in below and removed; anything marked resolved there was dropped, same as the app-side items resolved since the last pass (data-channel timeout, folder download, transfer-pane wiring, VSplitView layout, refresh-preserves-path, double-click-to-open, file selection highlight). See git history for the old wording if needed.

## Ferri app

- **Expand Ferri app test coverage.** `Ferri/FerriTests/FerriTests.swift` already has 50 mock-based tests (`MockFTPClient`, no Docker/network needed — works fine under App Sandbox, contrary to the old note here). Audit for gaps: `FilePromiseDragSourceView`'s drag/download logic (recursion into `downloadDirectoryRecursively` itself, as opposed to the mock's own `listDirectoryRecursively`) looks under-tested relative to the other ViewModels.
- **Surface a clear error when a saved connection's initial directory is misconfigured.** `MainView` (`Ferri/Ferri/Views/MainView.swift:146`) calls `fileBrowserViewModel.loadDirectory(at: server.initialDirectoryPath ?? "")` right after connecting. If that path doesn't exist or isn't listable on the server, the user sees a raw, unhelpful `"The operation couldn't be completed. (FTPClient.SFTPClientError error 3.)"` alert — traced live to a misconfigured `initialDirectoryPath` on a connection to `server.ashelia.xyz`. Root cause is two-fold: (1) `SFTPClientError` (`FTPClient/Sources/FTPClient/SFTPClient.swift:14`) only conforms to `CustomStringConvertible`, not `LocalizedError`, so its `description` never reaches the alert shown to the user; and (2) there's no fallback when the configured initial directory fails — it should fall back to `/` (or the server's actual home directory) and surface a dismissible warning instead of leaving the browser on a hard error. Fix both: make `SFTPClientError` conform to `LocalizedError` (`errorDescription`), and add a fallback-to-root path in the post-connect load.

# To be triaged

- Add the ability to download multiple selected items at once
- When the the SFTP connection die (network issue, like laptop going to sleep), clicking the refresh button should attempt to re-open the connection instead of strictly doing a file listing.
- Remove the overflow menu that only contains "add a new connection". That button is already in the left pane. Same logic for the refresh button, it's already next to the navigation buttons.
- The current speed and size indicators of a transfer item is currently shifting a lot visually (e.g. when size change from 9.23MB to 9.3MB to 10.1MB. We should instead have a fixed size for the size/speed text to avoid distraction.
- **`retryTransfer` (`Ferri/Ferri/ViewModels/TransferQueueViewModel.swift`) doesn't actually restart the download.** It resets a failed/cancelled row's status to `.queued` and clears its bytes/error, but never calls `runDownload` — so clicking "Retry" in the transfer queue just leaves the row stuck at `.queued` forever. Compare with `togglePause`'s resume branch, which does call `runDownload(id:resumeOffset:)` after flipping status. Found while adding group-retry support (`retryGroupFailed`), which inherits the same gap since it delegates to `retryTransfer` per failed child.


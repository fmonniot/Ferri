# TODO

Open issues, written to be actionable by a future session without extra context-gathering.

## Ferri app

- **Flaky test: `FileBrowserViewModelTests.downloadFilesGroupsSingleDirectory()`.** Fails intermittently under a full `RunAllTests` pass (observed `filesTotal == 1`, expected `2`) but passes reliably in isolation. Root cause is timing: `FileBrowserViewModel.downloadDirectoryIntoGroup` kicks off the recursive download in a detached `Task`, and the test asserts the group's rolled-up file count before that Task has enqueued every child. The test needs to wait for the group to reach its expected child count (poll/await) rather than reading it after a fixed point. Same latent race likely affects the sibling `downloadFiles*` group tests. Not introduced by the coverage expansion below — pre-existing.

- **`FilePromiseDragSourceView` drag/promise plumbing is still only smoke-tested.** The shared `RemoteDownloader` recursion it delegates to is well covered (`DownloadLogicTests` + `FileBrowserViewModel.downloadFiles` tests), but the AppKit-bridging drag layer itself — `handlePan`'s multi-selection promising (`filesToDrag`/`effectiveSelection`), `NSFilePromiseProvider` fulfillment, and the Finder `NSProgress` publish ordering — has no unit coverage, and per `CLAUDE.md` a real Finder drop can't be driven from XCUITest (the `FerriUITests` drag test only asserts a drag *reaches* `beginDraggingSession`). Extracting the pure selection/promise-list logic out of the `NSView` into a testable helper would let most of this be unit-tested without a live drag; the actual drop still needs a manual check.

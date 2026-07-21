# TODO

Open issues, written to be actionable by a future session without extra context-gathering.

## Ferri app

- **Flaky test: `FileBrowserViewModelTests.downloadFilesGroupsSingleDirectory()`.** Fails intermittently under a full `RunAllTests` pass (observed `filesTotal == 1`, expected `2`) but passes reliably in isolation. Root cause is timing: `FileBrowserViewModel.downloadDirectoryIntoGroup` kicks off the recursive download in a detached `Task`, and the test asserts the group's rolled-up file count before that Task has enqueued every child. The test needs to wait for the group to reach its expected child count (poll/await) rather than reading it after a fixed point. Same latent race likely affects the sibling `downloadFiles*` group tests. Not introduced by the coverage expansion below — pre-existing.

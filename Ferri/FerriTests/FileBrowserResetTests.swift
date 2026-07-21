import Testing
import Foundation
@testable import Ferri
@testable import FTPClient

// MARK: - FileBrowserViewModel Reset Tests

/// Covers `FileBrowserViewModel.reset()`, which isn't exercised by the existing
/// `FileBrowserViewModelTests` suite in `FerriTests.swift`.
@MainActor
struct FileBrowserResetTests {

    private func makeMockClient(files: [RemoteFile] = [], currentPath: String = "/home") -> MockFTPClient {
        let mock = MockFTPClient()
        mock.mockFiles = files
        mock.mockCurrentPath = currentPath
        return mock
    }

    private func sampleFiles() -> [RemoteFile] {
        [
            RemoteFile(name: "docs", path: "/home/docs", isDirectory: true, size: 4096),
            RemoteFile(name: "readme.txt", path: "/home/readme.txt", isDirectory: false, size: 1024),
        ]
    }

    @Test
    func resetClearsAllStateAfterNavigation() async {
        let mock = makeMockClient(files: sampleFiles(), currentPath: "/home")
        let vm = FileBrowserViewModel(ftpClient: mock)

        await vm.loadDirectory(at: "/home")
        mock.mockCurrentPath = "/home/docs"
        await vm.loadDirectory(at: "/home/docs")

        // Sanity check that state is non-default before reset.
        #expect(vm.files.isEmpty == false)
        #expect(vm.currentPath != "/")
        #expect(vm.pathHistory.isEmpty == false)
        #expect(vm.historyIndex != -1)

        vm.reset()

        #expect(vm.files == [])
        #expect(vm.currentPath == "/")
        #expect(vm.isLoading == false)
        #expect(vm.errorMessage == nil)
        #expect(vm.isPermissionDenied == false)
        #expect(vm.initialDirectoryWarning == nil)
        #expect(vm.pathHistory == [])
        #expect(vm.historyIndex == -1)
    }

    @Test
    func resetClearsInitialDirectoryWarning() async {
        let mock = makeMockClient(files: sampleFiles(), currentPath: "/")
        mock.failListDirectoryForPaths = ["/broken"]
        mock.listDirectoryError = SFTPClientError.requestFailed(3, "Permission denied")

        let vm = FileBrowserViewModel(ftpClient: mock)
        await vm.loadInitialDirectory(at: "/broken")
        #expect(vm.initialDirectoryWarning != nil)

        vm.reset()

        #expect(vm.initialDirectoryWarning == nil)
        #expect(vm.files == [])
        #expect(vm.currentPath == "/")
        #expect(vm.pathHistory == [])
        #expect(vm.historyIndex == -1)
    }

    @Test
    func resetClearsErrorAndPermissionDeniedState() async {
        let mock = makeMockClient()
        mock.shouldFailListDirectory = true
        mock.listDirectoryError = SFTPClientError.requestFailed(3, "Permission denied")

        let vm = FileBrowserViewModel(ftpClient: mock)
        await vm.loadDirectory(at: "/home")
        #expect(vm.isPermissionDenied == true)

        vm.reset()

        #expect(vm.errorMessage == nil)
        #expect(vm.isPermissionDenied == false)
        #expect(vm.isLoading == false)
    }

    @Test
    func resetOnFreshViewModelIsANoOpOnDefaults() {
        let mock = makeMockClient()
        let vm = FileBrowserViewModel(ftpClient: mock)

        vm.reset()

        #expect(vm.files == [])
        #expect(vm.currentPath == "/")
        #expect(vm.isLoading == false)
        #expect(vm.errorMessage == nil)
        #expect(vm.isPermissionDenied == false)
        #expect(vm.initialDirectoryWarning == nil)
        #expect(vm.pathHistory == [])
        #expect(vm.historyIndex == -1)
    }
}

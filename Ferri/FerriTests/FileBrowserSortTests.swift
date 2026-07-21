import Testing
import Foundation
@testable import Ferri
@testable import FTPClient

// MARK: - FileBrowserViewModel Sort Tests

/// Covers sorting behavior not exercised by the existing `FileBrowserViewModelTests` suite in
/// `FerriTests.swift` (which only tests `sortBy` toggling and name sorting): the explicit-direction
/// `applySort(column:ascending:)` entry point, sorting by size/date/permissions, and the
/// directories-first invariant that applies regardless of column.
@MainActor
struct FileBrowserSortTests {

    private func makeMockClient(files: [RemoteFile] = [], currentPath: String = "/home") -> MockFTPClient {
        let mock = MockFTPClient()
        mock.mockFiles = files
        mock.mockCurrentPath = currentPath
        return mock
    }

    private func sizeFiles() -> [RemoteFile] {
        [
            RemoteFile(name: "big.bin", path: "/home/big.bin", isDirectory: false, size: 3000),
            RemoteFile(name: "small.txt", path: "/home/small.txt", isDirectory: false, size: 100),
            RemoteFile(name: "medium.dat", path: "/home/medium.dat", isDirectory: false, size: 1500),
        ]
    }

    @Test
    func applySortSetsColumnAndOrderAscending() async {
        let mock = makeMockClient(files: sizeFiles())
        let vm = FileBrowserViewModel(ftpClient: mock)
        await vm.loadDirectory(at: "/home")

        vm.applySort(column: .size, ascending: true)

        #expect(vm.sortColumn == .size)
        #expect(vm.sortOrder == .ascending)
        #expect(vm.files.map(\.name) == ["small.txt", "medium.dat", "big.bin"])
    }

    @Test
    func applySortSetsColumnAndOrderDescending() async {
        let mock = makeMockClient(files: sizeFiles())
        let vm = FileBrowserViewModel(ftpClient: mock)
        await vm.loadDirectory(at: "/home")

        vm.applySort(column: .size, ascending: false)

        #expect(vm.sortColumn == .size)
        #expect(vm.sortOrder == .descending)
        #expect(vm.files.map(\.name) == ["big.bin", "medium.dat", "small.txt"])
    }

    /// Unlike `sortBy`, calling `applySort` twice with the same column+direction must not toggle -
    /// it always lands on the direction passed in, independent of whatever the prior state was.
    @Test
    func applySortDoesNotToggleOnRepeatedCalls() async {
        let mock = makeMockClient(files: sizeFiles())
        let vm = FileBrowserViewModel(ftpClient: mock)
        await vm.loadDirectory(at: "/home")

        vm.applySort(column: .size, ascending: true)
        vm.applySort(column: .size, ascending: true)

        #expect(vm.sortOrder == .ascending)
        #expect(vm.files.map(\.name) == ["small.txt", "medium.dat", "big.bin"])
    }

    @Test
    func sortBySizeAscending() async {
        let mock = makeMockClient(files: sizeFiles())
        let vm = FileBrowserViewModel(ftpClient: mock)
        await vm.loadDirectory(at: "/home")

        vm.sortBy(.size)

        #expect(vm.sortColumn == .size)
        #expect(vm.sortOrder == .ascending)
        #expect(vm.files.map(\.size) == [100, 1500, 3000])
    }

    @Test
    func sortBySizeDescending() async {
        let mock = makeMockClient(files: sizeFiles())
        let vm = FileBrowserViewModel(ftpClient: mock)
        await vm.loadDirectory(at: "/home")

        vm.sortBy(.size) // ascending
        vm.sortBy(.size) // descending

        #expect(vm.sortOrder == .descending)
        #expect(vm.files.map(\.size) == [3000, 1500, 100])
    }

    /// A file with a `nil` modificationDate is treated as `Date.distantPast` by `sortFiles`, so
    /// it must sort as the earliest file when ascending.
    @Test
    func sortByDateOrdersFilesAndTreatsNilAsDistantPast() async {
        let older = Date(timeIntervalSince1970: 1000)
        let newer = Date(timeIntervalSince1970: 100_000)
        let files = [
            RemoteFile(name: "newer.txt", path: "/home/newer.txt", isDirectory: false, modificationDate: newer),
            RemoteFile(name: "no-date.txt", path: "/home/no-date.txt", isDirectory: false, modificationDate: nil),
            RemoteFile(name: "older.txt", path: "/home/older.txt", isDirectory: false, modificationDate: older),
        ]
        let mock = makeMockClient(files: files)
        let vm = FileBrowserViewModel(ftpClient: mock)
        await vm.loadDirectory(at: "/home")

        vm.applySort(column: .date, ascending: true)

        // nil (distantPast) sorts before both real dates.
        #expect(vm.files.map(\.name) == ["no-date.txt", "older.txt", "newer.txt"])
    }

    @Test
    func sortByDateDescending() async {
        let older = Date(timeIntervalSince1970: 1000)
        let newer = Date(timeIntervalSince1970: 100_000)
        let files = [
            RemoteFile(name: "newer.txt", path: "/home/newer.txt", isDirectory: false, modificationDate: newer),
            RemoteFile(name: "no-date.txt", path: "/home/no-date.txt", isDirectory: false, modificationDate: nil),
            RemoteFile(name: "older.txt", path: "/home/older.txt", isDirectory: false, modificationDate: older),
        ]
        let mock = makeMockClient(files: files)
        let vm = FileBrowserViewModel(ftpClient: mock)
        await vm.loadDirectory(at: "/home")

        vm.applySort(column: .date, ascending: false)

        #expect(vm.files.map(\.name) == ["newer.txt", "older.txt", "no-date.txt"])
    }

    @Test
    func sortByPermissionsOrdersByPermissionString() async {
        let files = [
            RemoteFile(name: "world.txt", path: "/home/world.txt", isDirectory: false, permissions: "rw-r--r--"),
            RemoteFile(name: "exec.sh", path: "/home/exec.sh", isDirectory: false, permissions: "rwxr-xr-x"),
            RemoteFile(name: "locked.txt", path: "/home/locked.txt", isDirectory: false, permissions: "r--------"),
        ]
        let mock = makeMockClient(files: files)
        let vm = FileBrowserViewModel(ftpClient: mock)
        await vm.loadDirectory(at: "/home")

        vm.applySort(column: .permissions, ascending: true)

        let sortedPermissions = vm.files.map(\.permissions)
        #expect(sortedPermissions == sortedPermissions.sorted())
        #expect(vm.files.map(\.name) == ["locked.txt", "world.txt", "exec.sh"])
    }

    @Test
    func sortByPermissionsDescending() async {
        let files = [
            RemoteFile(name: "world.txt", path: "/home/world.txt", isDirectory: false, permissions: "rw-r--r--"),
            RemoteFile(name: "exec.sh", path: "/home/exec.sh", isDirectory: false, permissions: "rwxr-xr-x"),
            RemoteFile(name: "locked.txt", path: "/home/locked.txt", isDirectory: false, permissions: "r--------"),
        ]
        let mock = makeMockClient(files: files)
        let vm = FileBrowserViewModel(ftpClient: mock)
        await vm.loadDirectory(at: "/home")

        vm.applySort(column: .permissions, ascending: false)

        #expect(vm.files.map(\.name) == ["exec.sh", "world.txt", "locked.txt"])
    }

    /// Regardless of sort column or direction, directories must always sort before files - this
    /// holds even for a descending size sort where a small directory would otherwise land after
    /// a large file.
    @Test
    func directoriesAlwaysSortBeforeFilesOnDescendingSizeSort() async {
        let files = [
            RemoteFile(name: "huge-file.bin", path: "/home/huge-file.bin", isDirectory: false, size: 1_000_000),
            RemoteFile(name: "tiny-dir", path: "/home/tiny-dir", isDirectory: true, size: 0),
            RemoteFile(name: "medium-file.bin", path: "/home/medium-file.bin", isDirectory: false, size: 5000),
            RemoteFile(name: "another-dir", path: "/home/another-dir", isDirectory: true, size: 4096),
        ]
        let mock = makeMockClient(files: files)
        let vm = FileBrowserViewModel(ftpClient: mock)
        await vm.loadDirectory(at: "/home")

        vm.applySort(column: .size, ascending: false)

        // The two directories occupy the first two slots, in whatever relative order the size
        // comparison puts them, followed by both files.
        #expect(vm.files[0].isDirectory == true)
        #expect(vm.files[1].isDirectory == true)
        #expect(vm.files[2].isDirectory == false)
        #expect(vm.files[3].isDirectory == false)
        #expect(Set(vm.files.prefix(2).map(\.name)) == ["tiny-dir", "another-dir"])
        #expect(vm.files.suffix(2).map(\.name) == ["huge-file.bin", "medium-file.bin"])
    }
}

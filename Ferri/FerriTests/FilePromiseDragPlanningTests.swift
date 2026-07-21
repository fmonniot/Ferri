import Testing
import Foundation
import AppKit
import UniformTypeIdentifiers
@testable import Ferri
@testable import FTPClient

// MARK: - FilePromiseDragPlanning Tests

/// Unit-tests the pure selection/promise-list logic extracted from `FilePromiseDragSourceView`
/// (see TODO.md) — the AppKit-bridging drag/promise-fulfillment plumbing around it still needs a
/// manual Finder drop to verify.
struct FilePromiseDragPlanningTests {

    private func file(_ name: String, isDirectory: Bool = false) -> RemoteFile {
        RemoteFile(name: name, path: "/home/\(name)", isDirectory: isDirectory)
    }

    // MARK: filesToDrag

    @Test
    func filesToDragReturnsJustTheFileWhenSelectionIsEmpty() {
        let dragged = file("a.txt")

        let result = FilePromiseDragPlanning.filesToDrag(startingFrom: dragged, selectedFiles: [])

        #expect(result.map(\.name) == ["a.txt"])
    }

    @Test
    func filesToDragReturnsJustTheFileWhenSelectionIsASingleOtherFile() {
        let dragged = file("a.txt")
        let other = file("b.txt")

        let result = FilePromiseDragPlanning.filesToDrag(startingFrom: dragged, selectedFiles: [other])

        #expect(result.map(\.name) == ["a.txt"])
    }

    @Test
    func filesToDragReturnsJustTheFileWhenSelectionHasMultipleItemsButNotTheDraggedOne() {
        let dragged = file("a.txt")
        let selected = [file("b.txt"), file("c.txt")]

        let result = FilePromiseDragPlanning.filesToDrag(startingFrom: dragged, selectedFiles: selected)

        #expect(result.map(\.name) == ["a.txt"])
    }

    @Test
    func filesToDragReturnsWholeSelectionWhenDraggedFileIsPartOfAMultiItemSelection() {
        let dragged = file("a.txt")
        let selected = [dragged, file("b.txt"), file("c.txt")]

        let result = FilePromiseDragPlanning.filesToDrag(startingFrom: dragged, selectedFiles: selected)

        #expect(result.map(\.name) == ["a.txt", "b.txt", "c.txt"])
    }

    @Test
    func filesToDragMatchesByIdNotEquality() {
        // Two RemoteFiles with the same path/name but different ids (e.g. stale selection state
        // from before a refresh) must not be treated as the same file.
        let dragged = file("a.txt")
        let staleCopy = RemoteFile(name: "a.txt", path: "/home/a.txt", isDirectory: false)

        let result = FilePromiseDragPlanning.filesToDrag(startingFrom: dragged, selectedFiles: [staleCopy, file("b.txt")])

        #expect(result.map(\.name) == ["a.txt"])
    }

    // MARK: fileType

    @Test
    func fileTypeIsFolderForDirectories() {
        #expect(FilePromiseDragPlanning.fileType(for: file("dir", isDirectory: true)) == UTType.folder.identifier)
    }

    @Test
    func fileTypeIsDataForRegularFiles() {
        #expect(FilePromiseDragPlanning.fileType(for: file("a.txt")) == UTType.data.identifier)
    }

    // MARK: draggingFrame

    @Test
    func draggingFrameIsUnoffsetForTheFirstItem() {
        let bounds = NSRect(x: 0, y: 0, width: 20, height: 20)

        let frame = FilePromiseDragPlanning.draggingFrame(bounds: bounds, index: 0)

        #expect(frame == bounds)
    }

    @Test
    func draggingFrameFansOutSubsequentItems() {
        let bounds = NSRect(x: 0, y: 0, width: 20, height: 20)

        let frame = FilePromiseDragPlanning.draggingFrame(bounds: bounds, index: 2)

        #expect(frame == bounds.offsetBy(dx: 12, dy: 12))
    }
}

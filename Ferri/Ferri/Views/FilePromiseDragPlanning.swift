import Foundation
import AppKit
import UniformTypeIdentifiers
import FTPClient

/// Pure selection/promise-list logic pulled out of `FilePromiseDragSourceView` so it can be
/// unit-tested directly. The rest of that view — `NSFilePromiseProvider` fulfillment, the
/// `NSDraggingSession`, Finder's `NSProgress` publish ordering — is AppKit-bridging plumbing that
/// can't be driven from XCUITest (see TODO.md); this is the slice of it that can.
enum FilePromiseDragPlanning {

    /// The items a drag from `file` should carry: the whole current selection when `file` is part
    /// of a multi-item selection, or just `file` otherwise — matching the context menu's
    /// `effectiveSelection` convention (right-clicking within vs. outside a selection).
    static func filesToDrag(startingFrom file: RemoteFile, selectedFiles: [RemoteFile]) -> [RemoteFile] {
        guard selectedFiles.count > 1, selectedFiles.contains(where: { $0.id == file.id }) else {
            return [file]
        }
        return selectedFiles
    }

    /// The pasteboard file-type identifier a promise provider should advertise for `file`.
    static func fileType(for file: RemoteFile) -> String {
        file.isDirectory ? UTType.folder.identifier : UTType.data.identifier
    }

    /// The fanned-out drag frame for the `index`-th item in a multi-item drag, so the preview
    /// reads as a stack rather than a single overlapping icon.
    static func draggingFrame(bounds: NSRect, index: Int) -> NSRect {
        let offset = CGFloat(index) * 6
        return bounds.offsetBy(dx: offset, dy: offset)
    }
}

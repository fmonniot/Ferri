//
//  FerriUITests.swift
//  FerriUITests
//
//  Created by François Monniot on 3/14/26.
//

import XCTest

/// Drives the real app against `UITestMockFTPClient` (a fixed, in-memory directory tree
/// wired in behind the `-UITestMode` launch argument - see `Ferri/Views/UITestSupport.swift`)
/// so file-browser interactions can be exercised without Docker/a live SFTP server.
///
/// Fixed tree:
///   /
///     Documents/
///       notes.txt
///     Photos/            (empty)
///     readme.txt
///
/// SwiftUI's `Table` on macOS surfaces as an accessibility `Outline` (`OutlineRow`/`Cell`),
/// not a `Table`/`Row` - queries below go through `app.outlines` accordingly. Each file's
/// name `Text` carries an explicit `accessibilityIdentifier("file.<name>")` (FileBrowserView)
/// so rows can be found and selection state read reliably regardless of display text.
final class FerriUITests: XCTestCase {

    private var launchedApp: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        // Each test launches its own app instance; leaving it running lets its window
        // occlude the next test's freshly-launched window ("Unable to find hit point").
        launchedApp?.terminate()
        launchedApp = nil
    }

    private func launchApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode"] + extraArguments
        app.launch()
        launchedApp = app
        return app
    }

    private func row(_ app: XCUIApplication, named identifier: String) -> XCUIElement {
        app.outlines.outlineRows.containing(.staticText, identifier: identifier).element
    }

    @MainActor
    func testSingleClickSelectsExactlyOneRowAtATime() throws {
        let app = launchApp()

        let documents = app.staticTexts["file.Documents"]
        let readme = app.staticTexts["file.readme.txt"]
        XCTAssertTrue(documents.waitForExistence(timeout: 5))

        let documentsRow = row(app, named: "file.Documents")
        let readmeRow = row(app, named: "file.readme.txt")

        documents.click()
        XCTAssertTrue(documentsRow.isSelected, "Clicking a row should select it")

        // Regression check for the drag-source overlay double-delivering mouseDown: a second
        // click on the SAME row must not toggle it into some doubled/extra-selected state -
        // it should simply remain the sole selected row.
        documents.click()
        XCTAssertTrue(documentsRow.isSelected)
        XCTAssertFalse(readmeRow.isSelected)

        // Clicking a different row must move the selection, not extend it to both rows.
        readme.click()
        XCTAssertTrue(readmeRow.isSelected, "Clicking a second row should select it")
        XCTAssertFalse(documentsRow.isSelected, "Selecting a new row must deselect the previous one")
    }

    @MainActor
    func testDoubleClickNavigatesIntoFolderAndUpdatesBreadcrumb() throws {
        let app = launchApp()

        let documents = app.staticTexts["file.Documents"]
        XCTAssertTrue(documents.waitForExistence(timeout: 5))
        documents.doubleClick()

        // notes.txt only exists inside /Documents in the fixed test tree.
        let notes = app.staticTexts["file.notes.txt"]
        XCTAssertTrue(notes.waitForExistence(timeout: 5), "Double-clicking a folder should navigate into it")

        // Breadcrumb should now show a "Documents" crumb reflecting the new path.
        XCTAssertTrue(app.buttons["Documents"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testUpButtonNavigatesBackToParent() throws {
        let app = launchApp()

        let documents = app.staticTexts["file.Documents"]
        XCTAssertTrue(documents.waitForExistence(timeout: 5))

        let upButton = app.buttons["nav.up"]
        XCTAssertFalse(upButton.isEnabled, "Up should be disabled at the root")

        documents.doubleClick()
        XCTAssertTrue(app.staticTexts["file.notes.txt"].waitForExistence(timeout: 5))
        XCTAssertTrue(upButton.isEnabled, "Up should be enabled once inside a subfolder")

        upButton.click()
        XCTAssertTrue(app.staticTexts["file.Documents"].waitForExistence(timeout: 5), "Up should return to the root listing")
        XCTAssertTrue(app.staticTexts["file.readme.txt"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testBackAndForwardButtonsNavigateHistory() throws {
        let app = launchApp()

        let backButton = app.buttons["nav.back"]
        let forwardButton = app.buttons["nav.forward"]

        let documents = app.staticTexts["file.Documents"]
        XCTAssertTrue(documents.waitForExistence(timeout: 5))
        XCTAssertFalse(backButton.isEnabled)
        XCTAssertFalse(forwardButton.isEnabled)

        documents.doubleClick()
        XCTAssertTrue(app.staticTexts["file.notes.txt"].waitForExistence(timeout: 5))
        XCTAssertTrue(backButton.isEnabled)
        XCTAssertFalse(forwardButton.isEnabled)

        backButton.click()
        XCTAssertTrue(app.staticTexts["file.readme.txt"].waitForExistence(timeout: 5), "Back should return to the root listing")
        XCTAssertTrue(forwardButton.isEnabled, "Forward should become available after going back")

        forwardButton.click()
        XCTAssertTrue(app.staticTexts["file.notes.txt"].waitForExistence(timeout: 5), "Forward should re-enter Documents")
    }

    /// Regression test for the drag-source overlay's `NSPanGestureRecognizer`: it must get
    /// first look at mouse events (`delaysPrimaryMouseButtonEvents` at its default `true`) so
    /// it can recognize a real drag before the table's own click-tracking loop consumes the
    /// events. `FilePromiseDragSourceView.handlePan` posts `.uiTestDragSessionStarted` right
    /// before `beginDraggingSession`, which `MainView` surfaces (behind `-UITestMode`) as the
    /// hidden `debug.lastDragStartedFile` text - a real Finder drop isn't drivable from
    /// XCUITest, but reaching that call is exactly the step that silently broke, so it's what
    /// this test guards.
    @MainActor
    func testDraggingARowStartsAFilePromiseDrag() throws {
        let app = launchApp()

        let readme = app.staticTexts["file.readme.txt"]
        XCTAssertTrue(readme.waitForExistence(timeout: 5))

        let dragStatus = app.staticTexts["debug.lastDragStartedFile"]
        XCTAssertTrue(dragStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(dragStatus.value as? String, "none")

        let source = readme.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let target = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        source.click(forDuration: 0.2, thenDragTo: target)

        let deadline = Date().addingTimeInterval(5)
        while (dragStatus.value as? String) != "readme.txt" && Date() < deadline {
            usleep(100_000)
        }
        XCTAssertEqual(dragStatus.value as? String, "readme.txt", "Dragging a row should reach beginDraggingSession")
    }

    /// Regression test for the initial-directory-fallback fix: a misconfigured
    /// `FTPServer.initialDirectoryPath` must fall back to `/` and show a dismissible warning
    /// banner instead of stranding the browser on a hard error. `-UITestModeBadInitialDirectory`
    /// (`UITestSupport`) routes `MainView`'s post-connect load through
    /// `loadInitialDirectory(at: UITestMockFTPClient.missingPath)`, a path the mock always fails.
    @MainActor
    func testMisconfiguredInitialDirectoryFallsBackToRootWithDismissibleWarning() throws {
        // Literal rather than referencing UITestSupport/UITestMockFTPClient directly - this UI
        // test target runs the compiled app as a separate process (no @testable import), so it
        // only has access to the launch argument string and the accessibility identifiers below.
        let app = launchApp(extraArguments: ["-UITestModeBadInitialDirectory"])

        // Fallback succeeded: the root listing (readme.txt, from the fixed tree) is showing,
        // not a hard error/permission-denied page.
        XCTAssertTrue(app.staticTexts["file.readme.txt"].waitForExistence(timeout: 5))

        let warning = app.staticTexts["initialDirectoryWarning.message"]
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertTrue((warning.value as? String ?? "").contains("/DoesNotExist"))

        app.buttons["initialDirectoryWarning.dismiss"].click()
        XCTAssertFalse(warning.waitForExistence(timeout: 2), "Dismissing should remove the warning banner")

        // The fallback listing itself must remain intact after dismissing the warning.
        XCTAssertTrue(app.staticTexts["file.readme.txt"].exists)
    }

    /// Regression test: a warning banner left over from one connection's fallback must not
    /// survive into the next connection just because the user never dismissed it - switching
    /// saved connections doesn't call `reset()` (only "Disconnect" does), so
    /// `loadInitialDirectory` itself has to clear any stale warning up front.
    @MainActor
    func testWarningIsResetWhenConnectingToAnotherServerWithoutDismissing() throws {
        let app = launchApp(extraArguments: ["-UITestModeBadInitialDirectory"])

        let warning = app.staticTexts["initialDirectoryWarning.message"]
        XCTAssertTrue(warning.waitForExistence(timeout: 5), "Warning should be showing from the misconfigured initial directory")

        // Simulates connecting to a second, correctly-configured server without touching the
        // dismiss button first (see the button's doc comment in MainView for why this stand-in
        // is needed instead of driving a real second connection).
        app.buttons["debug.simulateConnectToAnotherServer"].click()

        XCTAssertFalse(warning.waitForExistence(timeout: 5), "Connecting to a new server should clear the previous connection's warning")
        XCTAssertTrue(app.staticTexts["file.readme.txt"].exists, "The new connection's listing should still be showing")
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}

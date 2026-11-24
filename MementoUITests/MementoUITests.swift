//
//  MementoUITests.swift
//  MementoUITests
//
//  Created by Jessela Emile on 8/31/26.
//

import XCTest

/// Smoke tests for the main flows. The app is launched with `--uitesting`, which gives it a
/// throwaway data directory and a generated folder of six sample photos (see UITestSupport),
/// so these tests never touch the real library.
final class MementoUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Sidebar rows that are always present, with the title each screen shows.
    private let alwaysVisibleSections: [(id: String, title: String)] = [
        ("timeline", "Timeline"), ("folders", "Folders"), ("people", "People"), ("places", "Places"),
        ("needsReview", "Needs review"), ("duplicates", "Duplicates"), ("quarantine", "Quarantine"),
        ("newRun", "New run"), ("history", "History"), ("rules", "Rules")
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        // When the previous test terminated the app, window restoration can relaunch it with
        // no window at all — open one the way a person would.
        if !app.windows.firstMatch.waitForExistence(timeout: 3) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "Memento opened no window")
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    // MARK: - Tests

    @MainActor
    func testEverySidebarSectionOpens() throws {
        for section in alwaysVisibleSections {
            let row = app.buttons["sidebar.\(section.id)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Sidebar row '\(section.title)' is missing")
            row.click()
            assertScreenTitle(section.title)
        }
    }

    @MainActor
    func testScanOfSampleFolderProducesPlan() throws {
        startScanOfSampleFolder()

        assertScreenTitle("Plan", timeout: 60)
        XCTAssertTrue(app.buttons["Apply plan"].waitForExistence(timeout: 5), "Plan has no Apply button")
        let summary = app.staticTexts.matching(textContaining: "6 items").firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "Plan should include all 6 sample photos")
        // Scanning is read-only: nothing has moved yet.
        waitForFileStatus("source=6 library=0 intact=yes")
    }

    @MainActor
    func testApplyThenRevertRestoresFiles() throws {
        startScanOfSampleFolder()
        assertScreenTitle("Plan", timeout: 60)

        // Apply (Move mode by default): every photo leaves the source for the library.
        app.buttons["Apply plan"].click()
        assertScreenTitle("History", timeout: 60)
        waitForFileStatus("source=0 library=6 intact=no")

        // Revert the run from its History card.
        let card = app.buttons["history.runCard"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), "No run card in History")
        card.click()
        let revertButton = app.buttons["Revert entire run"]
        XCTAssertTrue(revertButton.waitForExistence(timeout: 5))
        revertButton.click()
        let confirm = app.buttons["Revert"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Revert confirmation didn't appear")
        confirm.click()

        let ok = app.buttons["OK"].firstMatch
        XCTAssertTrue(ok.waitForExistence(timeout: 30), "Revert result alert didn't appear")
        ok.click()

        // Every photo is back where it started, unchanged, and the library is empty again.
        waitForFileStatus("source=6 library=0 intact=yes")
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    // MARK: - Helpers

    /// Opens New run (pre-filled with the sample folders in test mode) and starts the scan.
    private func startScanOfSampleFolder() {
        waitForFileStatus("source=6 library=0 intact=yes")
        app.buttons["sidebar.newRun"].click()
        assertScreenTitle("New run")
        let start = app.buttons["Start scan"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "Start scan button is missing")
        waitUntil(start, matches: "isEnabled == true", "Start scan never became enabled", timeout: 5)
        start.click()
    }

    private func assertScreenTitle(_ title: String, timeout: TimeInterval = 5,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let header = app.staticTexts.matching(identifier: "screen.title")
            .matching(NSPredicate(format: "label == %@ OR value == %@", title, title))
            .firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: timeout),
                      "Expected the '\(title)' screen", file: file, line: line)
    }

    /// Waits for the test-mode status label (file counts in the sample folders) to read `expected`.
    private func waitForFileStatus(_ expected: String, timeout: TimeInterval = 15,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let label = app.staticTexts["uitest.fileStatus"]
        XCTAssertTrue(label.waitForExistence(timeout: 5), "Status label missing", file: file, line: line)
        let predicate = NSPredicate(format: "value == %@ OR label == %@", expected, expected)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: label)],
                                      timeout: timeout)
        XCTAssertEqual(result, .completed,
                       "File status is '\(label.value as? String ?? label.label)', expected '\(expected)'",
                       file: file, line: line)
    }

    private func waitUntil(_ element: XCUIElement, matches format: String, _ message: String,
                           timeout: TimeInterval) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, message)
    }
}

private extension XCUIElementQuery {
    func matching(textContaining text: String) -> XCUIElementQuery {
        matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text))
    }
}

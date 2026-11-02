import XCTest

/// Synthetic presentation tests exercise the actual shared window/menu views.
/// They never request Bluetooth permission, select a real device or open a link.
@MainActor final class OpenJBLUITests: XCTestCase {
    func testConfirmedWindowAndMenuAgree() {
        assertSharedPresentation("confirmed", expected: ["Confirmed: ANC"])
    }
    func testPendingKeepsConfirmedValueVisible() {
        assertSharedPresentation("pending", expected: ["Confirmed: ANC", "Pending: Ambient"])
    }
    func testStaleValuesRemainMarked() {
        assertSharedPresentation("stale", expected: ["Confirmed: ANC · stale"])
    }
    func testWorkflowDisablesOrdinaryChanges() {
        assertSharedPresentation("busy", expected: ["Busy with findMyBuds. Stop that workflow first."])
    }
    func testIndeterminateExplainsExplicitRetry() {
        assertSharedPresentation("indeterminate", expected: ["Verification failed repeatedly. Explicit Retry is required."])
    }

    private func assertSharedPresentation(_ state: String, expected: [String],
                                          file: StaticString = #filePath, line: UInt = #line) {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "io.github.lopesfelipe.OpenJBL")
        app.launchArguments = ["--ui-test-state", state]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Synthetic UI fixture — no hardware access"].waitForExistence(timeout: 10),
                      file: file, line: line)
        for text in expected {
            XCTAssertTrue(app.staticTexts[text].firstMatch.exists, "Window missing \(text)", file: file, line: line)
        }
        app.buttons["show-menu-preview"].click()
        let panel = app.sheets.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5), file: file, line: line)
        for text in expected {
            XCTAssertTrue(panel.staticTexts[text].firstMatch.exists, "Menu missing \(text)", file: file, line: line)
        }
        XCTAssertTrue(panel.staticTexts["Left/right role mapping is unverified."].exists, file: file, line: line)
        panel.buttons["Close Menu Preview"].click()
    }
}

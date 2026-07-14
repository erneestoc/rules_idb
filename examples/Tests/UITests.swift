import XCTest

/// UI tests: driven by XCUIApplication from a separate XCTRunner host app
/// that the idb runner assembles from Xcode's agent template.
class UITests: XCTestCase {
    func testAppLaunchesAndShowsLabel() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(
            app.staticTexts["rules_idb host app"].waitForExistence(timeout: 30),
            "expected the host app's label to appear"
        )
    }

    func testCanQueryHierarchy() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertGreaterThan(app.windows.count, 0)
    }
}

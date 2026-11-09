import XCTest

final class ProbeUITests: XCTestCase {
    func testRunningHostIsThisBuild() {
        let app = XCUIApplication()
        app.launch()
        let label = app.staticTexts["marker"]
        XCTAssertTrue(label.waitForExistence(timeout: 20))
        print("probe: host marker \(label.label), expected \(expectedMarker)")
        XCTAssertEqual(label.label, expectedMarker)
    }
}

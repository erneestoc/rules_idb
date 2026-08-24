import XCTest

/// A UI test that always fails. Exists so the runner's screen-recording
/// support (RULES_IDB_RECORD_VIDEO=on-failure) has a failing UI target to
/// validate against: the recording is kept only when the test fails, and a
/// UI test drives enough on-screen activity to produce a non-trivial video.
class FailingUITests: XCTestCase {
    func testLaunchesThenFails() {
        let app = XCUIApplication()
        app.launch()
        // Let the host app render so the recording has visible content.
        _ = app.staticTexts["rules_idb host app"].waitForExistence(timeout: 10)
        XCTFail("intentional failure: exercises on-failure screen recording")
    }
}

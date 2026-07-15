import XCTest

// Validates XCTSkip handling: the skipped test must not fail the run and
// must not be reported as an executed failure.
final class SkippingTests: XCTestCase {
  func testAlwaysSkipped() throws {
    throw XCTSkip("intentionally skipped to validate skip reporting")
  }

  func testPasses() {
    XCTAssertTrue(true)
  }
}

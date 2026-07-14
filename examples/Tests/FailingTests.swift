import XCTest

/// Intentionally failing tests used to verify that the idb runner correctly
/// reports failures (the idb client exits 0 even when test cases fail, so
/// the runner must derive the verdict from structured output).
class FailingTests: XCTestCase {
    func testThatPasses() {
        XCTAssertTrue(true)
    }

    func testThatFails() {
        XCTAssertEqual(1 + 1, 3, "intentional failure for runner validation")
    }
}

import XCTest

// Crashes the test host process mid-run. Used to exercise the path where idb
// detects a host crash and then has to deliver a terminal response to the
// `xctest run --json` client.
//
// Test methods run in alphabetical order, so testBCrashes sits in the middle:
// if anything is reported for testCNeverRuns, then a crash record is NOT
// terminal and the runner must not treat it as one.
class CrashingTests: XCTestCase {

    func testAPassesFirst() {
        XCTAssertTrue(true)
    }

    func testBCrashesTheHost() {
        let pointer = UnsafeMutablePointer<Int>(bitPattern: 0x1)!
        pointer.pointee = 0xDEAD
        XCTFail("unreachable: the host should have crashed")
    }

    func testCNeverRuns() {
        XCTAssertTrue(true)
    }
}

import XCTest

// Crashes the test host process mid-run. Used to exercise the path where idb
// detects a host crash: the companion reports the crash, then has to deliver a
// terminal response to the `xctest run --json` client. If that terminal write
// fails, the client is left waiting for its whole timeout.
class CrashingTests: XCTestCase {

    // A normal test, so the run has reported results before the crash.
    func testAPassesFirst() {
        XCTAssertTrue(true)
    }

    // Writing through a bogus pointer kills the host with SIGSEGV, which is a
    // genuine process crash rather than an XCTest assertion failure.
    func testBCrashesTheHost() {
        let pointer = UnsafeMutablePointer<Int>(bitPattern: 0x1)!
        pointer.pointee = 0xDEAD
        XCTFail("unreachable: the host should have crashed")
    }
}

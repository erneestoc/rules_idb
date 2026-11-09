import Foundation
import XCTest

final class OtherProbeTests: XCTestCase {
    func testRunningHostIsThisBuild() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "marker", withExtension: "txt"))
        let marker = try String(contentsOf: url, encoding: .utf8)
        print("probe: host marker \(marker), expected \(expectedOtherMarker)")
        XCTAssertEqual(marker, expectedOtherMarker)
    }

    func testSecond() {}
    func testThird() {}
}

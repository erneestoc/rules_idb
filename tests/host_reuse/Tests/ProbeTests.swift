import Foundation
import XCTest

final class ProbeTests: XCTestCase {
    func testRunningHostIsThisBuild() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "marker", withExtension: "txt"))
        let marker = try String(contentsOf: url, encoding: .utf8)
        print("probe: host marker \(marker), expected \(expectedMarker)")
        XCTAssertEqual(marker, expectedMarker)
    }

    func testSecond() {}
    func testThird() {}
}

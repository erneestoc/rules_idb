import XCTest

/// Logic (hostless) unit tests: no test host app required. The idb runner
/// executes these with `idb xctest run logic`.
class LogicTests: XCTestCase {
    func testBasicMath() {
        XCTAssertEqual((1...10).reduce(0, +), 55)
    }

    func testStringManipulation() {
        XCTAssertEqual("rules_idb".uppercased(), "RULES_IDB")
    }

    func testCodableRoundTrip() throws {
        struct Point: Codable, Equatable { let x: Int, y: Int }
        let point = Point(x: 3, y: 7)
        let data = try JSONEncoder().encode(point)
        XCTAssertEqual(try JSONDecoder().decode(Point.self, from: data), point)
    }
}

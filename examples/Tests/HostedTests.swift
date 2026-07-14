import UIKit
import XCTest

/// Hosted unit tests: these require the test host app because they touch
/// UIApplication and UIKit view hierarchy state.
class HostedTests: XCTestCase {
    func testRunsInsideHostApp() {
        // UIApplication.shared traps if there is no host app, proving these
        // tests actually run hosted.
        let application = UIApplication.shared
        XCTAssertNotNil(application.delegate, "expected to run inside the HostApp test host")
    }

    func testHostAppHasKeyWindow() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        XCTAssertFalse(windows.isEmpty && UIApplication.shared.windows.isEmpty)
    }

    func testEnvironmentPassthrough() {
        // The runner must forward --test_env variables into the hosted process.
        if let expected = ProcessInfo.processInfo.environment["RULES_IDB_SMOKE"] {
            XCTAssertEqual(expected, "1")
        }
    }

    func testMainThread() {
        let expectation = expectation(description: "main queue")
        DispatchQueue.main.async {
            XCTAssertTrue(Thread.isMainThread)
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }
}

/// A batch of small workloads so the suite runs long enough to be measurable.
class WorkloadTests: XCTestCase {
    private func churn(_ seed: Int) -> Int {
        var data = [Int]()
        data.reserveCapacity(200_000)
        var value = seed
        for _ in 0..<200_000 {
            value = (value &* 1_103_515_245 &+ 12_345) % 2_147_483_648
            data.append(value)
        }
        return data.sorted()[seed % 1000]
    }

    func testWorkload01() { XCTAssertGreaterThanOrEqual(churn(1), 0) }
    func testWorkload02() { XCTAssertGreaterThanOrEqual(churn(2), 0) }
    func testWorkload03() { XCTAssertGreaterThanOrEqual(churn(3), 0) }
    func testWorkload04() { XCTAssertGreaterThanOrEqual(churn(4), 0) }
    func testWorkload05() { XCTAssertGreaterThanOrEqual(churn(5), 0) }
    func testWorkload06() { XCTAssertGreaterThanOrEqual(churn(6), 0) }
    func testWorkload07() { XCTAssertGreaterThanOrEqual(churn(7), 0) }
    func testWorkload08() { XCTAssertGreaterThanOrEqual(churn(8), 0) }
    func testWorkload09() { XCTAssertGreaterThanOrEqual(churn(9), 0) }
    func testWorkload10() { XCTAssertGreaterThanOrEqual(churn(10), 0) }
    func testUIWork() {
        for _ in 0..<50 {
            let view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            let label = UILabel(frame: view.bounds)
            label.text = "hello"
            view.addSubview(label)
            view.setNeedsLayout()
            view.layoutIfNeeded()
        }
    }
}

import UIKit
import XCTest

/// A single hosted test that adds an XCTAttachment, used to probe whether
/// RULES_IDB_COLLECT_RESULT_BUNDLE produces a real .xcresult (with the
/// attachment payload) in idb's native (non-xcodebuild) test path.
class AttachmentTests: XCTestCase {
    func testAttachesAPayload() {
        let payload = "rules_idb attachment probe".data(using: .utf8)!
        let attachment = XCTAttachment(data: payload, uniformTypeIdentifier: "public.plain-text")
        attachment.name = "probe.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(payload.count, 26)
    }
}

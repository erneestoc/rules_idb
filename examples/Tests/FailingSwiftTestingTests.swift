import Testing

// Intentionally failing; validates that swift-testing failures fail the
// target (no false negatives through the XCTest bridge).
@Suite struct FailingSwiftTestingSuite {
  @Test func intentionallyFails() {
    #expect(1 + 1 == 3, "intentional failure for runner validation")
  }
}

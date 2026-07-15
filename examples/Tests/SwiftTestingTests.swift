import Testing

// Swift Testing (@Test) coverage: validates that the runner executes
// swift-testing tests, not only XCTest.
@Suite struct SwiftTestingSuite {
  @Test func addition() {
    #expect(1 + 1 == 2)
  }

  @Test func stringWorks() {
    #expect("rules".uppercased() == "RULES")
  }
}

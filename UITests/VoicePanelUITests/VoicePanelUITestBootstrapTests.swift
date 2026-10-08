import XCTest

final class VoicePanelUITestBootstrapTests: XCTestCase {
    func testHarnessStarts() {
        VoicePanelUITestProgress.report("bootstrap started")
        XCTAssertTrue(true)
        VoicePanelUITestProgress.report("bootstrap completed")
    }
}

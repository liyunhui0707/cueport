import XCTest
@testable import AttentionCore

final class BridgeCompatibilityTests: XCTestCase {
    func testReviewed169And170ClientsAcceptOnlyExactVersionLines() {
        for version in ["0.169.0", "0.170.0"] {
            for line in ["codex-cli \(version)", "codex-cli \(version)\n", "codex-cli \(version)\r\n"] {
                XCTAssertTrue(BridgeCompatibility.acceptsNativeVersionOutput(Data(line.utf8)))
            }
        }
    }
    func testLegacyUnknownPrereleaseAndMalformedOutputsStayRejected() {
        for line in ["codex-cli 0.166.0", "codex-cli 0.169.1", "codex-cli 0.170.1", "codex-cli 0.171.0",
                     "codex-cli 0.169.0-alpha.1", "codex-cli 0.169.0-extra", "0.169.0",
                     "warning\ncodex-cli 0.169.0", "codex-cli 0.169.0\nother output", "codex-cli 0.169.0\0"] {
            XCTAssertFalse(BridgeCompatibility.acceptsNativeVersionOutput(Data(line.utf8)))
        }
        XCTAssertFalse(BridgeCompatibility.acceptsNativeVersionOutput(Data([0xff, 0xfe])))
        XCTAssertFalse(BridgeCompatibility.acceptsNativeVersionOutput(Data(repeating: 32, count: 129)))
    }
}

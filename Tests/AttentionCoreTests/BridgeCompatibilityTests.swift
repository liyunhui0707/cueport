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
    func testStableUpgradesAreEligibleButVersionAloneDoesNotQualifyThem() {
        for version in ["0.169.1", "0.172.0", "0.200.0", "1.0.0"] {
            XCTAssertTrue(BridgeCompatibility.eligibleVersion(version))
            XCTAssertNil(BridgeCompatibility.nativeVersion(in: Data("codex-cli \(version)".utf8)))
        }
        for version in ["0.168.99", "0.0172.0", "latest", "0.172.0-beta", "0.172.0\n"] {
            XCTAssertFalse(BridgeCompatibility.eligibleVersion(version))
        }
    }

    func testNewMethodsAreAllowedButMissingOrChangedIdentityFieldsFail() throws {
        let variant: [String: Any] = ["properties": ["method": ["enum": ["turn/started"]],
                                                      "params": ["$ref": "#/definitions/Start"]]]
        func schema(_ type: String, required: [String]) -> [String: Any] {
            ["oneOf": [variant], "definitions": ["Start": ["properties": ["threadId": ["type": type]],
                                                             "required": required]]]
        }
        let expected = ["turn/started": ["threadId"]]
        let valid = schema("string", required: ["threadId"])
        XCTAssertNoThrow(try NativeProtocolCheck.methods(valid, expected))
        XCTAssertNoThrow(try NativeProtocolCheck.methods(valid, [:]))
        XCTAssertThrowsError(try NativeProtocolCheck.methods(valid, ["turn/completed": []]))
        XCTAssertThrowsError(try NativeProtocolCheck.methods(schema("integer", required: ["threadId"]), expected))
        XCTAssertThrowsError(try NativeProtocolCheck.methods(schema("string", required: []), expected))
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

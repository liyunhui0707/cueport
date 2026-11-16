import XCTest
@testable import AttentionCore

final class FocusVerificationTests: XCTestCase {
    let target = TerminalIdentity(sessionID: "w9t8p7:12345678-1234-1234-1234-123456789ABC")
    func testExactCurrentSessionIsConfirmedIndependentlyOfTitle() throws {
        let output = Data("\"12345678-1234-1234-1234-123456789abc\"\n".utf8)
        XCTAssertNoThrow(try SessionLocator.verifyFocus(target, output: output))
    }
    func testExpectedIDInTitleCannotHideWrongCurrentSession() {
        let output = Data("{\"active\":\"00000000-0000-0000-0000-000000000001\",\"title\":\"12345678-1234-1234-1234-123456789ABC\"}".utf8)
        XCTAssertThrowsError(try SessionLocator.verifyFocus(target, output: output))
        XCTAssertThrowsError(try SessionLocator.verifyFocus(target, output: Data("\"00000000-0000-0000-0000-000000000001\"".utf8)))
    }
    func testUnknownDuplicateAndMalformedFocusReportsFailClosed() {
        for text in ["", "Current session: 12345678-1234-1234-1234-123456789ABC", "\"invalid\"", "[\"12345678-1234-1234-1234-123456789ABC\",\"12345678-1234-1234-1234-123456789ABC\"]"] {
            XCTAssertThrowsError(try SessionLocator.verifyFocus(target, output: Data(text.utf8)))
        }
    }
    func testInvalidEncodingAndOversizedFocusReportsAreRejected() {
        XCTAssertThrowsError(try SessionLocator.verifyFocus(target, output: Data([0xff])))
        XCTAssertThrowsError(try SessionLocator.verifyFocus(target, output: Data(repeating: 65, count: 1_048_577)))
    }
}

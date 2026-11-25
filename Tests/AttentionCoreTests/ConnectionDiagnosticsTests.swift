import XCTest
@testable import AttentionCore

final class ConnectionDiagnosticsTests: XCTestCase {
    func testMissingHelperAndUninspectableConfigurationAreDistinct() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("hooks.json")
        XCTAssertTrue(ConnectionDiagnostics.hooks(at: file).contains("No Hooks file"))
        let helper = dir.appendingPathComponent("old installation/aar")
        let bytes = try HookConfiguration.merged(existing: nil, command: HookConfiguration.command(executable: helper.path, dataRoot: nil))
        try bytes.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertTrue(ConnectionDiagnostics.hooks(at: file).contains("Hook helper unavailable"))
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: false)
        XCTAssertTrue(FileManager.default.createFile(atPath: helper.path, contents: Data(), attributes: [.posixPermissions: 0o700]))
        XCTAssertTrue(ConnectionDiagnostics.hooks(at: file).contains("7/7"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertTrue(ConnectionDiagnostics.hooks(at: file).contains("could not be verified"))
    }
    func testBackendVersionDetailsAreBoundedAndDoNotDiscloseRawOutput() {
        let status = ConnectionDiagnostics.backendDescription(Data(#"{"appServerVersion":"0.170.0"}"#.utf8), client: "0.169.0")
        XCTAssertTrue(status.contains("0.170.0")); XCTAssertTrue(status.contains("0.169.0"))
        let bad = ConnectionDiagnostics.backendDescription(Data(#"{"appServerVersion":"personal text"}"#.utf8), client: "0.169.0")
        XCTAssertFalse(bad.contains("personal")); XCTAssertTrue(bad.contains("no verifiable"))
    }
    func testBackendAndClientClosuresHaveDifferentRecoveryGuidance() {
        func guidance(_ reason: String) -> String { ConnectionDiagnostics.TransportEnd(reason: reason, date: Date()).guidance }
        XCTAssertTrue(guidance("proxy-launch-failed").contains("installation"))
        XCTAssertTrue(guidance("upstream-closed").contains("backend proxy closed"))
        XCTAssertTrue(guidance("client-closed").contains("client closed"))
        XCTAssertTrue(guidance("unrecognized private text").contains("unknown reason"))
        XCTAssertFalse(guidance("unrecognized private text").contains("private text"))
    }
}

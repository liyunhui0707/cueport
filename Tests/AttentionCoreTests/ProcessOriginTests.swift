import XCTest
@testable import AttentionCore

final class ProcessOriginTests: XCTestCase {
    let guid = "12345678-1234-1234-1234-123456789ABC"
    func hint(pid: Int32 = 100, start: UInt64 = 123, group: UInt32 = 100,
              foreground: UInt32 = 100, tty: Bool = true, uid: UInt32 = 501) -> ProcessOriginHint {
        ProcessOriginHint(pid: pid, uid: uid, startMicroseconds: start,
            processGroup: group, terminalGroup: foreground, terminalDevice: 42,
            hasControllingTerminal: tty, isCodex: true)
    }
    func resolve(_ a: ProcessOriginHint?, _ b: ProcessOriginHint?, sessions: [TerminalSession]? = nil) throws -> VerifiedTerminalOrigin {
        try ProcessOriginVerifier.match(hint: a, live: b,
            sessions: sessions ?? [TerminalSession(id: guid, windowID: "w", tabID: "t", tty: "/dev/ttys001")],
            devices: ["/dev/ttys001": 42], currentUID: 501)
    }
    func testKernelTTYSelectsExactPaneWithoutEnvironmentHint() throws {
        let origin = try resolve(hint(), hint())
        XCTAssertEqual(origin.terminal.guid, guid)
    }
    func testPIDReuseAndForeignUserFailClosed() {
        XCTAssertThrowsError(try resolve(hint(), hint(start: 124)))
        XCTAssertThrowsError(try resolve(hint(), hint(uid: 502)))
    }
    func testBackgroundOrDetachedAncestorIsNotOrigin() {
        XCTAssertThrowsError(try resolve(hint(tty: false), hint(tty: false)))
        XCTAssertThrowsError(try resolve(hint(group: 99), hint(group: 99)))
        XCTAssertThrowsError(try resolve(hint(foreground: 99), hint(foreground: 99)))
    }
    func testMissingAndAmbiguousTTYFailClosed() {
        XCTAssertThrowsError(try resolve(nil, hint()))
        XCTAssertThrowsError(try resolve(hint(), nil))
        XCTAssertThrowsError(try resolve(hint(), hint(), sessions: []))
        let one = TerminalSession(id: guid, windowID: "w", tabID: "t", tty: "/dev/ttys001")
        XCTAssertThrowsError(try resolve(hint(), hint(), sessions: [one, one]))
    }
    func testDevicePathsCannotBecomeArbitraryFileReads() {
        XCTAssertNil(ProcessOriginProbe.terminalDevice("/etc/passwd"))
        XCTAssertNil(ProcessOriginProbe.terminalDevice("/dev/ttys001/../../etc/passwd"))
    }
    func testBindingCannotFollowReusedTTYToAnotherPane() throws {
        let origin = try resolve(hint(), hint())
        let replacement = TerminalSession(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", windowID: "w", tabID: "t", tty: "/dev/ttys001")
        XCTAssertThrowsError(try ProcessOriginVerifier.revalidate(origin, live: hint(),
            sessions: [replacement], devices: ["/dev/ttys001": 42], currentUID: 501))
    }
    func testOldNotificationProcessReferenceDoesNotFollowPIDReuse() {
        XCTAssertEqual(hint().instanceID, hint().instanceID)
        XCTAssertNotEqual(hint().instanceID, hint(start: 124).instanceID)
    }
    func testMissingOriginOnNewInputInvalidatesOldAssociation() throws {
        var state = RouterState()
        let time = Date()
        try state.apply(AgentEvent(kind: .inputSubmitted, sessionID: "thread", processOriginHint: hint(), timestamp: time))
        try state.apply(AgentEvent(kind: .inputSubmitted, sessionID: "thread", timestamp: time.addingTimeInterval(1)))
        XCTAssertNil(state.sessions["thread"]?.processOriginHint)
    }
    func testConflictingClientCannotSilentlyRebindOneThread() throws {
        var state = RouterState()
        let time = Date()
        try state.apply(AgentEvent(kind: .inputSubmitted, sessionID: "thread", processOriginHint: hint(), timestamp: time))
        try state.apply(AgentEvent(kind: .activity, sessionID: "thread", processOriginHint: hint(start: 124), timestamp: time.addingTimeInterval(1)))
        try state.apply(AgentEvent(kind: .sessionStarted, sessionID: "thread", processOriginHint: hint(start: 124), timestamp: time.addingTimeInterval(2)))
        XCTAssertEqual(state.sessions["thread"]?.processOriginConflict, true)
        XCTAssertEqual(state.sessions["thread"]?.processOriginHint?.startMicroseconds, 124)
    }
}

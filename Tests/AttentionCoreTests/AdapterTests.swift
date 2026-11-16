import XCTest
@testable import AttentionCore

final class AdapterTests: XCTestCase {
    let guid = "12345678-1234-1234-1234-123456789ABC"
    func payload(response: Any = "{\"accepted\":true}", extra: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = ["hook_event_name": "PostToolUse", "session_id": "session", "turn_id": "turn", "tool_name": "request_user_input_async", "tool_use_id": "call-1", "cwd": "/private/SecretParent/project", "tool_input": ["questions": [["title": "SECRET PROMPT", "options": ["SECRET ANSWER"]], ["title": "SECOND SECRET"]]], "tool_response": response, "transcript_path": "/private/secret/transcript"]
        object.merge(extra) { _, new in new }; return try JSONSerialization.data(withJSONObject: object)
    }
    func testQuestionIDsMatchCodexAndAcceptedDoesNotResolve() throws {
        let events = try CodexHookAdapter.events(data: payload(), environment: ["ITERM_SESSION_ID": "w0t2p1:" + guid])
        XCTAssertEqual(events.first?.kind, .questionQueued)
        XCTAssertEqual(events.first?.questionIDs, [#"["request_user_input_async","call-1",0]"#, #"["request_user_input_async","call-1",1]"#])
        XCTAssertEqual(events.first?.terminal?.guid, guid)
        let text = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for secret in ["SECRET", "transcript", "SecretParent", "options"] { XCTAssertFalse(text.contains(secret)) }
        XCTAssertEqual(events.first?.project, "project")
    }
    func testRejectedOrMissingCallCannotCreateQuestion() throws {
        XCTAssertTrue(try CodexHookAdapter.events(data: payload(response: ["accepted": false]), environment: [:]).isEmpty)
        XCTAssertTrue(try CodexHookAdapter.events(data: payload(extra: ["tool_use_id": NSNull()]), environment: [:]).isEmpty)
    }
    func testRepeatedToolEventHasStableID() throws {
        let a = try CodexHookAdapter.events(data: payload(), environment: [:], now: Date(timeIntervalSince1970: 1))
        let b = try CodexHookAdapter.events(data: payload(), environment: [:], now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(a.first?.id, b.first?.id)
    }
    func testRepeatedStopInvocationsInOneTurnAreNotCollapsed() throws {
        let data = try JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop", "session_id": "s", "turn_id": "same-turn"])
        let a = try CodexHookAdapter.events(data: data, environment: [:])
        let b = try CodexHookAdapter.events(data: data, environment: [:])
        XCTAssertNotEqual(a.first?.id, b.first?.id)
    }
    func testTerminalEnvironmentCandidatesRemainSeparateHints() throws {
        let other = "00000000-0000-0000-0000-000000000002"
        let value = try CodexHookAdapter.events(data: payload(), environment: ["ITERM_SESSION_ID": guid, "TERM_SESSION_ID": other])
        XCTAssertEqual(value.first?.terminalHints?.map(\.guid), [guid, other])
    }
    func testOversizeAndMalformedAreRejected() {
        XCTAssertThrowsError(try CodexHookAdapter.events(data: Data(repeating: 0x20, count: 1_048_577), environment: [:]))
        XCTAssertThrowsError(try CodexHookAdapter.events(data: Data("[]".utf8), environment: [:]))
    }
    func testInvalidTerminalAndShellInjectionNeverRoute() throws {
        let events = try CodexHookAdapter.events(data: payload(), environment: ["ITERM_SESSION_ID": "$(touch /tmp/should-not-exist)"])
        XCTAssertNil(events.first?.terminal)
        XCTAssertNil(TerminalIdentity(sessionID: "active").guid)
        XCTAssertNil(TerminalIdentity(sessionID: "x:" + guid).guid)
        XCTAssertNil(TerminalIdentity(sessionID: "x:y:" + guid).guid)
    }
    func testExactSessionAcrossMovedWindowAndTab() throws {
        let target = TerminalSession(id: guid, windowID: "moved-window", tabID: "renamed-tab")
        let match = try SessionLocator.exact(TerminalIdentity(sessionID: "w0t0p0:" + guid), in: [target])
        XCTAssertEqual(match, target)
        XCTAssertThrowsError(try SessionLocator.exact(TerminalIdentity(sessionID: guid), in: []))
        XCTAssertThrowsError(try SessionLocator.exact(TerminalIdentity(sessionID: guid), in: [target, target]))
        XCTAssertThrowsError(try SessionLocator.exact(nil, in: [target]))
    }
}

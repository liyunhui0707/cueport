import XCTest
@testable import AttentionCore

final class ReplyMetadataTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let q0 = #"["request_user_input_async","call-test",0]"#
    let q1 = #"["request_user_input_async","call-test",1]"#
    func envelope(_ id: String, answer: String = "PRIVATE_TEST_ANSWER") throws -> String {
        let body = try JSONSerialization.data(withJSONObject: [["questionItemId": id,
            "question": "PRIVATE_TEST_TITLE", "answer": answer]], options: .withoutEscapingSlashes)
        return "<send_user_message_question_reply>\n" + String(decoding: body, as: UTF8.self) + "\n</send_user_message_question_reply>"
    }
    func testOfficialEditorEnvelopeExtractsOnlyCanonicalID() throws {
        let prompt = try envelope(#"[ "request_user_input_async", "call-test", 0 ]"#)
        let data = try JSONSerialization.data(withJSONObject: ["hook_event_name": "UserPromptSubmit", "session_id": "s", "prompt": prompt])
        let events = try CodexHookAdapter.events(data: data, environment: [:], now: now)
        XCTAssertEqual(events.first?.kind, .inputSubmitted)
        XCTAssertEqual(events.first?.questionIDs, [q0])
        let stored = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(stored.contains("PRIVATE_TEST_ANSWER"))
        XCTAssertFalse(stored.contains("PRIVATE_TEST_TITLE"))
        XCTAssertFalse(stored.contains("send_user_message_question_reply"))
    }
    func testOrdinaryQuotedMalformedAndForeignRepliesDoNotInferAnswers() throws {
        XCTAssertEqual(CodexReplyMetadata.submittedIDs("排序选按名称。"), [])
        XCTAssertEqual(CodexReplyMetadata.submittedIDs("Explain this example: " + (try envelope(q0))), [])
        XCTAssertEqual(CodexReplyMetadata.submittedIDs("```\n" + (try envelope(q0)) + "\n```"), [])
        for invalid in [#"["other_tool","call-test",0]"#, #"["request_user_input_async","call-test",true]"#,
                        #"["request_user_input_async","call-test",-1]"#, #"["request_user_input_async","call-test",64]"#,
                        #"["request_user_input_async","call-test",0,"extra"]"#] {
            XCTAssertEqual(CodexReplyMetadata.submittedIDs(try envelope(invalid)), [])
        }
        XCTAssertEqual(CodexReplyMetadata.submittedIDs(try envelope(q0, answer: " ")), [])
    }
    func testFocusedSubmissionPreservesOtherQuestionWithoutClaimingResolution() throws {
        var state = RouterState()
        try state.apply(AgentEvent(kind: .questionQueued, sessionID: "s", questionIDs: [q0, q1], timestamp: now))
        try state.apply(AgentEvent(kind: .inputSubmitted, sessionID: "s", questionIDs: [q0], timestamp: now.addingTimeInterval(1)))
        let session = try XCTUnwrap(state.sessions["s"])
        XCTAssertEqual(session.requests[q0]?.evidence, .unknown)
        XCTAssertEqual(session.requests[q0]?.answerSubmittedAt, now.addingTimeInterval(1))
        XCTAssertEqual(session.requests[q1]?.evidence, .observed)
        XCTAssertEqual(session.queuedQuestions.map(\.id), [q1])
        XCTAssertEqual(session.submittedQuestions.map(\.id), [q0])
        XCTAssertEqual(session.outstanding.count, 2)
    }
    func testAnswerBeforeCreationAndReplayCannotReopenQuestion() throws {
        var state = RouterState()
        try state.apply(AgentEvent(kind: .inputSubmitted, sessionID: "s", questionIDs: [q0], timestamp: now.addingTimeInterval(2)))
        for seconds: Double in [1, 3] {
            try state.apply(AgentEvent(kind: .questionQueued, sessionID: "s", questionIDs: [q0], timestamp: now.addingTimeInterval(seconds)))
        }
        XCTAssertEqual(state.sessions["s"]?.requests[q0]?.evidence, .unknown)
        XCTAssertEqual(state.sessions["s"]?.submittedQuestions.count, 1)
        XCTAssertTrue(state.sessions["s"]!.queuedQuestions.isEmpty)
    }
    func testOrdinaryChatStaysUnknownAndSubmissionSurvivesRestart() throws {
        var state = RouterState()
        try state.apply(AgentEvent(kind: .questionQueued, sessionID: "s", questionIDs: [q0, q1], timestamp: now))
        try state.apply(AgentEvent(kind: .inputSubmitted, sessionID: "s", questionIDs: [q0], timestamp: now.addingTimeInterval(1)))
        try state.apply(AgentEvent(kind: .inputSubmitted, sessionID: "s", timestamp: now.addingTimeInterval(2)))
        state = try JSONDecoder().decode(RouterState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(state.sessions["s"]?.requests[q0]?.evidence, .unknown)
        XCTAssertEqual(state.sessions["s"]?.requests[q1]?.evidence, .unknown)
        XCTAssertNotNil(state.sessions["s"]?.requests[q0]?.answerSubmittedAt)
        XCTAssertNil(state.sessions["s"]?.requests[q1]?.answerSubmittedAt)
    }
    func testSubmittedQuestionCannotGenerateNewCreationBanner() throws {
        var session = AgentSession(id: "s", project: "sample")
        session.requests[q0] = AttentionRequest(id: q0, kind: .question, evidence: .observed, updatedAt: now, answerSubmittedAt: now)
        XCTAssertNil(NotificationPolicy.plan(event: AgentEvent(kind: .questionQueued, sessionID: "s", questionIDs: [q0], timestamp: now), session: session, sourceInstance: "verified-test", submitted: [:], now: now))
    }
    func testFreshQuestionRanksAheadOfUnconfirmedHistory() {
        var old = AgentSession(id: "old", project: "sample")
        old.requests[q0] = AttentionRequest(id: q0, kind: .question, evidence: .unknown, updatedAt: now)
        var fresh = AgentSession(id: "fresh", project: "sample")
        fresh.requests[q1] = AttentionRequest(id: q1, kind: .question, evidence: .observed, updatedAt: now)
        XCTAssertLessThan(fresh.priority, old.priority)
        XCTAssertTrue(old.needsAttention)
    }
}

import XCTest
@testable import AttentionCore

final class CheckedReminderTests: XCTestCase {
    private func sample() -> AgentSession {
        var session = AgentSession(id: "thread", project: "Example")
        session.execution = .idle
        for i in 0..<17 {
            let key = "question-\(i)"
            session.requests[key] = .init(id: key, kind: .question, evidence: .unknown, updatedAt: .distantPast)
        }
        session.protocolCoverageNotice = .init(id: "notice", issue: .unsupportedInput, observedAt: .distantPast, reviewed: true)
        return session
    }

    func testVisitAndManualCheckAreSeparateAndManualChoiceSurvivesReload() throws {
        var state = RouterState()
        let original = sample()
        state.sessions[original.id] = original
        state.markReviewed(original.id)
        XCTAssertEqual(state.sessions[original.id]?.uncertainQuestions.count, 17)
        state.clearCheckedReminders(from: CheckedReminderBatch(original))
        let restored = try JSONDecoder().decode(RouterState.self, from: JSONEncoder().encode(state))
        let current = try XCTUnwrap(restored.sessions[original.id])
        XCTAssertFalse(current.needsAttention)
        XCTAssertEqual(current.uncertainQuestions.count, 0)
        XCTAssertNil(current.visibleCoverageNotice)
        XCTAssertEqual(current.outstanding.count, 17)
        XCTAssertTrue(current.outstanding.allSatisfy { $0.evidence == .unknown && $0.manuallyCheckedAt != nil })
        XCTAssertEqual(current.protocolCoverageNotice?.issue, .unsupportedInput)
    }

    func testManualCheckLeavesConfirmedApprovalAndExecutionVisible() throws {
        var state = RouterState()
        let original = sample()
        state.sessions[original.id] = original
        try state.apply(.init(kind: .humanApprovalPending, sessionID: original.id,
                              requestID: "approval", source: "codex-protocol"))
        state.clearCheckedReminders(from: CheckedReminderBatch(original))
        let current = try XCTUnwrap(state.sessions[original.id])
        XCTAssertEqual(current.execution, .idle)
        XCTAssertEqual(current.visibleOutstanding.map(\.id), ["approval"])
        XCTAssertEqual(current.requests["approval"]?.evidence, .confirmed)
        XCTAssertEqual(SessionOverview(state: state, bridgeMode: false).attentionCount, 1)
    }

    func testNewRequestsApprovalsAndOtherSessionsSurviveChecking() throws {
        var state = RouterState()
        let checked = sample()
        state.sessions["thread"] = checked
        try state.apply(.init(kind: .questionQueued, sessionID: "thread", questionIDs: ["question-0","new"]))
        try state.apply(.init(kind: .approvalRequested, sessionID: "thread", requestID: "approval"))
        try state.apply(.init(kind: .questionQueued, sessionID: "other", questionIDs: ["other-question"]))
        try state.apply(.init(kind: .observationGap, sessionID: "thread"))
        state.sessions["thread"]?.protocolCoverageNotice = .init(id: "new-notice", issue: .requestLimit, observedAt: Date())
        state.markReviewed("thread", asSeen: checked)
        state.clearCheckedReminders(from: CheckedReminderBatch(checked))
        let current = try XCTUnwrap(state.sessions["thread"])
        XCTAssertEqual(Set(current.uncertainQuestions.map(\.id)), ["question-0","new"])
        XCTAssertEqual(current.visibleCoverageNotice?.reviewed, false)
        XCTAssertEqual(current.visibleOutstanding.filter { $0.kind == .approval }.count, 1)
        XCTAssertTrue(current.needsAttention)
        XCTAssertEqual(state.sessions["other"]?.queuedQuestions.count, 1)
    }
}

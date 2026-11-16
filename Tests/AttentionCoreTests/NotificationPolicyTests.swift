import XCTest
@testable import AttentionCore

final class NotificationPolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let instance = String(repeating: "a", count: 64)
    func question(_ ids: [String] = ["q1", "q2"]) -> AgentEvent {
        AgentEvent(kind: .questionQueued, sessionID: "s", turnID: "turn", questionIDs: ids, timestamp: now)
    }
    func testRunningQuestionsNotifyOnceAndPartialReplayOnlyCountsNewQuestions() throws {
        var state = RouterState()
        try state.apply(AgentEvent(kind: .inputSubmitted, sessionID: "s", timestamp: now))
        let event = question(); try state.apply(event)
        let plan = try XCTUnwrap(NotificationPolicy.plan(event: event, session: state.sessions["s"]!, sourceInstance: instance, submitted: [:], now: now))
        XCTAssertEqual(plan.questionCount, 2)
        state.notificationReceipts = NotificationPolicy.recordSubmission(plan, in: [:], now: now)
        // Persist/reload, then replay a new envelope with the same question IDs.
        state = try JSONDecoder().decode(RouterState.self, from: JSONEncoder().encode(state))
        XCTAssertNil(NotificationPolicy.plan(event: question(), session: state.sessions["s"]!, sourceInstance: instance, submitted: state.notificationReceipts!, now: now))
        let next = question(["q2", "q3"]); try state.apply(next)
        XCTAssertEqual(NotificationPolicy.plan(event: next, session: state.sessions["s"]!, sourceInstance: instance, submitted: state.notificationReceipts!, now: now)?.questionCount, 1)
        XCTAssertEqual(state.sessions["s"]?.execution, .running)
    }
    func testUnverifiedSourcesAndEarlyApprovalsStayQuiet() throws {
        var state = RouterState(); let event = question(); try state.apply(event)
        XCTAssertNil(NotificationPolicy.plan(event: event, session: state.sessions["s"]!, sourceInstance: nil, submitted: [:], now: now))
        let early = AgentEvent(kind: .approvalRequested, sessionID: "s", requestID: "r", timestamp: now)
        try state.apply(early)
        XCTAssertNil(NotificationPolicy.plan(event: early, session: state.sessions["s"]!, sourceInstance: instance, submitted: [:], now: now))
        XCTAssertEqual(state.sessions["s"]?.requests["r"]?.evidence, .observed)
    }
    func testHumanApprovalRequiresConfirmedCorrelatedProtocolEvidence() throws {
        var state = RouterState()
        var event = AgentEvent(kind: .humanApprovalPending, sessionID: "s", requestID: "r", timestamp: now, source: "codex-protocol")
        try state.apply(event)
        XCTAssertNotNil(NotificationPolicy.plan(event: event, session: state.sessions["s"]!, sourceInstance: instance, submitted: [:], now: now))
        event.source = "codex-hook"
        XCTAssertNil(NotificationPolicy.plan(event: event, session: state.sessions["s"]!, sourceInstance: instance, submitted: [:], now: now))
    }
    func testDeliveredProtocolApprovalCanNotifyWithoutClaimingHumanWaiting() throws {
        let process = ProcessOriginHint(pid: 500, uid: 501, startMicroseconds: 10, processGroup: 500,
            terminalGroup: 500, terminalDevice: 20, hasControllingTerminal: true, isCodex: true)
        let binding = ProtocolOriginBinding(origin: .init(terminal: .init(sessionID: "12345678-1234-1234-1234-123456789ABC"), process: process))
        var state = RouterState()
        let event = AgentEvent(kind: .approvalRequested, sessionID: "s", requestID: "r", protocolBinding: binding, timestamp: now, source: "codex-protocol")
        try state.apply(event)
        let plan = try XCTUnwrap(NotificationPolicy.plan(event: event, session: state.sessions["s"]!, sourceInstance: instance, submitted: [:], now: now))
        XCTAssertEqual(plan.kind, .approvalRequested)
        XCTAssertEqual(state.sessions["s"]?.requests["r"]?.evidence, .observed)
        try state.apply(.init(kind: .requestResolved, sessionID: "s", requestID: "r", protocolBinding: binding, timestamp: now.addingTimeInterval(0.5), source: "codex-protocol"))
        XCTAssertNil(NotificationPolicy.plan(event: event, session: state.sessions["s"]!, sourceInstance: instance, submitted: [:], now: now.addingTimeInterval(1)))
    }
    func testRepeatedStopsInOneTurnDoNotRepeatBanner() throws {
        var state = RouterState()
        var stop = AgentEvent(kind: .turnStopped, sessionID: "s", turnID: "t1", timestamp: now)
        try state.apply(stop)
        let plan = try XCTUnwrap(NotificationPolicy.plan(event: stop, session: state.sessions["s"]!, sourceInstance: instance, submitted: [:], now: now))
        let receipts = NotificationPolicy.recordSubmission(plan, in: [:], now: now)
        stop.id = "other-hook-invocation"; stop.timestamp = now.addingTimeInterval(1); try state.apply(stop)
        XCTAssertNil(NotificationPolicy.plan(event: stop, session: state.sessions["s"]!, sourceInstance: instance, submitted: receipts, now: stop.timestamp))
        stop.id = "next-turn-stop"; stop.turnID = "t2"; try state.apply(stop)
        XCTAssertNotNil(NotificationPolicy.plan(event: stop, session: state.sessions["s"]!, sourceInstance: instance, submitted: receipts, now: stop.timestamp))
    }
    func testExpiredOrUncertainQuestionsDoNotCreateFreshBanners() throws {
        var state = RouterState(); let event = question(); try state.apply(event)
        XCTAssertNil(NotificationPolicy.plan(event: event, session: state.sessions["s"]!, sourceInstance: instance, submitted: [:], now: now.addingTimeInterval(121)))
        try state.apply(AgentEvent(kind: .turnStopped, sessionID: "s", timestamp: now))
        XCTAssertNil(NotificationPolicy.plan(event: event, session: state.sessions["s"]!, sourceInstance: instance, submitted: [:], now: now))
        XCTAssertEqual(state.sessions["s"]?.outstanding.count, 2)
    }
    func testRevealURLCannotTurnIdentityIntoAnotherHandler() throws {
        let identity = TerminalIdentity(sessionID: "w1t2p0:12345678-1234-1234-1234-123456789ABC")
        let parts = try XCTUnwrap(URLComponents(url: SessionLocator.revealURL(identity), resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "iterm2"); XCTAssertNil(parts.host); XCTAssertEqual(parts.path, "reveal")
        XCTAssertEqual(parts.queryItems, [URLQueryItem(name: "sessionid", value: identity.sessionID)])
        XCTAssertThrowsError(try SessionLocator.revealURL(TerminalIdentity(sessionID: "iterm2:/command?c=anything")))
        XCTAssertThrowsError(try SessionLocator.revealURL(TerminalIdentity(sessionID: identity.sessionID + "&c=anything")))
    }
}

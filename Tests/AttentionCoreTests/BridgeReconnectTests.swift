import XCTest
@testable import AttentionCore

final class BridgeReconnectTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000)

    func testRuntimeCloseGetsBoundedRecoveryRatherThanOneShotShutdown() {
        var policy = BridgeReconnectPolicy()
        let retry = policy.recovery(after: 300, now: now)
        XCTAssertEqual(retry?.delay, 0.25)
        XCTAssertEqual(retry?.deadline, now.addingTimeInterval(120))
        XCTAssertEqual(policy.attempts, 1)
    }

    func testRapidFailuresBackOffAndStopAtAttemptOrTimeBudget() {
        var policy = BridgeReconnectPolicy()
        var delays: [TimeInterval] = []
        for i in 0..<8 {
            let retry = policy.recovery(after: 0, now: now.addingTimeInterval(Double(i)))
            XCTAssertNotNil(retry)
            if let retry { delays.append(retry.delay) }
        }
        XCTAssertEqual(delays, [0.25, 0.5, 1, 2, 4, 8, 8, 8])
        XCTAssertNil(policy.recovery(after: 0, now: now.addingTimeInterval(9)))
        var timed = BridgeReconnectPolicy()
        XCTAssertNotNil(timed.recovery(after: 0, now: now))
        XCTAssertNil(timed.recovery(after: 0, now: now.addingTimeInterval(120)))
    }

    func testStableConnectionRenewsIncidentBudgetWithoutAnUnboundedRetryLoop() {
        var policy = BridgeReconnectPolicy()
        for i in 0..<8 { _ = policy.recovery(after: 0, now: now.addingTimeInterval(Double(i))) }
        let later = now.addingTimeInterval(500)
        XCTAssertEqual(policy.recovery(after: 60, now: later)?.delay, 0.25)
        XCTAssertEqual(policy.attempts, 1)
        XCTAssertEqual(policy.deadline, later.addingTimeInterval(120))
    }

    func testInvalidTimingFailsClosed() {
        var policy = BridgeReconnectPolicy()
        XCTAssertNil(policy.recovery(after: -.infinity, now: now))
        XCTAssertNil(policy.recovery(after: .nan, now: now))
        XCTAssertNil(policy.recovery(after: -1, now: now))
    }

    func testRecoveringTransportStaysVisibleButCannotRouteOrResolveAQuestion() throws {
        let process = ProcessOriginHint(pid: 500, uid: 501, startMicroseconds: 10,
            processGroup: 500, terminalGroup: 500, terminalDevice: 20,
            hasControllingTerminal: true, isCodex: true, capturedAt: now)
        let binding = ProtocolOriginBinding(id: "original", origin: .init(
            terminal: .init(sessionID: "12345678-1234-1234-1234-123456789ABC"), process: process))
        var state = RouterState()
        try state.apply(.init(kind: .sessionStarted, sessionID: "thread", protocolBinding: binding,
                              timestamp: now, source: "codex-protocol"))
        try state.apply(.init(kind: .questionQueued, sessionID: "thread", questionIDs: ["question"],
                              protocolBinding: binding, timestamp: now, source: "codex-protocol"))
        var lost = AgentEvent(kind: .sourceLost, sessionID: "thread", protocolBinding: binding,
                              timestamp: now.addingTimeInterval(1), source: "codex-protocol")
        lost.transportRecoveryDeadline = now.addingTimeInterval(121)
        try state.apply(lost)
        let session = try XCTUnwrap(state.sessions["thread"])
        XCTAssertEqual(session.execution, .unknown)
        XCTAssertEqual(session.requests["question"]?.evidence, .unknown)
        XCTAssertNil(session.verifiedProtocolBinding)
        XCTAssertEqual(BridgeWorkerBuildStatus(session: session, installedHelper: nil, now: now).status, .recovering)
        XCTAssertEqual(BridgeWorkerBuildStatus(session: session, installedHelper: nil, now: now.addingTimeInterval(122)).status, .recoveryFailed)
        XCTAssertThrowsError(try ProtocolRoute.authorize(session, reference: binding.reference))
        let filter = OpenThreadFilter(state: state, processes: [500: .present(process)], currentUID: 501)
        XCTAssertTrue(filter.visibleThreadIDs.contains("thread"))
        let closed = OpenThreadFilter(state: state, processes: [500: .absent], currentUID: 501)
        XCTAssertFalse(closed.visibleThreadIDs.contains("thread"))

        let replacement = ProtocolOriginBinding(id: "replacement", origin: binding.origin)
        try state.apply(.init(kind: .sessionStarted, sessionID: "thread", protocolBinding: replacement,
                              executionObservation: .running, timestamp: now.addingTimeInterval(2), source: "codex-protocol"))
        let restored = try XCTUnwrap(state.sessions["thread"])
        XCTAssertEqual(restored.verifiedProtocolBinding, replacement)
        XCTAssertNil(restored.protocolBindings?[binding.id]?.recoveryDeadline)
        XCTAssertEqual(restored.requests["question"]?.evidence, .unknown)
        XCTAssertThrowsError(try ProtocolRoute.authorize(restored, reference: binding.reference))
    }

    func testRecoveryMetadataCannotBeForgedByHooksOrExtendBeyondBoundedWindow() throws {
        var value = AgentEvent(kind: .sourceLost, sessionID: "thread", timestamp: now)
        value.transportRecoveryDeadline = now.addingTimeInterval(120)
        XCTAssertThrowsError(try value.validate())
    }
}

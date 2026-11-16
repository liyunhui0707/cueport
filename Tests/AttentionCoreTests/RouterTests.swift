import XCTest
@testable import AttentionCore

final class RouterTests: XCTestCase {
    let time = Date(timeIntervalSince1970: 1_800_000_000)
    func event(_ kind: EventKind, offset: TimeInterval = 0, request: String? = nil, questions: [String] = [], source: String = "codex-hook", session: String = "agent-a") -> AgentEvent {
        AgentEvent(kind: kind, sessionID: session, turnID: "turn-a", requestID: request, questionIDs: questions, project: "router", timestamp: time.addingTimeInterval(offset), source: source)
    }
    func testRunningAndMultipleQuestionsCoexist() throws {
        var state = RouterState()
        try state.apply(event(.turnStarted))
        try state.apply(event(.questionQueued, offset: 1, questions: ["q1", "q2"]))
        try state.apply(event(.activity, offset: 2))
        XCTAssertEqual(state.sessions["agent-a"]?.execution, .running)
        XCTAssertEqual(state.sessions["agent-a"]?.outstanding.count, 2)
        XCTAssertTrue(state.sessions["agent-a"]!.needsAttention)
    }
    func testStopAndReviewDoNotResolveQuestions() throws {
        var state = RouterState()
        try state.apply(event(.questionQueued, questions: ["q1"]))
        try state.apply(event(.turnStopped, offset: 1))
        state.markReviewed("agent-a")
        XCTAssertEqual(state.sessions["agent-a"]?.requests["q1"]?.evidence, .unknown)
        XCTAssertTrue(state.sessions["agent-a"]!.needsAttention)
        XCTAssertTrue(state.sessions["agent-a"]!.completionReviewed)
    }
    func testOrdinaryInputDoesNotInventAnswers() throws {
        var state = RouterState()
        try state.apply(event(.questionQueued, questions: ["q1", "q2"]))
        try state.apply(event(.inputSubmitted, offset: 1))
        XCTAssertEqual(state.sessions["agent-a"]?.outstanding.map(\.evidence), [.unknown, .unknown])
    }
    func testExactResolutionAndTombstoneBeforeCreation() throws {
        var state = RouterState()
        try state.apply(event(.requestResolved, offset: 2, questions: ["q1"], source: "codex-protocol"))
        try state.apply(event(.questionQueued, questions: ["q1", "q2"]))
        XCTAssertEqual(state.sessions["agent-a"]?.outstanding.map(\.id), ["q2"])
    }
    func testHookCannotClaimHumanApprovalOrResolution() throws {
        var state = RouterState()
        XCTAssertThrowsError(try state.apply(event(.humanApprovalPending, request: "r1")))
        XCTAssertThrowsError(try state.apply(event(.requestResolved, questions: ["q1"])))
        XCTAssertTrue(state.sessions.isEmpty)
    }
    func testEarlyApprovalIsObservedOnly() throws {
        var state = RouterState()
        try state.apply(event(.approvalRequested, request: "r1"))
        try state.apply(event(.activity, offset: 1))
        XCTAssertEqual(state.sessions["agent-a"]?.requests["r1"]?.evidence, .observed)
    }
    func testIdempotenceAndOlderExecutionDoesNotRewind() throws {
        var state = RouterState()
        let old = event(.activity)
        try state.apply(event(.turnStopped, offset: 2))
        XCTAssertTrue(try state.apply(old)); XCTAssertFalse(try state.apply(old))
        XCTAssertEqual(state.sessions["agent-a"]?.execution, .idle)
    }
    func testLateBackgroundToolResultDoesNotRestartStoppedTurn() throws {
        var state = RouterState()
        try state.apply(event(.inputSubmitted))
        try state.apply(event(.turnStopped, offset: 1))
        try state.apply(event(.activity, offset: 2))
        XCTAssertEqual(state.sessions["agent-a"]?.execution, .idle)
        XCTAssertEqual(state.recentEvents?.map(\.kind), [.inputSubmitted, .turnStopped, .activity])
    }
    func testIndependentSessionAndRequestNamespaces() throws {
        var state = RouterState()
        try state.apply(event(.questionQueued, questions: ["same"], session: "a"))
        try state.apply(event(.questionQueued, questions: ["same"], session: "b"))
        try state.apply(event(.requestCancelled, offset: 1, questions: ["same"], source: "codex-protocol", session: "a"))
        XCTAssertEqual(state.sessions["a"]?.outstanding.count, 0)
        XCTAssertEqual(state.sessions["b"]?.outstanding.count, 1)
    }
    func testStaleIsUnknownRatherThanExitedOrResolved() throws {
        var state = RouterState()
        try state.apply(event(.turnStarted))
        try state.apply(event(.questionQueued, questions: ["q"]))
        state.age(now: time.addingTimeInterval(601))
        XCTAssertEqual(state.sessions["agent-a"]?.execution, .unknown)
        XCTAssertEqual(state.sessions["agent-a"]?.requests["q"]?.evidence, .unknown)
    }
    func testIdentityChangeRequiresSessionStart() throws {
        var state = RouterState()
        let a = TerminalIdentity(sessionID: "00000000-0000-0000-0000-000000000001")
        let b = TerminalIdentity(sessionID: "00000000-0000-0000-0000-000000000002")
        var first = event(.sessionStarted); first.terminal = a; try state.apply(first)
        var changed = event(.activity, offset: 1); changed.terminal = b; try state.apply(changed)
        XCTAssertEqual(state.sessions["agent-a"]?.terminal, a)
        XCTAssertNotNil(state.sessions["agent-a"]?.routeError)
        var resumed = event(.sessionStarted, offset: 2); resumed.terminal = b; try state.apply(resumed)
        XCTAssertEqual(state.sessions["agent-a"]?.terminal, b)
        XCTAssertNil(state.sessions["agent-a"]?.routeError)
    }
    func testSourceLossPreservesAttention() throws {
        var state = RouterState()
        try state.apply(event(.questionQueued, questions: ["q"]))
        try state.apply(event(.sourceLost, offset: 1))
        XCTAssertTrue(state.sessions["agent-a"]!.needsAttention)
        XCTAssertEqual(state.sessions["agent-a"]?.execution, .unknown)
    }
    func testThousandQuestionsAcrossFiftySessionsWithReversedDelivery() throws {
        var state = RouterState()
        var events: [AgentEvent] = []
        for index in 0..<1000 {
            let session = "s-\(index % 50)"
            let question = "q-\(index)"
            events.append(event(.questionQueued, offset: Double(index * 2), questions: [question], session: session))
            if index.isMultiple(of: 2) {
                events.append(event(.requestResolved, offset: Double(index * 2 + 1), questions: [question], source: "codex-protocol", session: session))
            }
        }
        for value in events.reversed() { try state.apply(value) }
        for value in events { XCTAssertFalse(try state.apply(value)) }
        XCTAssertEqual(state.sessions.count, 50)
        XCTAssertEqual(state.sessions.values.reduce(0) { $0 + $1.outstanding.count }, 500)
        XCTAssertEqual(state.processed.count, 1500)
        for session in state.sessions.values {
            for question in session.outstanding {
                let index = try XCTUnwrap(Int(question.id.dropFirst(2)))
                XCTAssertEqual(session.id, "s-\(index % 50)")
                XCTAssertFalse(index.isMultiple(of: 2))
            }
        }
    }
}

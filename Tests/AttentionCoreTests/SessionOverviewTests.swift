import XCTest
@testable import AttentionCore

final class SessionOverviewTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func binding(_ id: String = "one", pid: Int32 = 500, start: UInt64 = 10,
                 guid: String = "12345678-1234-1234-1234-123456789ABC") -> ProtocolOriginBinding {
        .init(id: id, origin: .init(terminal: .init(sessionID: guid), process: .init(pid: pid, uid: 501,
            startMicroseconds: start, processGroup: UInt32(pid), terminalGroup: UInt32(pid),
            terminalDevice: 20, hasControllingTerminal: true, isCodex: true, capturedAt: now)))
    }
    func session(_ id: String, project: String = "Same project", binding: ProtocolOriginBinding? = nil) -> AgentSession {
        var s = AgentSession(id: id, project: project); s.lastSeen = now; s.execution = .idle
        if let binding { s.protocolBindings = [binding.id: .init(binding: binding, connected: true, updatedAt: now)] }
        return s
    }
    func testSameExactSourceGroupsDifferentThreadsWithoutMergingTheirEvidence() {
        var state = RouterState()
        var a = session("a", binding: binding()); a.requests["q"] = .init(id: "q", kind: .question, evidence: .unknown, updatedAt: now)
        state.sessions = ["a": a, "b": session("b", project: "Other project", binding: binding("two"))]
        let overview = SessionOverview(state: state, bridgeMode: true)
        XCTAssertEqual(overview.groups.count, 1); XCTAssertEqual(overview.registeredSourceCount, 1)
        XCTAssertEqual(Set(overview.groups[0].sessions.map(\.id)), ["a", "b"])
        XCTAssertEqual(overview.attentionCount, 1); XCTAssertEqual(state.sessions["a"]?.requests.count, 1)
    }
    func testProjectNameAndReusedPIDNeverMergeDistinctSources() {
        var state = RouterState()
        state.sessions = ["a": session("a", binding: binding()),
                          "b": session("b", binding: binding("two", start: 11)),
                          "c": session("c", binding: binding("three", guid: "22345678-1234-1234-1234-123456789ABC"))]
        let overview = SessionOverview(state: state, bridgeMode: true)
        XCTAssertEqual(overview.groups.count, 3); XCTAssertEqual(overview.registeredSourceCount, 3)
    }
    func testDisconnectedRecordsGoToHistoryWithoutErasingAttention() throws {
        var state = RouterState(); let b = binding()
        var s = session("old", binding: b)
        s.protocolBindings?[b.id]?.connected = false; s.completionAt = now
        state.sessions = ["old": s, "quiet": session("quiet")]
        let overview = SessionOverview(state: state, bridgeMode: true)
        XCTAssertTrue(overview.groups.isEmpty); XCTAssertEqual(overview.history.count, 2)
        XCTAssertEqual(overview.historyAttentionCount, 1); XCTAssertEqual(overview.attentionCount, 1)
        XCTAssertEqual(try JSONDecoder().decode(RouterState.self, from: JSONEncoder().encode(state)), state)
    }
    func testArchiveRoundTripAndRestorePreserveRequestsBindingsDedupeAndOutbox() throws {
        var state = RouterState(); var s = session("a", binding: binding())
        s.requests["q"] = .init(id: "q", kind: .question, evidence: .unknown, updatedAt: now)
        s.protocolGapAt = now; s.completionAt = now
        state.sessions["a"] = s; state.processed = ["old-event"]
        state.notificationReceipts = ["accepted-receipt": now]
        state.pendingNotifications = ["queued-stop": .init(event: .init(id: "queued-stop", kind: .turnStopped,
            sessionID: "a", protocolBinding: binding(), timestamp: now, source: "codex-protocol"), nextAttemptAt: now)]
        let original = state
        XCTAssertTrue(state.setArchived("a", archived: true, now: now))
        let overview = SessionOverview(state: state, bridgeMode: true)
        XCTAssertTrue(overview.groups.isEmpty); XCTAssertEqual(overview.archived.map(\.id), ["a"])
        XCTAssertEqual(overview.attentionCount, 0)
        XCTAssertEqual(state.sessions["a"]?.requests, original.sessions["a"]?.requests)
        XCTAssertEqual(state.sessions["a"]?.protocolBindings, original.sessions["a"]?.protocolBindings)
        XCTAssertEqual(state.processed, original.processed)
        XCTAssertEqual(state.pendingNotifications, original.pendingNotifications)
        XCTAssertEqual(state.notificationReceipts, original.notificationReceipts)
        state = try JSONDecoder().decode(RouterState.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(state.setArchived("a", archived: false, now: now))
        XCTAssertEqual(state, original)
    }
    func testRunningAndObservedOrConfirmedRequestsCannotBeArchived() {
        for execution in [Execution.running, .idle] {
            for evidence in [Evidence.observed, .confirmed] {
                var state = RouterState(); var s = session("s"); s.execution = execution
                s.requests["approval"] = .init(id: "approval", kind: .approval, evidence: evidence, updatedAt: now)
                state.sessions["s"] = s
                XCTAssertFalse(state.setArchived("s", archived: true, now: now)); XCTAssertNil(state.sessions["s"]?.archivedAt)
            }
        }
        var state = RouterState(); var s = session("s"); s.execution = .running; state.sessions["s"] = s
        XCTAssertFalse(state.setArchived("s", archived: true, now: now))
    }
    func testNewAttentionRestoresButReplayOldEventsAndRoutineActivityDoNot() throws {
        var state = RouterState(); state.sessions["s"] = session("s", binding: binding())
        XCTAssertTrue(state.setArchived("s", archived: true, now: now))
        for (id, kind, date) in [("old", EventKind.turnStopped, now.addingTimeInterval(-1)),
                                 ("activity", .activity, now.addingTimeInterval(1))] {
            try state.apply(.init(id: id, kind: kind, sessionID: "s", protocolBinding: binding(), timestamp: date, source: "codex-protocol"))
            XCTAssertNotNil(state.sessions["s"]?.archivedAt)
        }
        let fresh = AgentEvent(id: "new", kind: .questionQueued, sessionID: "s", questionIDs: ["new-question"],
            protocolBinding: binding(), timestamp: now.addingTimeInterval(2), source: "codex-protocol")
        try state.apply(fresh); XCTAssertNil(state.sessions["s"]?.archivedAt)
        try state.apply(.init(id: "clear", kind: .requestResolved, sessionID: "s", questionIDs: ["new-question"],
            protocolBinding: binding(), timestamp: now.addingTimeInterval(3), source: "codex-protocol"))
        XCTAssertTrue(state.setArchived("s", archived: true, now: now.addingTimeInterval(4)))
        try state.apply(fresh); XCTAssertNotNil(state.sessions["s"]?.archivedAt)
    }
    func testAmbiguousSourceIsSeparateAndDoesNotPickTheNewestThreadAsCurrent() {
        var state = RouterState(); var s = session("ambiguous", binding: binding())
        let other = binding("two", pid: 600)
        s.protocolBindings?[other.id] = .init(binding: other, connected: true, updatedAt: now)
        state.sessions = [s.id: s, "unique": session("unique", binding: binding())]
        let overview = SessionOverview(state: state, bridgeMode: true)
        XCTAssertEqual(overview.groups.count, 2); XCTAssertEqual(overview.registeredSourceCount, 2)
        XCTAssertNil(overview.groups.first { $0.sessions.contains { $0.id == "ambiguous" } }?.sourceKey)
    }
    func testOldSnapshotWithoutArchiveFieldAndHookOnlySessionsStillAppear() throws {
        var state = RouterState(); state.sessions["hook"] = session("hook")
        let data = try JSONEncoder().encode(state)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("archivedAt"))
        let restored = try JSONDecoder().decode(RouterState.self, from: data)
        XCTAssertNil(restored.sessions["hook"]?.archivedAt)
        XCTAssertEqual(SessionOverview(state: restored, bridgeMode: false).groups.count, 1)
        XCTAssertTrue(SessionOverview(state: restored, bridgeMode: false).history.isEmpty)
    }
}

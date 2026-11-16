import XCTest
@testable import AttentionCore

final class OpenThreadFilterTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func binding(_ id: String = "one", pid: Int32 = 500) -> ProtocolOriginBinding {
        .init(id: id, origin: .init(terminal: .init(sessionID: "12345678-1234-1234-1234-123456789ABC"),
            process: .init(pid: pid, uid: 501, startMicroseconds: 10, processGroup: UInt32(pid), terminalGroup: UInt32(pid),
                terminalDevice: UInt32(pid), hasControllingTerminal: true, isCodex: true, capturedAt: now)))
    }
    func session(_ id: String, binding: ProtocolOriginBinding? = nil) -> AgentSession {
        var s = AgentSession(id: id, project: "Sample project"); s.execution = .idle
        if let binding { s.protocolBindings = [binding.id: .init(binding: binding, connected: true, updatedAt: now)] }
        return s
    }
    func testTwoRegisteredThreadsOnOneOpenTerminalStayIndependentAndClosedUnregisteredDisappear() {
        var state = RouterState(); let a = binding(), b = binding("closed", pid: 600)
        var first = session("first", binding: a)
        first.requests["q"] = .init(id: "q", kind: .question, evidence: .unknown, updatedAt: now)
        state.sessions = ["first": first, "second": session("second", binding: a),
                          "closed": session("closed", binding: b), "unregistered": session("unregistered")]
        let filter = OpenThreadFilter(state: state, processes: [500: .present(a.origin.process), 600: .absent], currentUID: 501)
        XCTAssertEqual(filter.visibleThreadIDs, ["first", "second"])
        let overview = SessionOverview(state: state, bridgeMode: true, visibleThreadIDs: filter.visibleThreadIDs)
        XCTAssertEqual(overview.groups.count, 1); XCTAssertEqual(overview.registeredThreads.count, 2)
        XCTAssertEqual(overview.attentionCount, 1); XCTAssertTrue(overview.history.isEmpty)
    }
    func testExitOnlyHidesRecordsAndDoesNotResolveRequestsOrRemoveHistoricalEvidence() throws {
        var state = RouterState(); var s = session("s", binding: binding())
        s.requests["approval"] = .init(id: "approval", kind: .approval, evidence: .confirmed, updatedAt: now)
        s.completionAt = now; state.sessions[s.id] = s
        let snapshot = try JSONEncoder().encode(state)
        let filter = OpenThreadFilter(state: state, processes: [500: .absent], currentUID: 501)
        XCTAssertTrue(filter.visibleThreadIDs.isEmpty)
        XCTAssertEqual(state, try JSONDecoder().decode(RouterState.self, from: snapshot))
        XCTAssertEqual(SessionOverview(state: state, bridgeMode: true).registeredThreads.count, 1)
        XCTAssertEqual(state.sessions["s"]?.requests["approval"]?.evidence, .confirmed)
    }
    func testReusedPIDWrongUIDChangedTTYExitedCodexAndLostTerminalAreHidden() {
        let b = binding(); var state = RouterState(); state.sessions["s"] = session("s", binding: b)
        var cases: [ProcessOriginHint] = []
        var p = b.origin.process; p.startMicroseconds += 1; cases.append(p)
        p = b.origin.process; p.uid += 1; cases.append(p)
        p = b.origin.process; p.terminalDevice += 1; cases.append(p)
        p = b.origin.process; p.isCodex = false; cases.append(p)
        p = b.origin.process; p.hasControllingTerminal = false; cases.append(p)
        for actual in cases {
            XCTAssertTrue(OpenThreadFilter(state: state, processes: [500: .present(actual)], currentUID: 501).visibleThreadIDs.isEmpty)
        }
    }
    func testIdleOldUnknownAndBackgroundJobDoNotMeanExited() {
        let b = binding(); var state = RouterState(); var s = session("s", binding: b)
        s.lastSeen = .distantPast; s.execution = .unknown
        s.requests["q"] = .init(id: "q", kind: .question, evidence: .unknown, updatedAt: .distantPast)
        state.sessions[s.id] = s
        var p = b.origin.process; p.terminalGroup += 1
        XCTAssertFalse(p.isDirectForegroundCandidate)
        XCTAssertEqual(OpenThreadFilter(state: state, processes: [500: .present(p)], currentUID: 501).visibleThreadIDs, ["s"])
    }
    func testUnavailableInspectionRetainsRegisteredRecordsAndReportsUncertainty() {
        var state = RouterState(); state.sessions["s"] = session("s", binding: binding())
        for statuses: [Int32: RegisteredProcessStatus] in [[:], [500: .unavailable]] {
            let filter = OpenThreadFilter(state: state, processes: statuses, currentUID: 501)
            XCTAssertEqual(filter.visibleThreadIDs, ["s"]); XCTAssertEqual(filter.unavailableProcessIDs, [500])
        }
    }
    func testDisconnectedRegistrationHidesEvenIfProcessStillExistsAndArchiveRemainsReversible() {
        let b = binding(); var state = RouterState(); var s = session("s", binding: b)
        s.protocolBindings?[b.id]?.connected = false; state.sessions[s.id] = s
        XCTAssertTrue(OpenThreadFilter(state: state, processes: [500: .present(b.origin.process)], currentUID: 501).visibleThreadIDs.isEmpty)
        state.sessions[s.id]?.protocolBindings?[b.id]?.connected = true
        XCTAssertTrue(state.setArchived(s.id, archived: true, now: now))
        let filter = OpenThreadFilter(state: state, processes: [500: .present(b.origin.process)], currentUID: 501)
        XCTAssertEqual(filter.visibleThreadIDs, ["s"])
        XCTAssertTrue(SessionOverview(state: state, bridgeMode: true, visibleThreadIDs: filter.visibleThreadIDs).groups.isEmpty)
        XCTAssertTrue(state.setArchived(s.id, archived: false))
        XCTAssertEqual(SessionOverview(state: state, bridgeMode: true, visibleThreadIDs: filter.visibleThreadIDs).registeredThreads.count, 1)
    }
    func testSharedBindingsKeepAmbiguityWithoutChoosingTheNewestOrResolvingAnything() {
        let a = binding(), b = binding("two", pid: 600); var state = RouterState()
        var s = session("shared", binding: a)
        s.protocolBindings?[b.id] = .init(binding: b, connected: true, updatedAt: now.addingTimeInterval(1)); state.sessions[s.id] = s
        let filter = OpenThreadFilter(state: state, processes: [500: .present(a.origin.process), 600: .absent], currentUID: 501)
        let overview = SessionOverview(state: state, bridgeMode: true, visibleThreadIDs: filter.visibleThreadIDs)
        XCTAssertEqual(filter.visibleThreadIDs, ["shared"])
        XCTAssertNil(overview.groups.first?.sourceKey); XCTAssertNil(state.sessions["shared"]?.verifiedProtocolBinding)
    }
}

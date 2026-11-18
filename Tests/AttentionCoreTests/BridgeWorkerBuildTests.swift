import XCTest
@testable import AttentionCore

final class BridgeWorkerBuildTests: XCTestCase {
    let current = "00000000-0000-0000-0000-000000000001"
    let earlier = "00000000-0000-0000-0000-000000000002"
    let now = Date()
    func binding(_ id: String = "connection") -> ProtocolOriginBinding {
        .init(id: id, origin: .init(terminal: .init(sessionID: "12345678-1234-1234-1234-123456789ABC"),
            process: .init(pid: 500, uid: 501, startMicroseconds: 10, processGroup: 500,
                           terminalGroup: 500, terminalDevice: 20, hasControllingTerminal: true, isCodex: true, capturedAt: now)))
    }
    func registration(_ build: String?, id: String = "connection", at: Date? = nil) -> AgentEvent {
        var event = AgentEvent(kind: .sessionStarted, sessionID: "s", protocolBinding: binding(id), timestamp: at ?? now, source: "codex-protocol")
        event.workerBuildUUID = build
        return event
    }
    func health(_ state: RouterState, helper: String? = nil) -> BridgeWorkerBuildStatus {
        .init(session: state.sessions["s"] ?? .init(id: "s", project: "sample"), installedHelper: helper ?? current)
    }
    func testActualWorkerBuildIsComparedWithPackagedHelperAndChangesAfterReplacement() throws {
        var state = RouterState(); try state.apply(registration(current))
        XCTAssertEqual(health(state).status, .current)
        XCTAssertEqual(health(state, helper: earlier).status, .reconnectNeeded)
        XCTAssertEqual(health(state, helper: earlier).running, current)
        XCTAssertEqual(health(state, helper: earlier).installed, earlier)
        XCTAssertEqual(BridgeWorkerBuildStatus(session: state.sessions["s"]!, installedHelper: nil).status, .helperUnavailable)
        XCTAssertEqual(health(state, helper: "not-a-uuid").status, .helperUnavailable)
    }
    func testLegacySnapshotAndMissingWorkerMetadataNeverClaimCurrent() throws {
        var state = RouterState(); try state.apply(registration(nil))
        let decoded = try JSONDecoder().decode(RouterState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(health(decoded).status, .unverified)
        XCTAssertNil(decoded.sessions["s"]?.protocolBindings?["connection"]?.workerBuildUUID)
        XCTAssertEqual(health(RouterState()).status, .notRegistered)
    }
    func testAmbiguousAndDisconnectedConnectionsNeverClaimCurrent() throws {
        var state = RouterState(); try state.apply(registration(current))
        try state.apply(registration(current, id: "second"))
        XCTAssertEqual(health(state).status, .ambiguous)
        for id in ["connection", "second"] {
            try state.apply(.init(kind: .sourceLost, sessionID: "s", protocolBinding: binding(id), timestamp: now.addingTimeInterval(1), source: "codex-protocol"))
        }
        XCTAssertEqual(health(state).status, .disconnected)
    }
    func testMissingAndOutOfOrderMetadataCannotRelabelKnownWorker() throws {
        var state = RouterState(); try state.apply(registration(current))
        try state.apply(.init(kind: .activity, sessionID: "s", protocolBinding: binding(), timestamp: now.addingTimeInterval(1), source: "codex-protocol"))
        XCTAssertEqual(health(state).status, .current)
        try state.apply(registration(earlier, at: now.addingTimeInterval(-1)))
        XCTAssertEqual(health(state).status, .current)
        try state.apply(registration(earlier, at: now.addingTimeInterval(2)))
        XCTAssertEqual(health(state).status, .conflicting)
        try state.apply(registration(current, at: now.addingTimeInterval(3)))
        XCTAssertEqual(health(state).status, .conflicting)
        XCTAssertEqual(state.sessions["s"]?.verifiedProtocolBinding?.reference, binding().reference)
    }
    func testFreshConnectionCanReportNewBuildWithoutRevivingOldSource() throws {
        var state = RouterState(); try state.apply(registration(earlier))
        try state.apply(.init(kind: .questionQueued, sessionID: "s", questionIDs: ["q"], protocolBinding: binding(), timestamp: now, source: "codex-protocol"))
        try state.apply(.init(kind: .sourceLost, sessionID: "s", protocolBinding: binding(), timestamp: now.addingTimeInterval(1), source: "codex-protocol"))
        try state.apply(registration(current, id: "fresh", at: now.addingTimeInterval(2)))
        try state.apply(registration(earlier, at: now.addingTimeInterval(3)))
        XCTAssertEqual(health(state).status, .current)
        XCTAssertEqual(state.sessions["s"]?.protocolBindings?["connection"]?.connected, false)
        XCTAssertEqual(state.sessions["s"]?.verifiedProtocolBinding?.id, "fresh")
        XCTAssertEqual(state.sessions["s"]?.requests["q"]?.evidence, .unknown)
        XCTAssertFalse(state.sessions["s"]!.requests["q"]!.reviewed)
    }
    func testBuildMetadataRequiresValidProtocolOriginAndCanonicalUUID() throws {
        var event = registration("not-a-uuid")
        XCTAssertThrowsError(try event.validate())
        event = registration(current); event.source = "codex-hook"
        XCTAssertThrowsError(try event.validate())
        event = registration(current); event.protocolBinding = nil
        XCTAssertThrowsError(try event.validate())
    }
    func testObserverPropagatesPinnedWorkerBuildAcrossResumeAndEvents() throws {
        var observer = CodexProtocolObserver(binding: binding(), project: "sample", workerBuildUUID: current)
        func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        _ = observer.observe(try json(["id": 1, "method": "thread/start"]), from: .client)
        let events = observer.observe(try json(["id": 1, "result": ["thread": ["id": "s", "status": ["type": "idle"]]]]), from: .server)
        XCTAssertEqual(events.first?.workerBuildUUID, current)
        let gap = observer.observationGap()
        XCTAssertEqual(gap.first?.workerBuildUUID, current)
        let lost = observer.disconnect()
        XCTAssertEqual(lost.first?.workerBuildUUID, current)
        XCTAssertFalse(events.contains { $0.kind == .humanApprovalPending || $0.kind == .requestResolved })
    }
    func testWorkerReportsItsPinnedNativeClientVersionAndOldRecordsStayUnknown() throws {
        var observer = CodexProtocolObserver(binding: binding(), project: "sample", nativeClientVersion: "0.170.0")
        _ = observer.observe(Data(#"{"id":1,"method":"thread/resume"}"#.utf8), from: .client)
        let events = observer.observe(Data(#"{"id":1,"result":{"thread":{"id":"s","status":{"type":"idle"}}}}"#.utf8), from: .server)
        var state = RouterState()
        for event in events { try state.apply(event) }
        let decoded = try JSONDecoder().decode(RouterState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(health(decoded).nativeVersion, "0.170.0")
        XCTAssertTrue(health(decoded).detail.contains("Running native Codex · 0.170.0"))
        var invalid = registration(current); invalid.nativeClientVersion = "0.171.0"
        XCTAssertThrowsError(try invalid.validate())
        invalid.nativeClientVersion = "0.170.0"; invalid.source = "codex-hook"
        XCTAssertThrowsError(try invalid.validate())
    }
}

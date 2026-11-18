import XCTest
@testable import AttentionCore

final class BridgeRecoveryCompletionTests: XCTestCase {
    func binding(_ id: String) -> ProtocolOriginBinding {
        let process = ProcessOriginHint(pid: 500, uid: 501, startMicroseconds: 10, processGroup: 500,
            terminalGroup: 500, terminalDevice: 20, hasControllingTerminal: true, isCodex: true,
            capturedAt: Date(timeIntervalSince1970: 1_000))
        return .init(id: id, origin: .init(terminal: .init(sessionID: "12345678-1234-1234-1234-123456789ABC"), process: process))
    }
    func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    func resume(_ observer: inout CodexProtocolObserver, status: String, turns: [[String: Any]]) throws -> [AgentEvent] {
        _ = observer.observe(try json(["id": 1, "method": "thread/resume"]), from: .client)
        return observer.observe(try json(["id": 1, "result": ["thread": ["id": "thread", "status": ["type": status], "turns": turns]]]), from: .server)
    }
    func testOnlyAnObservedActiveTurnCanBeRecoveredFromAnExplicitCompletedSnapshot() throws {
        var previous = CodexProtocolObserver(binding: binding("old"), project: "Synthetic")
        let registration = try resume(&previous, status: "idle", turns: [])
        var state = RouterState()
        for event in registration { try state.apply(event) }
        try state.apply(.init(kind: .questionQueued, sessionID: "thread", questionIDs: ["pending-question"],
                              protocolBinding: binding("old"), source: "codex-protocol"))
        _ = previous.observe(try json(["method": "turn/started", "params": ["threadId": "thread", "turn": ["id": "known-turn"]]]), from: .server)
        XCTAssertEqual(previous.recoveryTurns, ["thread": "known-turn"])
        for event in previous.disconnect() { try state.apply(event) }
        var recovered = CodexProtocolObserver(binding: binding("new"), project: "Synthetic", recoveryTurns: previous.recoveryTurns)
        let events = try resume(&recovered, status: "idle", turns: [["id": "known-turn", "status": "completed"]])
        XCTAssertEqual(events.map(\.kind), [.sessionStarted, .turnStopped])
        XCTAssertEqual(events.last?.turnID, "known-turn")
        XCTAssertEqual(events.last?.recoveredFromHistory, true)
        XCTAssertEqual(events.last?.protocolBinding, binding("new"))
        XCTAssertTrue(recovered.recoveryTurns.isEmpty)
        XCTAssertFalse(events.contains { $0.kind == .requestResolved || $0.kind == .requestCancelled })
        for event in events { try state.apply(event) }
        XCTAssertEqual(state.sessions["thread"]?.execution, .idle)
        XCTAssertEqual(state.sessions["thread"]?.requests["pending-question"]?.evidence, .unknown)
        XCTAssertNotNil(state.sessions["thread"]?.completionAt)
    }
    func testIdleAloneOldHistoryDifferentTurnDuplicateOrActiveSnapshotNeverInventsCompletion() throws {
        for (known, status, turns) in [
            ([:], "idle", [["id": "known-turn", "status": "completed"]]),
            (["thread": "known-turn"], "idle", []),
            (["thread": "known-turn"], "idle", [["id": "different-turn", "status": "completed"]]),
            (["thread": "known-turn"], "active", [["id": "known-turn", "status": "completed"]]),
            (["thread": "known-turn"], "idle", [["id": "known-turn", "status": "completed"], ["id": "known-turn", "status": "completed"]])
        ] as [([String: String], String, [[String: String]])] {
            var observer = CodexProtocolObserver(binding: binding("new"), project: "Synthetic", recoveryTurns: known)
            let events = try resume(&observer, status: status, turns: turns)
            XCTAssertEqual(events.map(\.kind), [.sessionStarted])
        }
    }
    func testAlreadyObservedCompletionAndUnsubscribeDoNotCreateARecoveryReplay() throws {
        for finish in ["turn/completed", "thread/unsubscribe"] {
            var observer = CodexProtocolObserver(binding: binding("old"), project: "Synthetic")
            _ = try resume(&observer, status: "active", turns: [["id": "known-turn", "status": "inProgress"]])
            XCTAssertEqual(observer.recoveryTurns["thread"], "known-turn")
            if finish == "turn/completed" {
                _ = observer.observe(try json(["method": finish, "params": ["threadId": "thread", "turn": ["id": "known-turn", "status": "completed"]]]), from: .server)
            } else {
                _ = observer.observe(try json(["id": 2, "method": finish, "params": ["threadId": "thread"]]), from: .client)
            }
            XCTAssertTrue(observer.recoveryTurns.isEmpty)
        }
    }
}

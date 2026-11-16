import XCTest
@testable import AttentionCore

final class BridgeObserverTests: XCTestCase {
    func testMCPToolApprovalIsObservedWithoutPersistingToolOrFormContent() throws {
        var observer = try registered(); let now = Date()
        let events = observer.observe(try data(["id": 40, "method": "mcpServer/elicitation/request", "params": [
            "threadId": "s", "turnId": NSNull(), "serverName": "PRIVATE_SERVER", "mode": "form",
            "_meta": ["codex_approval_kind": "mcp_tool_call", "tool_params": ["body": "PRIVATE_BODY"]],
            "message": "PRIVATE_MESSAGE", "requestedSchema": ["type": "object", "properties": [:]]
        ]]), from: .server, now: now)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(events.count, 1); XCTAssertEqual(event.kind, .approvalRequested)
        XCTAssertNotNil(event.requestID); XCTAssertNil(event.turnID)
        var state = RouterState()
        try state.apply(.init(kind: .sessionStarted, sessionID: "s", protocolBinding: binding(), timestamp: now, source: "codex-protocol"))
        try state.apply(event)
        let session = try XCTUnwrap(state.sessions["s"])
        XCTAssertEqual(session.requests[event.requestID!]?.evidence, .observed)
        XCTAssertNotNil(NotificationPolicy.plan(event: event, session: session, sourceInstance: "synthetic-verified-source", submitted: [:], now: now))
        let encoded = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        for secret in ["PRIVATE_SERVER", "PRIVATE_BODY", "PRIVATE_MESSAGE"] { XCTAssertFalse(encoded.contains(secret)) }
    }
    func testMCPApprovalNeedsAnExplicitSupportedApprovalMarkerAndOwnedThread() throws {
        for mode in ["form", "openai/form", "openaiForm"] {
            var observer = try registered()
            var params: [String: Any] = ["threadId": "s", "mode": mode, "_meta": ["codex_approval_kind": "mcp_tool_call"]]
            XCTAssertEqual(observer.observe(try data(["id": "a", "method": "mcpServer/elicitation/request", "params": params]), from: .server).first?.kind, .approvalRequested)
            params["threadId"] = "unowned"
            let unowned = observer.observe(try data(["id": "b", "method": "mcpServer/elicitation/request", "params": params]), from: .server)
            XCTAssertEqual(unowned.first?.coverageIssue, .unscopedRequest)
            XCTAssertFalse(unowned.contains { $0.kind == .approvalRequested || $0.kind == .questionQueued })
            params["threadId"] = "s"; params["_meta"] = [:]
            XCTAssertEqual(observer.observe(try data(["id": "c", "method": "mcpServer/elicitation/request", "params": params]), from: .server).first?.kind, .questionQueued)
            params["_meta"] = ["codex_approval_kind": "browser_auth"]
            XCTAssertEqual(observer.observe(try data(["id": "d", "method": "mcpServer/elicitation/request", "params": params]), from: .server).first?.kind, .questionQueued)
            params["_meta"] = ["codex_approval_kind": "mcp_tool_call"]; params["mode"] = "url"
            XCTAssertEqual(observer.observe(try data(["id": "e", "method": "mcpServer/elicitation/request", "params": params]), from: .server).first?.coverageIssue, .unsupportedInput)
        }
    }
    func testMCPResolutionNeedsServerConfirmationAndPreservesSiblingApprovals() throws {
        var observer = try registered()
        let params: [String: Any] = ["threadId": "s", "mode": "form", "_meta": ["codex_approval_kind": "mcp_tool_call"]]
        let first = try XCTUnwrap(observer.observe(try data(["id": 9, "method": "mcpServer/elicitation/request", "params": params]), from: .server).first)
        let sibling = try XCTUnwrap(observer.observe(try data(["id": "9", "method": "mcpServer/elicitation/request", "params": params]), from: .server).first)
        XCTAssertNotEqual(first.requestID, sibling.requestID)
        XCTAssertTrue(observer.observe(try data(["id": 9, "result": ["action": "accept"]]), from: .client).isEmpty)
        XCTAssertTrue(observer.observe(try data(["method": "serverRequest/resolved", "params": ["threadId": "unowned", "requestId": 9]]), from: .server).isEmpty)
        let resolved = try XCTUnwrap(observer.observe(try data(["method": "serverRequest/resolved", "params": ["threadId": "s", "requestId": 9]]), from: .server).first)
        XCTAssertEqual(resolved.requestID, first.requestID)
        let other = observer.observe(try data(["method": "serverRequest/resolved", "params": ["threadId": "s", "requestId": "9"]]), from: .server)
        XCTAssertEqual(other.first?.requestID, sibling.requestID)
    }
    func testResumingRetiredActiveThreadRestoresRunningWithoutInventingTurnOrAnswers() throws {
        var observer = try registered(); var state = RouterState(); let now = Date()
        try state.apply(.init(kind: .sessionStarted, sessionID: "s", protocolBinding: binding(), timestamp: now, source: "codex-protocol"))
        try state.apply(.init(kind: .questionQueued, sessionID: "s", questionIDs: ["q"], protocolBinding: binding(), timestamp: now, source: "codex-protocol"))
        for event in observer.observe(try data(["method": "turn/started", "params": ["threadId": "s", "turn": ["id": "work"]]]), from: .server) { try state.apply(event) }
        for event in observer.observe(try data(["id": 10, "method": "thread/unsubscribe", "params": ["threadId": "s"]]), from: .client) { try state.apply(event) }
        _ = observer.observe(try data(["id": 11, "method": "thread/resume", "params": ["threadId": "s"]]), from: .client)
        let resumed = observer.observe(try data(["id": 11, "result": ["thread": ["id": "s", "status": ["type": "active", "activeFlags": ["waitingOnApproval"]]]]]), from: .server)
        for event in resumed { try state.apply(event) }
        XCTAssertEqual(state.sessions["s"]?.execution, .running)
        XCTAssertEqual(state.sessions["s"]?.requests["q"]?.evidence, .unknown)
        XCTAssertNotEqual(state.sessions["s"]?.verifiedProtocolBinding?.reference, binding().reference)
        XCTAssertFalse(resumed.contains { [.turnStarted, .turnStopped, .humanApprovalPending, .requestResolved].contains($0.kind) })
        XCTAssertNil(state.sessions["s"]?.completionAt)
    }
    func testNewConnectionResumeUsesCurrentStatusWithoutReopeningClosedBinding() throws {
        var state = RouterState(); let now = Date()
        try state.apply(.init(kind: .sessionStarted, sessionID: "s", protocolBinding: binding(), timestamp: now, source: "codex-protocol"))
        try state.apply(.init(kind: .sourceLost, sessionID: "s", protocolBinding: binding(), timestamp: now.addingTimeInterval(1), source: "codex-protocol"))
        var observer = CodexProtocolObserver(binding: binding("new-connection", pid: 501), project: "sample")
        _ = observer.observe(try data(["id": 1, "method": "thread/resume", "params": ["threadId": "s"]]), from: .client)
        for event in observer.observe(try data(["id": 1, "result": ["thread": ["id": "s", "status": ["type": "active", "activeFlags": []]]]]), from: .server, now: now.addingTimeInterval(2)) { try state.apply(event) }
        XCTAssertEqual(state.sessions["s"]?.execution, .running)
        XCTAssertEqual(state.sessions["s"]?.protocolBindings?["connection-a"]?.connected, false)
        XCTAssertEqual(state.sessions["s"]?.verifiedProtocolBinding?.id, "new-connection")
        XCTAssertNil(state.sessions["s"]?.completionAt)
    }
    func testResumeStatusAbsentUnknownOrUnloadedCannotClaimIdleOrHumanWait() throws {
        for status: [String: Any]? in [nil, [:], ["type": "notLoaded"], ["type": "systemError"], ["type": "future"], ["type": "idle"]] {
            var observer = CodexProtocolObserver(binding: binding(), project: "sample"); var state = RouterState()
            _ = observer.observe(try data(["id": 1, "method": "thread/resume", "params": ["threadId": "s"]]), from: .client)
            var thread: [String: Any] = ["id": "s"]; if let status { thread["status"] = status }
            let events = observer.observe(try data(["id": 1, "result": ["thread": thread]]), from: .server)
            for event in events { try state.apply(event) }
            XCTAssertEqual(state.sessions["s"]?.execution, status?["type"] as? String == "idle" ? .idle : .unknown)
            XCTAssertTrue(state.sessions["s"]?.requests.isEmpty ?? false)
            XCTAssertFalse(events.contains { $0.kind == .humanApprovalPending || $0.kind == .turnStopped })
        }
    }
    func testExecutionSnapshotCannotBeClaimedByHookOrNonRegistrationEvent() throws {
        let invalid = [
            AgentEvent(kind: .sessionStarted, sessionID: "s"),
            AgentEvent(kind: .sessionStarted, sessionID: "s", source: "codex-protocol"),
            AgentEvent(kind: .turnStarted, sessionID: "s", protocolBinding: binding(), source: "codex-protocol")
        ]
        for event in invalid {
            var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
            payload["executionObservation"] = "running"
            let decoded = try JSONDecoder().decode(AgentEvent.self, from: data(payload))
            XCTAssertThrowsError(try decoded.validate())
        }
    }
    func test169PickerReadCannotBindOrResetInterleavedRunningSource() throws {
        var observer = try registered(); var state = RouterState()
        let now = Date()
        try state.apply(.init(kind: .sessionStarted, sessionID: "s", protocolBinding: binding(), timestamp: now, source: "codex-protocol"))
        let running = observer.observe(try data(["method": "turn/started", "params": ["threadId": "s", "turn": ["id": "work"]]]), from: .server, now: now.addingTimeInterval(1))
        for event in running { try state.apply(event) }
        _ = observer.observe(try data(["id": 2, "method": "thread/resume", "params": ["threadId": "s"]]), from: .client)
        let pickerID = "picker-00000000-0000-0000-0000-000000000001-2"
        _ = observer.observe(try data(["id": pickerID, "method": "thread/read", "params": ["threadId": "s"]]), from: .client)
        let metadata = observer.observe(try data(["id": pickerID, "result": ["thread": ["id": "s", "preview": "SYNTHETIC-PRIVATE"]]]), from: .server)
        XCTAssertTrue(metadata.isEmpty)
        let resumed = observer.observe(try data(["id": 2, "result": ["thread": ["id": "s"]]]), from: .server)
        XCTAssertTrue(resumed.isEmpty)
        XCTAssertEqual(observer.pickerMetadataRequestCount, 1)
        XCTAssertEqual(state.sessions["s"]?.execution, .running)
        XCTAssertEqual(state.sessions["s"]?.verifiedProtocolBinding, binding())
    }
    func test169OversizedPickerListRequiresItsExactCorrelatedResponse() throws {
        var observer = try registered()
        let id = "picker-00000000-0000-0000-0000-000000000001-1"
        _ = observer.observe(try data(["id": id, "method": "thread/list", "params": [:]]), from: .client)
        XCTAssertFalse(observer.ignoreOversizedServerResponse(Data("{\"id\":\"picker-other\",\"result\":".utf8)))
        XCTAssertFalse(observer.ignoreOversizedServerResponse(Data(("{\"id\":\"" + id + "\",\"method\":\"item/commandExecution/requestApproval\",\"params\":").utf8)))
        let prefix = Data(("{\"id\":\"" + id + "\",\"result\":").utf8)
        XCTAssertTrue(observer.ignoreOversizedServerResponse(prefix))
        XCTAssertEqual(observer.ignoredOversizedMethods, ["thread/list": 1])
        XCTAssertFalse(observer.ignoreOversizedServerResponse(prefix))
    }
    func binding(_ id: String = "connection-a", pid: Int32 = 500) -> ProtocolOriginBinding {
        .init(id: id, origin: .init(terminal: .init(sessionID: "12345678-1234-1234-1234-123456789ABC"),
            process: .init(pid: pid, uid: 501, startMicroseconds: 100, processGroup: UInt32(pid),
                terminalGroup: UInt32(pid), terminalDevice: 20, hasControllingTerminal: true, isCodex: true, capturedAt: Date(timeIntervalSince1970: 100))))
    }
    func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    func testConnectionResponseBindsOnlyItsOwnThreadAndRedactsContent() throws {
        var observer = CodexProtocolObserver(binding: binding(), project: "sample")
        XCTAssertTrue(observer.observe(try data(["id": 1, "method": "thread/start", "params": ["cwd": "/SECRET"]]), from: .client).isEmpty)
        let events = observer.observe(try data(["id": 1, "result": ["thread": ["id": "thread-a", "cwd": "/private/SECRET/actual-project", "preview": "SECRET", "turns": []]]]), from: .server)
        XCTAssertEqual(events.map(\.kind), [.sessionStarted])
        XCTAssertEqual(events.first?.protocolBinding?.id, "connection-a")
        XCTAssertEqual(events.first?.project, "actual-project")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(events), as: UTF8.self).contains("SECRET"))
        // An unrelated broadcast cannot silently claim another client's thread.
        XCTAssertTrue(observer.observe(try data(["method": "turn/started", "params": ["threadId": "other", "turn": ["id": "t"]]]), from: .server).isEmpty)
    }
    func registered() throws -> CodexProtocolObserver {
        var observer = CodexProtocolObserver(binding: binding(), project: "sample")
        _ = observer.observe(try data(["id": 1, "method": "thread/start", "params": [:]]), from: .client)
        _ = observer.observe(try data(["id": 1, "result": ["thread": ["id": "s"]]]), from: .server)
        return observer
    }
    func testTwoAsyncQuestionsAndTransportAckDoesNotResolveThem() throws {
        var observer = try registered()
        let events = observer.observe(try data(["method": "item/completed", "params": ["threadId": "s", "turnId": "t", "item": ["type": "agentMessage", "id": "call-a", "text": "SECRET", "questions": [["title": "SECRET"], ["title": "SECRET"]]]]]), from: .server)
        XCTAssertEqual(events.first?.kind, .questionQueued)
        XCTAssertEqual(events.first?.questionIDs.count, 2)
        XCTAssertTrue(observer.observe(try data(["method": "serverRequest/resolved", "params": ["threadId": "s", "requestId": 9]]), from: .server).isEmpty)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(events), as: UTF8.self).contains("SECRET"))
    }
    func testOnlyAcceptedStructuredEditorEchoResolvesExactQuestion() throws {
        var observer = try registered()
        let id = "[\"request_user_input_async\",\"call-a\",0]"
        let body = try JSONSerialization.data(withJSONObject: [["answer": "SECRET", "question": "SECRET", "questionItemId": id]])
        let reply = "<send_user_message_question_reply>\n" + String(decoding: body, as: UTF8.self) + "\n</send_user_message_question_reply>"
        let input: [[String: Any]] = [["type": "text", "text": reply]]
        let submitted = observer.observe(try data(["id": 2, "method": "turn/start", "params": ["threadId": "s", "input": input]]), from: .client)
        XCTAssertFalse(submitted.contains { $0.kind == .requestResolved })
        XCTAssertEqual(submitted.first?.questionIDs, [id])
        let accepted = observer.observe(try data(["method": "item/completed", "params": ["threadId": "s", "turnId": "t", "item": ["type": "userMessage", "id": "u", "content": input]]]), from: .server)
        XCTAssertEqual(accepted.first?.kind, .requestResolved)
        XCTAssertEqual(accepted.first?.questionIDs, [id])
        var state = RouterState()
        try state.apply(.init(kind: .questionQueued, sessionID: "s", questionIDs: [id, "other-question"], timestamp: .distantPast, source: "codex-protocol"))
        try state.apply(submitted[0]); try state.apply(accepted[0])
        XCTAssertEqual(state.sessions["s"]?.requests[id]?.evidence, .resolved)
        XCTAssertEqual(state.sessions["s"]?.requests["other-question"]?.evidence, .observed)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(accepted), as: UTF8.self).contains("SECRET"))
        let ordinary = observer.observe(try data(["method": "item/completed", "params": ["threadId": "s", "item": ["type": "userMessage", "id": "u2", "content": [["type": "text", "text": "I choose blue"]]]]]), from: .server)
        XCTAssertFalse(ordinary.contains { $0.kind == .requestResolved })
    }
    func testApprovalRPCRemainsEarlyAndResolvedByMatchingIDOnly() throws {
        var observer = try registered()
        let request = observer.observe(try data(["id": 9, "method": "item/commandExecution/requestApproval", "params": ["threadId": "s", "turnId": "t", "itemId": "command", "command": "SECRET"]]), from: .server)
        XCTAssertEqual(request.first?.kind, .approvalRequested)
        XCTAssertTrue(observer.observe(try data(["method": "serverRequest/resolved", "params": ["threadId": "s", "requestId": "9"]]), from: .server).isEmpty)
        let resolution = observer.observe(try data(["method": "serverRequest/resolved", "params": ["threadId": "s", "requestId": 9]]), from: .server)
        XCTAssertEqual(resolution.first?.kind, .requestResolved)
        XCTAssertEqual(resolution.first?.requestID, request.first?.requestID)
        XCTAssertFalse(request.contains { $0.kind == .humanApprovalPending })
    }
    func testDisconnectDoesNotResolveOrEndThreadAndCannotReopenBinding() throws {
        var observer = try registered()
        var state = RouterState()
        let initial = AgentEvent(kind: .sessionStarted, sessionID: "s", protocolBinding: binding(), source: "codex-protocol")
        try state.apply(initial)
        let lost = observer.disconnect(now: initial.timestamp.addingTimeInterval(1))
        XCTAssertEqual(lost.first?.kind, .sourceLost)
        try state.apply(lost[0])
        XCTAssertNil(state.sessions["s"]?.verifiedProtocolBinding)
        var late = initial; late.id = "late"; late.timestamp = initial.timestamp.addingTimeInterval(2)
        try state.apply(late)
        XCTAssertNil(state.sessions["s"]?.verifiedProtocolBinding)
        XCTAssertEqual(state.sessions["s"]?.execution, .unknown)
    }
    func testConcurrentBindingsRefuseLastWriterWinsAndCanRecoverAfterOneCloses() throws {
        var state = RouterState(); let time = Date()
        try state.apply(.init(kind: .sessionStarted, sessionID: "s", protocolBinding: binding(), timestamp: time, source: "codex-protocol"))
        try state.apply(.init(kind: .sessionStarted, sessionID: "s", protocolBinding: binding("connection-b", pid: 501), timestamp: time.addingTimeInterval(1), source: "codex-protocol"))
        XCTAssertNil(state.sessions["s"]?.verifiedProtocolBinding)
        try state.apply(.init(kind: .sourceLost, sessionID: "s", protocolBinding: binding("connection-b", pid: 501), timestamp: time.addingTimeInterval(2), source: "codex-protocol"))
        XCTAssertEqual(state.sessions["s"]?.verifiedProtocolBinding?.id, "connection-a")
    }
    func testMetadataGapPreservesExactBindingAndDoesNotLoseOutstandingRequests() throws {
        var observer = try registered(); var state = RouterState()
        let start = AgentEvent(kind: .sessionStarted, sessionID: "s", protocolBinding: binding(), source: "codex-protocol")
        try state.apply(start)
        try state.apply(.init(kind: .questionQueued, sessionID: "s", questionIDs: ["q"], protocolBinding: binding(), source: "codex-protocol"))
        for event in observer.observationGap() { try state.apply(event) }
        XCTAssertEqual(state.sessions["s"]?.requests["q"]?.evidence, .unknown)
        XCTAssertNotNil(state.sessions["s"]?.protocolGapAt)
        XCTAssertNotNil(state.sessions["s"]?.verifiedProtocolBinding)
        XCTAssertEqual(state.sessions["s"]?.execution, .unknown)
        let later = observer.observe(try data(["method": "turn/started", "params": ["threadId": "s", "turn": ["id": "t"]]]), from: .server)
        for event in later { try state.apply(event) }
        XCTAssertEqual(state.sessions["s"]?.execution, .running)
        XCTAssertNil(state.sessions["s"]?.protocolGapAt)
        XCTAssertEqual(state.sessions["s"]?.requests["q"]?.evidence, .unknown)
    }
    func testOfficialHiddenHelpersAreFilteredButUserEphemeralSessionsRemain() throws {
        for source in ["system", "thread_title", "user", "subagent"] {
            var observer = CodexProtocolObserver(binding: binding(), project: "sample")
            _ = observer.observe(try data(["id": 1, "method": "thread/start", "params": [:]]), from: .client)
            let events = observer.observe(try data(["id": 1, "result": ["thread": ["id": "s", "ephemeral": true, "threadSource": source]]]), from: .server)
            XCTAssertEqual(events.isEmpty, source == "system" || source == "thread_title")
        }
    }
    func testReplayedQuestionMessageCannotReopenUncertainRequests() throws {
        var observer = try registered(); var state = RouterState()
        let message = try data(["method": "item/completed", "params": ["threadId": "s", "item": ["type": "agentMessage", "id": "q", "questions": [["title": "sample"]]]]])
        let first = observer.observe(message, from: .server)
        try state.apply(first[0])
        try state.apply(.init(kind: .inputSubmitted, sessionID: "s", source: "codex-protocol"))
        let replay = observer.observe(message, from: .server)
        XCTAssertFalse(try state.apply(replay[0]))
        XCTAssertEqual(state.sessions["s"]?.outstanding.first?.evidence, .unknown)
    }
    func testOnlyExactKnownMetadataResponsesCanAvoidLifecycleGap() throws {
        var observer = try registered()
        _ = observer.observe(try data(["id": 99, "method": "app/list", "params": [:]]), from: .client)
        XCTAssertFalse(observer.ignoreOversizedServerResponse(Data("{\"id\":98,\"result\":".utf8)))
        XCTAssertFalse(observer.ignoreOversizedServerResponse(Data("{\"id\":99,\"method\":\"item/commandExecution/requestApproval\",\"params\":".utf8)))
        XCTAssertTrue(observer.ignoreOversizedServerResponse(Data("{\"id\":99,\"result\":".utf8)))
        XCTAssertEqual(observer.ignoredOversizedMethods, ["app/list": 1])
        XCTAssertFalse(observer.ignoreOversizedServerResponse(Data("{\"id\":99,\"result\":".utf8)))
        _ = observer.observe(try data(["id": 100, "method": "thread/start", "params": [:]]), from: .client)
        XCTAssertFalse(observer.ignoreOversizedServerResponse(Data("{\"id\":100,\"result\":".utf8)))
    }

    func testUnsubscribeImmediatelyRevokesOnlyThatThreadAndRetainsQuestions() throws {
        var observer = try registered(); var state = RouterState()
        let now = Date()
        try state.apply(.init(kind: .sessionStarted, sessionID: "s", protocolBinding: binding(), timestamp: now, source: "codex-protocol"))
        try state.apply(.init(kind: .questionQueued, sessionID: "s", questionIDs: ["q"], protocolBinding: binding(), timestamp: now, source: "codex-protocol"))
        _ = observer.observe(try data(["id": 2, "method": "thread/start", "params": [:]]), from: .client)
        let other = observer.observe(try data(["id": 2, "result": ["thread": ["id": "other"]]]), from: .server)
        try state.apply(other[0])
        let retired = observer.observe(try data(["id": 3, "method": "thread/unsubscribe", "params": ["threadId": "s"]]), from: .client)
        XCTAssertEqual(retired.map(\.kind), [.sourceLost])
        for event in retired { try state.apply(event) }
        XCTAssertNil(state.sessions["s"]?.verifiedProtocolBinding)
        XCTAssertEqual(state.sessions["s"]?.requests["q"]?.evidence, .unknown)
        XCTAssertEqual(state.sessions["s"]?.execution, .unknown)
        XCTAssertNotNil(state.sessions["other"]?.verifiedProtocolBinding)
        // An acknowledgement is not an answer; late broadcast traffic cannot reattach.
        XCTAssertTrue(observer.observe(try data(["id": 3, "result": ["status": "unsubscribed"]]), from: .server).isEmpty)
        XCTAssertTrue(observer.observe(try data(["method": "turn/started", "params": ["threadId": "s", "turn": ["id": "late"]]]), from: .server).isEmpty)
        XCTAssertTrue(observer.observe(try data(["method": "turn/started", "params": ["threadId": "other", "turn": ["id": "working"]]]), from: .server).contains { $0.kind == .turnStarted })
    }

    func testResumeAfterRetirementRequiresPositiveResponseAndNewReference() throws {
        var observer = try registered(); var state = RouterState()
        let start = AgentEvent(kind: .sessionStarted, sessionID: "s", protocolBinding: binding(), source: "codex-protocol")
        try state.apply(start)
        let lost = observer.observe(try data(["method": "thread/closed", "params": ["threadId": "s"]]), from: .server)
        XCTAssertEqual(lost.map(\.kind), [.sourceLost])
        for event in lost { try state.apply(event) }
        _ = observer.observe(try data(["id": "resume-failed", "method": "thread/resume", "params": ["threadId": "s"]]), from: .client)
        XCTAssertTrue(observer.observe(try data(["id": "resume-failed", "error": ["code": -1]]), from: .server).isEmpty)
        XCTAssertNil(state.sessions["s"]?.verifiedProtocolBinding)
        _ = observer.observe(try data(["id": "resume-ok", "method": "thread/resume", "params": ["threadId": "s"]]), from: .client)
        let resumed = observer.observe(try data(["id": "resume-ok", "result": ["thread": ["id": "s"]]]), from: .server)
        XCTAssertEqual(resumed.map(\.kind), [.sessionStarted])
        XCTAssertNotEqual(resumed.first?.protocolBinding?.reference, start.protocolBinding?.reference)
        XCTAssertEqual(resumed.first?.protocolBinding?.origin, start.protocolBinding?.origin)
        for event in resumed { try state.apply(event) }
        XCTAssertEqual(state.sessions["s"]?.verifiedProtocolBinding, resumed.first?.protocolBinding)
        // A late event for the old subscription cannot follow the newly resumed one.
        var late = start; late.id = "late-old-subscription"; late.timestamp = Date().addingTimeInterval(1)
        try state.apply(late)
        XCTAssertEqual(state.sessions["s"]?.verifiedProtocolBinding, resumed.first?.protocolBinding)
    }

    func testRepeatedResumeDoesNotResetAnAlreadyRunningSubscription() throws {
        var observer = try registered(); var state = RouterState()
        let running = observer.observe(try data(["method": "turn/started", "params": ["threadId": "s", "turn": ["id": "t"]]]), from: .server)
        try state.apply(running[0])
        _ = observer.observe(try data(["id": 2, "method": "thread/resume", "params": ["threadId": "s"]]), from: .client)
        let resumed = observer.observe(try data(["id": 2, "result": ["thread": ["id": "s"]]]), from: .server)
        for event in resumed { try state.apply(event) }
        XCTAssertEqual(state.sessions["s"]?.execution, .running)
        XCTAssertEqual(state.sessions["s"]?.verifiedProtocolBinding?.id, "connection-a")
    }

    func testResumeReplyFromBeforeUnsubscribeCannotReattachOldThread() throws {
        var observer = try registered()
        _ = observer.observe(try data(["id": 2, "method": "thread/resume", "params": ["threadId": "s"]]), from: .client)
        _ = observer.observe(try data(["id": 3, "method": "thread/unsubscribe", "params": ["threadId": "s"]]), from: .client)
        let late = observer.observe(try data(["id": 2, "result": ["thread": ["id": "s"]]]), from: .server)
        XCTAssertTrue(late.isEmpty)
        XCTAssertTrue(observer.observe(try data(["method": "turn/started", "params": ["threadId": "s", "turn": ["id": "late"]]]), from: .server).isEmpty)
    }
}

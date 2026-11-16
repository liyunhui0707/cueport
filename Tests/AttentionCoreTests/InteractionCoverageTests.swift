import XCTest
@testable import AttentionCore

final class InteractionCoverageTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func binding() -> ProtocolOriginBinding {
        .init(id: "synthetic-connection", origin: .init(terminal: .init(sessionID: "12345678-1234-1234-1234-123456789ABC"),
            process: .init(pid: 500, uid: 501, startMicroseconds: 10, processGroup: 500, terminalGroup: 500,
                           terminalDevice: 20, hasControllingTerminal: true, isCodex: true, capturedAt: now)))
    }
    func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    func observer() throws -> CodexProtocolObserver {
        var observer = CodexProtocolObserver(binding: binding(), project: "sample")
        _ = observer.observe(try json(["id": 1, "method": "thread/start"]), from: .client)
        _ = observer.observe(try json(["id": 1, "result": ["thread": ["id": "s", "status": ["type": "active"]]]]), from: .server)
        return observer
    }
    func input(_ blocking: Bool = true) -> [String: Any] {
        ["threadId": "s", "turnId": "t", "itemId": "call", "isBlocking": blocking,
         "questions": [["id": "first", "question": "SECRET_QUESTION", "options": [["label": "SECRET_OPTION"]]],
                       ["id": "second", "question": "SECRET_QUESTION_TWO", "isSecret": true]]]
    }
    func testNullableAgentQuestionsAreNotAnUnsupportedInputOrAQuestion() throws {
        var observer = try observer()
        for item: [String: Any] in [
            ["type": "agentMessage", "id": "normal", "text": "PRIVATE_REPLY", "questions": NSNull()],
            ["type": "agentMessage", "text": "PRIVATE_REPLY", "questions": NSNull()],
            ["type": "agentMessage", "id": "empty", "questions": []],
            ["type": "agentMessage", "id": "absent", "text": "PRIVATE_REPLY"]
        ] {
            let events = observer.observe(try json(["method": "item/completed", "params": ["threadId": "s", "item": item]]), from: .server)
            XCTAssertTrue(events.isEmpty)
        }
        XCTAssertEqual(observer.coverageNoticeCount, 0)
        let completion = observer.observe(try json(["method": "turn/completed", "params": ["threadId": "s", "turn": ["id": "turn", "status": "completed"]]]), from: .server)
        XCTAssertEqual(completion.map(\.kind), [.turnStopped])
        let malformed = observer.observe(try json(["method": "item/completed", "params": ["threadId": "s", "item": ["type": "agentMessage", "id": "bad", "questions": ["unexpected": true]]]]), from: .server)
        XCTAssertEqual(malformed.first?.coverageIssue, .unsupportedInput)
    }
    func testBlockingInputProducesDistinctPrivateQuestionsAndServerClearsOnlyItsPrompt() throws {
        var observer = try observer(); var state = RouterState()
        try state.apply(.init(kind: .sessionStarted, sessionID: "s", protocolBinding: binding(), executionObservation: .running, timestamp: now, source: "codex-protocol"))
        try state.apply(.init(kind: .questionQueued, sessionID: "s", questionIDs: ["older"], protocolBinding: binding(), timestamp: now, source: "codex-protocol"))
        let queued = try XCTUnwrap(observer.observe(try json(["id": 7, "method": "item/tool/requestUserInput", "params": input()]), from: .server, now: now).first)
        XCTAssertEqual(queued.kind, .questionQueued); XCTAssertEqual(Set(queued.questionIDs).count, 2)
        try state.apply(queued)
        XCTAssertEqual(state.sessions["s"]?.execution, .running)
        XCTAssertNotNil(NotificationPolicy.plan(event: queued, session: state.sessions["s"]!, sourceInstance: binding().reference, submitted: [:], now: now))
        XCTAssertTrue(observer.observe(try json(["id": 7, "result": ["answers": ["first": ["answers": ["SECRET_ANSWER"]]]]]), from: .client).isEmpty)
        XCTAssertEqual(state.sessions["s"]?.requests[queued.questionIDs[0]]?.evidence, .observed)
        let resolved = try XCTUnwrap(observer.observe(try json(["method": "serverRequest/resolved", "params": ["threadId": "s", "requestId": 7]]), from: .server, now: now.addingTimeInterval(1)).first)
        XCTAssertEqual(resolved.questionIDs, queued.questionIDs)
        try state.apply(resolved)
        XCTAssertEqual(state.sessions["s"]?.requests["older"]?.evidence, .observed)
        for id in queued.questionIDs { XCTAssertEqual(state.sessions["s"]?.requests[id]?.evidence, .resolved) }
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(state), as: UTF8.self).contains("SECRET"))
    }
    func testNonblockingCanonicalAsyncIDsDeduplicateWithAgentItemAndIgnoreRPCResolution() throws {
        var observer = try observer(); var params = input(false)
        let ids = ["[\"request_user_input_async\",\"call\",0]", "[\"request_user_input_async\",\"call\",1]"]
        params["questions"] = ids.map { ["id": $0] }
        let queued = try XCTUnwrap(observer.observe(try json(["id": 8, "method": "item/tool/requestUserInput", "params": params]), from: .server, now: now).first)
        XCTAssertEqual(queued.questionIDs, ids)
        XCTAssertTrue(observer.observe(try json(["method": "serverRequest/resolved", "params": ["threadId": "s", "requestId": 8]]), from: .server).isEmpty)
        let echo = try XCTUnwrap(observer.observe(try json(["method": "item/completed", "params": ["threadId": "s", "item": ["type": "agentMessage", "id": "call", "questions": [[:], [:]]]]]), from: .server).first)
        XCTAssertEqual(echo.id, queued.id)
        var state = RouterState(); try state.apply(queued)
        XCTAssertFalse(try state.apply(echo)); XCTAssertEqual(state.sessions["s"]?.requests.count, 2)
    }
    func testMCPFormsLinksAndVerificationAreGenericPromptsWithoutReadingPayloads() throws {
        for mode in ["form", "openai/form", "openaiForm", "url", "openai/userVerification"] {
            var observer = try observer()
            let event = try XCTUnwrap(observer.observe(try json(["id": "prompt", "method": "mcpServer/elicitation/request", "params": [
                "threadId": "s", "turnId": NSNull(), "mode": mode, "message": "SECRET_MESSAGE", "url": "https://invalid.example/SECRET", "challenge": "SECRET_CHALLENGE", "requestedSchema": ["SECRET": "SECRET"]]]), from: .server).first)
            XCTAssertEqual(event.kind, .questionQueued); XCTAssertEqual(event.questionIDs.count, 1)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(event), as: UTF8.self).contains("SECRET"))
            let clear = observer.observe(try json(["method": "serverRequest/resolved", "params": ["threadId": "s", "requestId": "prompt"]]), from: .server)
            XCTAssertEqual(clear.first?.questionIDs, event.questionIDs)
        }
    }
    func testTypedAndOwnedRequestResolutionCannotClearSiblingOrRetiredInput() throws {
        var observer = try observer()
        let first = try XCTUnwrap(observer.observe(try json(["id": 9, "method": "item/tool/requestUserInput", "params": input()]), from: .server).first)
        let other = try XCTUnwrap(observer.observe(try json(["id": "9", "method": "item/tool/requestUserInput", "params": input()]), from: .server).first)
        XCTAssertNotEqual(first.questionIDs, other.questionIDs)
        XCTAssertTrue(observer.observe(try json(["method": "serverRequest/resolved", "params": ["threadId": "wrong", "requestId": 9]]), from: .server).isEmpty)
        _ = observer.observe(try json(["method": "thread/unsubscribe", "params": ["threadId": "s"]]), from: .client)
        XCTAssertTrue(observer.observe(try json(["method": "serverRequest/resolved", "params": ["threadId": "s", "requestId": 9]]), from: .server).isEmpty)
    }
    func testCoverageNoticePreservesExecutionAndRequestsWithoutInventingBannerOrHumanWait() throws {
        var observer = try observer(); var state = RouterState()
        try state.apply(.init(kind: .sessionStarted, sessionID: "s", protocolBinding: binding(), executionObservation: .running, timestamp: now, source: "codex-protocol"))
        let notice = try XCTUnwrap(observer.observe(try json(["id": 7, "method": "SECRET_UNKNOWN_METHOD", "params": ["threadId": "s", "body": "SECRET_BODY"]]), from: .server, now: now).first)
        XCTAssertEqual(notice.kind, .activity); XCTAssertEqual(notice.coverageIssue, .unsupportedRequest)
        try state.apply(notice)
        XCTAssertEqual(state.sessions["s"]?.execution, .running)
        XCTAssertTrue(state.sessions["s"]!.requests.isEmpty); XCTAssertTrue(state.sessions["s"]!.needsAttention)
        XCTAssertNil(NotificationPolicy.plan(event: notice, session: state.sessions["s"]!, sourceInstance: binding().reference, submitted: [:], now: now))
        XCTAssertTrue((state.pendingNotifications ?? [:]).isEmpty)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(state), as: UTF8.self).contains("SECRET"))
        state.markReviewed("s")
        XCTAssertFalse(state.sessions["s"]!.needsAttention)
        XCTAssertNotNil(state.sessions["s"]?.protocolCoverageNotice)
        XCTAssertFalse(try state.apply(notice))
        XCTAssertEqual(state.sessions["s"]?.protocolCoverageNotice?.reviewed, true)
        XCTAssertTrue(observer.observe(try json(["id": 8, "method": "another-unknown", "params": ["threadId": "s"]]), from: .server).isEmpty)
    }
    func testUnsupportedInputShapesAreNotSilentlyDroppedOrGuessedAsQuestions() throws {
        var malformed = [input(false)]
        var duplicate = input(); duplicate["questions"] = [["id": "same"], ["id": "same"]]; malformed.append(duplicate)
        var numeric = input(); numeric["isBlocking"] = 1; malformed.append(numeric)
        var missingTurn = input(); missingTurn.removeValue(forKey: "turnId"); malformed.append(missingTurn)
        var tooMany = input(); tooMany["questions"] = (0..<65).map { ["id": String($0)] }; malformed.append(tooMany)
        for params in malformed {
            var observer = try observer()
            let events = observer.observe(try json(["id": 4, "method": "item/tool/requestUserInput", "params": params]), from: .server)
            XCTAssertEqual(events.first?.coverageIssue, .unsupportedInput)
            XCTAssertFalse(events.contains { $0.kind == .questionQueued || $0.kind == .humanApprovalPending })
        }
    }
    func testKnownAutomaticServerRequestsStayQuietInScopedAndGlobalForms() throws {
        for method in ["item/tool/call", "account/chatgptAuthTokens/refresh", "attestation/generate", "currentTime/read"] {
            var observer = try observer()
            for params: [String: Any] in [[:], ["threadId": "s"]] {
                XCTAssertTrue(observer.observe(try json(["id": 4, "method": method, "params": params]), from: .server).isEmpty)
            }
            XCTAssertEqual(observer.coverageNoticeCount, 0)
        }
    }
    func testUnscopedAndLegacyRequestsOnlyWarnAlreadyRegisteredSources() throws {
        var empty = CodexProtocolObserver(binding: binding(), project: "sample")
        XCTAssertTrue(empty.observe(try json(["id": 1, "method": "future/request", "params": [:]]), from: .server).isEmpty)
        var observer = try observer()
        let unscoped = try XCTUnwrap(observer.observe(try json(["id": 2, "method": "future/request", "params": [:]]), from: .server).first)
        XCTAssertEqual(unscoped.sessionID, "s"); XCTAssertEqual(unscoped.coverageIssue, .unscopedRequest)
        XCTAssertTrue(unscoped.questionIDs.isEmpty)
        let legacy = observer.observe(try json(["id": 3, "method": "execCommandApproval", "params": ["conversationId": "s", "command": "SECRET"]]), from: .server)
        XCTAssertEqual(legacy.first?.coverageIssue, .unsupportedRequest)
        XCTAssertFalse(legacy.contains { $0.kind == .approvalRequested })
    }
    func testRequestLimitPreservesTrackedInputsAndRecoversAfterExactClear() throws {
        var observer = try observer()
        let params: [String: Any] = ["threadId": "s", "mode": "form"]
        for index in 0..<512 {
            XCTAssertEqual(observer.observe(try json(["id": index, "method": "mcpServer/elicitation/request", "params": params]), from: .server).first?.kind, .questionQueued)
        }
        XCTAssertEqual(observer.observe(try json(["id": 512, "method": "mcpServer/elicitation/request", "params": params]), from: .server).first?.coverageIssue, .requestLimit)
        XCTAssertEqual(observer.observe(try json(["method": "serverRequest/resolved", "params": ["threadId": "s", "requestId": 0]]), from: .server).first?.kind, .requestResolved)
        XCTAssertEqual(observer.observe(try json(["id": 512, "method": "mcpServer/elicitation/request", "params": params]), from: .server).first?.kind, .questionQueued)
    }
    func testCoverageMetadataValidationAndReviewCannotResolveQuestions() throws {
        var observer = try observer()
        var notice = try XCTUnwrap(observer.observe(try json(["id": 5, "method": "future/request", "params": ["threadId": "s"]]), from: .server, now: now).first)
        XCTAssertNoThrow(try notice.validate())
        var invalid = notice; invalid.source = "codex-hook"; XCTAssertThrowsError(try invalid.validate())
        invalid = notice; invalid.protocolBinding = nil; XCTAssertThrowsError(try invalid.validate())
        invalid = notice; invalid.id = "arbitrary"; XCTAssertThrowsError(try invalid.validate())
        var state = RouterState()
        try state.apply(.init(kind: .questionQueued, sessionID: "s", questionIDs: ["q"], protocolBinding: binding(), timestamp: now, source: "codex-protocol"))
        try state.apply(notice); state.markReviewed("s")
        XCTAssertEqual(state.sessions["s"]?.requests["q"]?.evidence, .observed)
        let decoded = try JSONDecoder().decode(RouterState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.sessions["s"]?.protocolCoverageNotice?.reviewed, true)
        notice.timestamp = now.addingTimeInterval(1)
        XCTAssertFalse(try state.apply(notice))
    }
    func testFreshSubscriptionCanReportCoverageAgainWithoutRevivingRetiredSource() throws {
        var observer = try observer()
        let first = try XCTUnwrap(observer.observe(try json(["id": 5, "method": "future/request", "params": ["threadId": "s"]]), from: .server).first)
        _ = observer.observe(try json(["method": "thread/unsubscribe", "params": ["threadId": "s"]]), from: .client)
        _ = observer.observe(try json(["id": 8, "method": "thread/resume", "params": ["threadId": "s"]]), from: .client)
        _ = observer.observe(try json(["id": 8, "result": ["thread": ["id": "s"]]]), from: .server)
        let next = try XCTUnwrap(observer.observe(try json(["id": 9, "method": "future/request", "params": ["threadId": "s"]]), from: .server).first)
        XCTAssertNotEqual(first.id, next.id)
        XCTAssertNotEqual(first.protocolBinding?.reference, next.protocolBinding?.reference)
    }
    func testMalformedAsyncQuestionItemsWarnWithoutGuessingQuestionCount() throws {
        for questions: Any in ["invalid", (0..<65).map { _ in [String: String]() }] {
            var observer = try observer()
            let events = observer.observe(try json(["method": "item/completed", "params": ["threadId": "s", "item": ["type": "agentMessage", "id": "call", "questions": questions]]]), from: .server)
            XCTAssertEqual(events.first?.coverageIssue, .unsupportedInput)
            XCTAssertFalse(events.contains { $0.kind == .questionQueued })
        }
    }
    func testConflictingRPCRolesCannotOverwriteAnAlreadyTrackedRequest() throws {
        var observer = try observer()
        let queued = try XCTUnwrap(observer.observe(try json(["id": 5, "method": "item/tool/requestUserInput", "params": input()]), from: .server).first)
        let collision = observer.observe(try json(["id": 5, "method": "item/permissions/requestApproval", "params": ["threadId": "s"]]), from: .server)
        XCTAssertEqual(collision.first?.coverageIssue, .unsupportedInput)
        XCTAssertFalse(collision.contains { $0.kind == .approvalRequested })
        let resolved = observer.observe(try json(["method": "serverRequest/resolved", "params": ["threadId": "s", "requestId": 5]]), from: .server)
        XCTAssertEqual(resolved.first?.questionIDs, queued.questionIDs)
    }
}

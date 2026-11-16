import XCTest
@testable import AttentionCore

final class NotificationDeliveryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func question(_ ids: [String] = ["q1"], id: String = "event", at: Date? = nil) -> AgentEvent {
        let process = ProcessOriginHint(pid: 500, uid: 501, startMicroseconds: 10, processGroup: 500,
            terminalGroup: 500, terminalDevice: 20, hasControllingTerminal: true, isCodex: true, capturedAt: now)
        let binding = ProtocolOriginBinding(id: "connection", origin: .init(
            terminal: .init(sessionID: "12345678-1234-1234-1234-123456789ABC"), process: process))
        return .init(id: id, kind: .questionQueued, sessionID: "s", questionIDs: ids,
            protocolBinding: binding, timestamp: at ?? now, source: "codex-protocol")
    }
    func store() throws -> LocalStore {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("aar-delivery-test-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try LocalStore(root: root)
    }
    func queuedIDs(_ state: RouterState) throws -> Set<String> {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        return Set((json["pendingNotifications"] as? [String: Any] ?? [:]).keys)
    }
    func testCrashAfterSnapshotAndInboxAcknowledgementRetainsNotificationIntent() throws {
        let store = try store(), event = question()
        try store.enqueue(event)
        var state = try store.load()
        let (file, value) = try XCTUnwrap(store.pending().first)
        try state.apply(value); try store.save(state); try store.acknowledge(file)
        // Restart after the event committed but before any native submission.
        let restored = try store.load()
        XCTAssertTrue(try store.pending().isEmpty)
        XCTAssertFalse(try { var replay = restored; return try replay.apply(event) }())
        XCTAssertEqual(try queuedIDs(restored), [event.id])
        XCTAssertEqual(restored.sessions["s"]?.requests["q1"]?.evidence, .observed)
    }
    func testCrashBeforeInboxAcknowledgementDoesNotDuplicateNotificationIntent() throws {
        let store = try store(), event = question()
        try store.enqueue(event)
        var state = RouterState(); try state.apply(event); try store.save(state)
        var restored = try store.load()
        let (file, replay) = try XCTUnwrap(store.pending().first)
        XCTAssertFalse(try restored.apply(replay)); try store.acknowledge(file)
        XCTAssertEqual(try queuedIDs(restored), [event.id])
    }
    enum Failure: Error { case injected }

    func testAcknowledgementFailureStillCommitsIntentAndReplayIsHarmless() throws {
        let store = try store(), event = question()
        try store.enqueue(event)
        let result = try InboxConsumer.consume(RouterState(), events: store.pending(), now: now,
            save: store.save, acknowledge: { _ in throw Failure.injected })
        XCTAssertEqual(result.acknowledgementFailures, 1)
        XCTAssertEqual(try queuedIDs(store.load()), [event.id])
        XCTAssertEqual(NotificationDelivery().due(in: result.state, now: now), [event])
        let replay = try InboxConsumer.consume(store.load(), events: store.pending(), now: now,
            save: store.save, acknowledge: store.acknowledge)
        XCTAssertEqual(try queuedIDs(replay.state), [event.id])
        XCTAssertTrue(try store.pending().isEmpty)
    }
    func testSnapshotFailureCannotAcknowledgeOrAdvanceTheBatch() throws {
        let store = try store(), event = question()
        try store.enqueue(event)
        var acknowledged = false
        XCTAssertThrowsError(try InboxConsumer.consume(RouterState(), events: store.pending(), now: now,
            save: { _ in throw Failure.injected }, acknowledge: { _ in acknowledged = true }))
        XCTAssertFalse(acknowledged)
        XCTAssertTrue(try store.load().processed.isEmpty)
        XCTAssertEqual(try store.pending().map { $0.1.id }, [event.id])
    }
    func testNativeFailureAndRestartHonorPersistedBackoffThenAcceptAtomically() throws {
        let store = try store(), event = question(), delivery = NotificationDelivery()
        var state = RouterState(); try state.apply(event)
        let plan = try XCTUnwrap(delivery.prepare(event, sourceInstance: event.protocolBinding?.reference,
            in: &state, now: now, save: store.save))
        try delivery.complete(plan, accepted: false, in: &state, now: now, save: store.save)
        let restarted = NotificationDelivery(); state = try store.load()
        XCTAssertTrue(restarted.due(in: state, now: now.addingTimeInterval(29)).isEmpty)
        XCTAssertNil(try restarted.prepare(event, sourceInstance: event.protocolBinding?.reference,
            in: &state, now: now.addingTimeInterval(29), save: store.save))
        let retry = try XCTUnwrap(restarted.prepare(event, sourceInstance: event.protocolBinding?.reference,
            in: &state, now: now.addingTimeInterval(30), save: store.save))
        XCTAssertEqual(retry.identifier, plan.identifier)
        XCTAssertEqual(state.pendingNotifications?[event.id]?.attempts, 2)
        try restarted.complete(retry, accepted: true, in: &state, now: now.addingTimeInterval(30), save: store.save)
        state = try store.load()
        XCTAssertTrue(state.pendingNotifications?.isEmpty == true)
        XCTAssertEqual(Set(state.notificationReceipts?.keys.map { $0 } ?? []), Set(plan.receiptIDs))
        XCTAssertEqual(state.sessions["s"]?.requests["q1"]?.evidence, .observed)
        XCTAssertFalse(state.sessions["s"]?.requests["q1"]?.reviewed ?? true)
    }
    func testAcceptedNativeSubmissionWithReceiptSaveFailureRetriesSavingNotSubmission() throws {
        let store = try store(), event = question(), delivery = NotificationDelivery()
        var state = RouterState(); try state.apply(event)
        let plan = try XCTUnwrap(delivery.prepare(event, sourceInstance: event.protocolBinding?.reference,
            in: &state, now: now, save: store.save))
        XCTAssertThrowsError(try delivery.complete(plan, accepted: true, in: &state, now: now,
            save: { _ in throw Failure.injected }))
        XCTAssertTrue(delivery.due(in: state, now: now.addingTimeInterval(60)).isEmpty)
        XCTAssertNil(try delivery.prepare(event, sourceInstance: event.protocolBinding?.reference,
            in: &state, now: now.addingTimeInterval(60), save: store.save))
        try delivery.flush(in: &state, save: store.save)
        let restored = try store.load()
        XCTAssertTrue(restored.pendingNotifications?.isEmpty == true)
        XCTAssertEqual(restored.notificationReceipts?.count, 1)
        // An accidental duplicate completion cannot undo a later state.
        try delivery.complete(plan, accepted: false, in: &state, now: now, save: store.save)
        XCTAssertEqual(state, restored)
    }
    func testReservationSaveFailureNeverMakesANativePlanOrLeaksAnInFlightReservation() throws {
        let event = question(), delivery = NotificationDelivery()
        var state = RouterState(); try state.apply(event)
        let original = state
        XCTAssertThrowsError(try delivery.prepare(event, sourceInstance: event.protocolBinding?.reference,
            in: &state, now: now, save: { _ in throw Failure.injected }))
        XCTAssertEqual(state, original)
        XCTAssertEqual(delivery.due(in: state, now: now), [event])
        XCTAssertNotNil(try delivery.prepare(event, sourceInstance: event.protocolBinding?.reference,
            in: &state, now: now, save: { _ in }))
    }
    func testRetiredSourceCannotRebindAPendingNotificationToAResumedConnection() throws {
        let event = question()
        var state = RouterState(); try state.apply(event)
        let originalQueue = state.pendingNotifications
        try state.apply(.init(kind: .sourceLost, sessionID: "s", protocolBinding: event.protocolBinding,
            timestamp: now.addingTimeInterval(1), source: "codex-protocol"))
        XCTAssertTrue(state.pendingNotifications?.isEmpty == true)
        let fresh = ProtocolOriginBinding(id: "resumed", origin: event.protocolBinding!.origin)
        try state.apply(.init(kind: .sessionStarted, sessionID: "s", protocolBinding: fresh,
            timestamp: now.addingTimeInterval(2), source: "codex-protocol"))
        // Even a retained pre-retirement intent cannot use the new reference.
        state.pendingNotifications = originalQueue
        XCTAssertNil(try NotificationDelivery().prepare(event, sourceInstance: fresh.reference,
            in: &state, now: now.addingTimeInterval(3), save: { _ in XCTFail("Stale source must not write a reservation") }))
        NotificationOutbox.prune(in: &state, now: now.addingTimeInterval(3))
        XCTAssertTrue(state.pendingNotifications?.isEmpty == true)
    }
    func testResolvedSubmittedAndExpiredQuestionsStayQuietWithoutInventingResolution() throws {
        let event = question(["q1", "q2"])
        var state = RouterState(); try state.apply(event)
        try state.apply(.init(kind: .inputSubmitted, sessionID: "s", questionIDs: ["q1"],
            protocolBinding: event.protocolBinding, timestamp: now.addingTimeInterval(1), source: "codex-protocol"))
        let delivery = NotificationDelivery()
        let plan = try XCTUnwrap(delivery.prepare(event, sourceInstance: event.protocolBinding?.reference,
            in: &state, now: now.addingTimeInterval(2), save: { _ in }))
        XCTAssertEqual(plan.questionCount, 1)
        XCTAssertEqual(state.sessions["s"]?.requests["q1"]?.evidence, .unknown)
        try state.apply(.init(kind: .requestResolved, sessionID: "s", questionIDs: ["q2"],
            protocolBinding: event.protocolBinding, timestamp: now.addingTimeInterval(3), source: "codex-protocol"))
        XCTAssertTrue(state.pendingNotifications?.isEmpty == true)

        var expired = RouterState(); try expired.apply(event)
        NotificationOutbox.prune(in: &expired, now: now.addingTimeInterval(121))
        XCTAssertTrue(expired.pendingNotifications?.isEmpty == true)
        XCTAssertEqual(expired.sessions["s"]?.outstanding.count, 2)
        XCTAssertEqual(expired.sessions["s"]?.requests["q2"]?.evidence, .observed)
    }
    func testPartialReplayQueuesOnlyNewQuestionIDsAndDoesNotDoubleReserve() throws {
        var state = RouterState()
        let first = question(["q1", "q2"]), second = question(["q2", "q3"], id: "second")
        try state.apply(first); try state.apply(second)
        XCTAssertEqual(Set(state.pendingNotifications?[second.id]?.event.questionIDs ?? []), ["q3"])
        let delivery = NotificationDelivery()
        XCTAssertNotNil(try delivery.prepare(first, sourceInstance: first.protocolBinding?.reference,
            in: &state, now: now, save: { _ in }))
        XCTAssertNil(try delivery.prepare(first, sourceInstance: first.protocolBinding?.reference,
            in: &state, now: now, save: { _ in XCTFail("Duplicate in-flight submission") }))
    }
    func testDisabledNotificationsDiscardIntentsWithoutChangingRequestsAndLegacyStateStillLoads() throws {
        let store = try store(), event = question()
        try store.enqueue(event)
        let result = try InboxConsumer.consume(RouterState(), events: store.pending(), now: now,
            notificationsEnabled: false, save: store.save, acknowledge: store.acknowledge)
        XCTAssertTrue(result.state.pendingNotifications?.isEmpty == true)
        XCTAssertEqual(result.state.sessions["s"]?.outstanding.count, 1)
        let old = Data(#"{"schema":1,"sessions":{},"processed":[]}"#.utf8)
        let legacy = try JSONDecoder().decode(RouterState.self, from: old)
        XCTAssertNil(legacy.pendingNotifications)
        XCTAssertEqual(legacy.schema, 1)
    }
    func testLateNativeAcceptanceCannotRestoreRetiredSourceOrClearNewerQuestions() throws {
        let first = question(), delivery = NotificationDelivery()
        var state = RouterState(); try state.apply(first)
        let plan = try XCTUnwrap(delivery.prepare(first, sourceInstance: first.protocolBinding?.reference,
            in: &state, now: now, save: { _ in }))
        try state.apply(.init(kind: .sourceLost, sessionID: "s", protocolBinding: first.protocolBinding,
            timestamp: now.addingTimeInterval(1), source: "codex-protocol"))
        var later = question(["q2"], id: "new-question", at: now.addingTimeInterval(2))
        later.protocolBinding = ProtocolOriginBinding(id: "fresh-connection", origin: first.protocolBinding!.origin)
        try state.apply(later)
        try delivery.complete(plan, accepted: true, in: &state, now: now.addingTimeInterval(3), save: { _ in })
        XCTAssertEqual(state.sessions["s"]?.verifiedProtocolBinding, later.protocolBinding)
        XCTAssertEqual(state.sessions["s"]?.protocolBindings?["connection"]?.connected, false)
        XCTAssertEqual(state.sessions["s"]?.requests["q1"]?.evidence, .unknown)
        XCTAssertEqual(state.sessions["s"]?.requests["q2"]?.evidence, .observed)
        XCTAssertEqual(try queuedIDs(state), [later.id])
    }
    func testNewTurnOrReviewSuppressesRetriedStopWithoutResolvingQuestions() throws {
        let event = question()
        let stop = AgentEvent(id: "stop", kind: .turnStopped, sessionID: "s", turnID: "t",
            protocolBinding: event.protocolBinding, timestamp: now.addingTimeInterval(1), source: "codex-protocol")
        var state = RouterState(); try state.apply(event); try state.apply(stop)
        XCTAssertEqual(try queuedIDs(state), [stop.id])
        var reviewed = state
        reviewed.markReviewed("s")
        NotificationOutbox.prune(in: &reviewed, now: now.addingTimeInterval(2))
        XCTAssertTrue(reviewed.pendingNotifications?.isEmpty == true)
        XCTAssertEqual(reviewed.sessions["s"]?.requests["q1"]?.evidence, .unknown)
        try state.apply(.init(kind: .turnStarted, sessionID: "s", turnID: "next",
            protocolBinding: event.protocolBinding, timestamp: now.addingTimeInterval(2), source: "codex-protocol"))
        XCTAssertTrue(state.pendingNotifications?.isEmpty == true)
        XCTAssertEqual(state.sessions["s"]?.execution, .running)
    }
    func testAllowedFutureClockSkewDoesNotDeferTheFirstSubmissionUntilMaintenance() throws {
        let event = question(at: now.addingTimeInterval(3)), delivery = NotificationDelivery()
        var state = RouterState(); try state.apply(event)
        XCTAssertEqual(delivery.due(in: state, now: now), [event])
        XCTAssertNotNil(try delivery.prepare(event, sourceInstance: event.protocolBinding?.reference,
            in: &state, now: now, save: { _ in }))
    }
    func testAnotherSessionsFutureEventCannotExpireCommittedIntent() throws {
        let event = question()
        var state = RouterState(); try state.apply(event)
        try state.apply(.init(kind: .activity, sessionID: "other", timestamp: now.addingTimeInterval(3_600)))
        XCTAssertEqual(try queuedIDs(state), [event.id])
        NotificationOutbox.prune(in: &state, now: now)
        XCTAssertEqual(try queuedIDs(state), [event.id])
    }
    func testHealthDistinguishesReservationFailureRetryAndNativeAcceptance() throws {
        let event = question(), delivery = NotificationDelivery()
        var state = RouterState(); try state.apply(event)
        XCTAssertEqual(delivery.health(in: state, now: now).waiting, 1)
        let plan = try XCTUnwrap(delivery.prepare(event, sourceInstance: event.protocolBinding?.reference,
            in: &state, now: now, save: { _ in }))
        var h = delivery.health(in: state, now: now)
        XCTAssertEqual(h.submitting, 1); XCTAssertNil(h.lastSubmission)
        try delivery.complete(plan, accepted: false, in: &state, now: now, save: { _ in })
        h = delivery.health(in: state, now: now)
        XCTAssertEqual(h.submitting, 0); XCTAssertEqual(h.retrying, 1)
        XCTAssertEqual(h.nextRetryAt, now.addingTimeInterval(30))
        XCTAssertEqual(h.lastSubmission?.outcome, .failed)
        // A restart does not pretend its predecessor's native callback occurred here.
        XCTAssertNil(NotificationDelivery().health(in: state, now: now).lastSubmission)
        let retry = try XCTUnwrap(delivery.prepare(event, sourceInstance: event.protocolBinding?.reference,
            in: &state, now: now.addingTimeInterval(30), save: { _ in }))
        try delivery.complete(retry, accepted: true, in: &state, now: now.addingTimeInterval(30), save: { _ in })
        h = delivery.health(in: state, now: now.addingTimeInterval(30))
        XCTAssertEqual(h.waiting + h.retrying + h.submitting + h.receiptsAwaitingSave, 0)
        XCTAssertEqual(h.lastSubmission?.outcome, .accepted)
        XCTAssertEqual(state.sessions["s"]?.requests["q1"]?.evidence, .observed)
    }
    func testHealthSeparatesAcceptedReceiptSaveFailureFromAnUnacceptedSubmission() throws {
        let event = question(), delivery = NotificationDelivery()
        var state = RouterState(); try state.apply(event)
        let plan = try XCTUnwrap(delivery.prepare(event, sourceInstance: event.protocolBinding?.reference,
            in: &state, now: now, save: { _ in }))
        XCTAssertThrowsError(try delivery.complete(plan, accepted: true, in: &state, now: now,
            save: { _ in throw Failure.injected }))
        var h = delivery.health(in: state, now: now)
        XCTAssertEqual(h.lastSubmission?.outcome, .accepted)
        XCTAssertEqual(h.lastSaveFailure?.stage, .receipt)
        XCTAssertEqual(h.receiptsAwaitingSave, 1); XCTAssertEqual(h.submitting, 0); XCTAssertEqual(h.retrying, 0)
        try delivery.flush(in: &state, now: now.addingTimeInterval(30), save: { _ in })
        h = delivery.health(in: state, now: now.addingTimeInterval(30))
        XCTAssertEqual(h.receiptsAwaitingSave, 0)
        XCTAssertEqual(h.lastSaveFailure?.stage, .receipt) // Explicitly labeled historical error.
    }
    func testHealthReservationErrorDoesNotInventNativeResultAndOmitsExpiredReminders() throws {
        let event = question(), delivery = NotificationDelivery()
        var state = RouterState(); try state.apply(event)
        XCTAssertThrowsError(try delivery.prepare(event, sourceInstance: event.protocolBinding?.reference,
            in: &state, now: now, save: { _ in throw Failure.injected }))
        let h = delivery.health(in: state, now: now)
        XCTAssertEqual(h.lastSaveFailure?.stage, .reservation)
        XCTAssertNil(h.lastSubmission); XCTAssertEqual(h.waiting, 1); XCTAssertEqual(h.submitting, 0)
        XCTAssertEqual(delivery.health(in: state, now: now.addingTimeInterval(121)).waiting, 0)
        let json = String(decoding: try JSONEncoder().encode(h), as: UTF8.self)
        XCTAssertFalse(json.contains(event.id)); XCTAssertFalse(json.contains("q1"))
    }
}

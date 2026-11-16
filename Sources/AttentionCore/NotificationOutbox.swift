import Foundation

/// Normalized metadata only. Intent is committed with the event's state change.
public struct PendingNotification: Codable, Equatable, Sendable {
    public var event: AgentEvent
    public var attempts: Int = 0
    public var nextAttemptAt: Date
}

public enum NotificationOutbox {
    // This is only a structural gate. The app must still probe the original OS
    // process before every submission; a later binding cannot authorize replay.
    static func source(_ event: AgentEvent, in state: RouterState) -> String? {
        guard let session = state.sessions[event.sessionID] else { return nil }
        if let binding = event.protocolBinding {
            return session.verifiedProtocolBinding == binding ? binding.reference : nil
        }
        guard let hint = event.processOriginHint, hint.isDirectForegroundCandidate,
              session.processOriginConflict != true,
              session.processOriginHint?.instanceID == hint.instanceID,
              event.terminal?.guid == session.terminal?.guid else { return nil }
        return hint.instanceID
    }
    static func plan(_ event: AgentEvent, in state: RouterState, submitted: [String: Date], now: Date) -> NotificationPlan? {
        guard let session = state.sessions[event.sessionID] else { return nil }
        return NotificationPolicy.plan(event: event, session: session,
            sourceInstance: source(event, in: state), submitted: submitted, now: now)
    }
    static func record(_ event: AgentEvent, in state: inout RouterState) {
        guard [.questionQueued, .approvalRequested, .humanApprovalPending, .turnStopped, .interrupted].contains(event.kind),
              state.pendingNotifications?[event.id] == nil else { return }
        var submitted = state.notificationReceipts ?? [:]
        for entry in (state.pendingNotifications ?? [:]).values {
            if let plan = plan(entry.event, in: state, submitted: state.notificationReceipts ?? [:], now: entry.event.timestamp) {
                for key in plan.receiptIDs { submitted[key] = event.timestamp }
            }
        }
        guard let plan = plan(event, in: state, submitted: submitted, now: event.timestamp) else { return }
        var candidate = event
        if event.kind == .questionQueued {
            // Partial replays queue only new IDs, without duplicating an earlier
            // outstanding intent for other questions in the same envelope.
            candidate.questionIDs = event.questionIDs.filter { id in
                var single = event; single.questionIDs = [id]
                return self.plan(single, in: state, submitted: submitted, now: event.timestamp) != nil
            }
        }
        guard !plan.receiptIDs.isEmpty else { return }
        state.pendingNotifications = state.pendingNotifications ?? [:]
        // First delivery is immediate even within the policy's five-second
        // future-clock tolerance. Only actual attempts acquire a retry deadline.
        state.pendingNotifications?[event.id] = .init(event: candidate, nextAttemptAt: .distantPast)
    }
    public static func prune(in state: inout RouterState, now: Date? = nil, enabled: Bool = true) {
        guard let entries = state.pendingNotifications else { return }
        // Applying an event invalidates intent by state, not by a different
        // producer's clock. Only the receiver's clock may expire other intents.
        state.pendingNotifications = enabled ? entries.filter {
            plan($0.value.event, in: state, submitted: state.notificationReceipts ?? [:], now: now ?? $0.value.event.timestamp) != nil
        } : [:]
    }
}

/// Commit state and outbox before removing inbox files. An acknowledgement
/// failure leaves a harmless replay; it must not suppress delivery of the batch.
public enum InboxConsumer {
    public struct Result {
        public let state: RouterState
        public let rejected: Int
        public let acknowledgementFailures: Int
    }
    public static func consume(_ state: RouterState, events: [(URL, AgentEvent)], rejected: Int = 0,
                               now: Date, notificationsEnabled: Bool = true,
                               save: (RouterState) throws -> Void,
                               acknowledge: (URL) throws -> Void) throws -> Result {
        var next = state, files: [URL] = [], invalid = rejected
        for (file, event) in events {
            do { try next.apply(event); files.append(file) }
            catch { invalid += 1 }
        }
        next.age(now: now)
        NotificationOutbox.prune(in: &next, now: now, enabled: notificationsEnabled)
        if next != state { try save(next) }
        var failures = 0
        for file in files {
            do { try acknowledge(file) }
            catch { failures += 1 }
        }
        return .init(state: next, rejected: invalid, acknowledgementFailures: failures)
    }
}

/// Main-actor owned by the app. Native API calls remain outside this type, so
/// crash/retry/receipt transitions can be tested without posting notifications.
public final class NotificationDelivery {
    private var inFlight: [String: NotificationPlan] = [:]
    private var accepted: [String: (NotificationPlan, Date)] = [:]
    private var lastSubmission: NotificationSubmissionObservation?
    private var lastSaveFailure: NotificationSaveFailure?
    public init() {}

    public func health(in state: RouterState, now: Date) -> NotificationDeliveryHealth {
        var health = NotificationDeliveryHealth()
        for entry in (state.pendingNotifications ?? [:]).values {
            guard inFlight[entry.event.id] == nil,
                  NotificationOutbox.plan(entry.event, in: state, submitted: state.notificationReceipts ?? [:], now: now) != nil else { continue }
            if entry.attempts == 0 { health.waiting += 1 }
            else {
                health.retrying += 1
                health.nextRetryAt = min(health.nextRetryAt ?? entry.nextAttemptAt, entry.nextAttemptAt)
            }
        }
        health.submitting = inFlight.count - accepted.count
        health.receiptsAwaitingSave = accepted.count
        health.lastSubmission = lastSubmission; health.lastSaveFailure = lastSaveFailure
        return health
    }

    public func due(in state: RouterState, now: Date) -> [AgentEvent] {
        (state.pendingNotifications ?? [:]).values.filter {
            $0.nextAttemptAt <= now && inFlight[$0.event.id] == nil
        }.sorted {
            $0.event.timestamp == $1.event.timestamp ? $0.event.id < $1.event.id : $0.event.timestamp < $1.event.timestamp
        }.map(\.event)
    }
    public func prepare(_ event: AgentEvent, sourceInstance: String?, in state: inout RouterState,
                        now: Date, save: (RouterState) throws -> Void) throws -> NotificationPlan? {
        guard var entry = state.pendingNotifications?[event.id], entry.event == event,
              entry.nextAttemptAt <= now, inFlight[event.id] == nil,
              let sourceInstance, sourceInstance == NotificationOutbox.source(event, in: state) else { return nil }
        var receipts = state.notificationReceipts ?? [:]
        for flight in inFlight.values { for key in flight.receiptIDs { receipts[key] = now } }
        guard let plan = NotificationOutbox.plan(event, in: state, submitted: receipts, now: now) else { return nil }
        var next = state
        entry.attempts = min(entry.attempts, 10) + 1
        entry.nextAttemptAt = now.addingTimeInterval(entry.attempts == 1 ? 30 : 60)
        next.pendingNotifications?[event.id] = entry
        // Persist a retry deadline before calling macOS. Restart cannot bypass it.
        do { try save(next) }
        catch { lastSaveFailure = .init(stage: .reservation, recordedAt: now); throw error }
        state = next; inFlight[event.id] = plan
        return plan
    }
    public func complete(_ plan: NotificationPlan, accepted: Bool, in state: inout RouterState,
                         now: Date, save: (RouterState) throws -> Void) throws {
        guard inFlight[plan.eventID] == plan, self.accepted[plan.eventID] == nil else { return }
        lastSubmission = .init(outcome: accepted ? .accepted : .failed, recordedAt: now)
        guard accepted else { inFlight[plan.eventID] = nil; return }
        self.accepted[plan.eventID] = (plan, now)
        try flush(in: &state, now: now, save: save)
    }
    public func flush(in state: inout RouterState, now: Date = Date(), save: (RouterState) throws -> Void) throws {
        guard !accepted.isEmpty else { return }
        var next = state
        for (id, (plan, time)) in accepted {
            next.notificationReceipts = NotificationPolicy.recordSubmission(plan, in: next.notificationReceipts ?? [:], now: time)
            next.pendingNotifications?[id] = nil
        }
        // On a failed save keep accepted plans in flight: retry persistence,
        // rather than resubmitting the same notification in this process.
        do { try save(next) }
        catch {
            lastSaveFailure = .init(stage: .receipt, recordedAt: now)
            throw error
        }
        state = next
        for id in accepted.keys { inFlight[id] = nil }
        accepted.removeAll()
    }
}

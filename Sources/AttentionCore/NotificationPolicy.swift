import Foundation

public struct NotificationPlan: Equatable, Sendable {
    public let eventID: String
    public let identifier: String
    public let receiptIDs: [String]
    public let kind: EventKind
    public let questionCount: Int
    public let sourceInstance: String
}

/// A banner requires a verified source and fresh actionable evidence.
/// Quiet observations remain in the state engine; this never resolves a request.
public enum NotificationPolicy {
    public static func plan(event: AgentEvent, session: AgentSession,
                            sourceInstance: String?, submitted: [String: Date],
                            now: Date = Date(), maximumAge: TimeInterval = 120) -> NotificationPlan? {
        guard let sourceInstance, event.sessionID == session.id,
              session.execution != .ended,
              now.timeIntervalSince(event.timestamp) >= -5,
              now.timeIntervalSince(event.timestamp) <= maximumAge else { return nil }
        func key(_ parts: [String]) -> String {
            // JSON framing avoids collisions between arbitrary identifier components.
            StableDigest.hex((try? JSONEncoder().encode(parts)) ?? Data())
        }
        var keys: [String] = []
        switch event.kind {
        case .approvalRequested:
            guard event.source == "codex-protocol", event.protocolBinding != nil,
                  let id = event.requestID, let request = session.requests[id],
                  request.kind == .approval, request.evidence == .observed else { return nil }
            keys = [key(["approval-delivered", session.id, id])]
        case .questionQueued:
            for id in Set(event.questionIDs).sorted() {
                guard let request = session.requests[id], request.kind == .question, request.answerSubmittedAt == nil,
                      request.evidence == .observed || request.evidence == .confirmed else { continue }
                keys.append(key(["question", session.id, id]))
            }
        case .humanApprovalPending:
            guard event.source == "codex-protocol", let id = event.requestID,
                  let request = session.requests[id], request.kind == .approval,
                  request.evidence == .confirmed else { return nil }
            keys = [key(["human-approval", session.id, id])]
        case .turnStopped:
            guard session.execution == .idle, session.completionAt == event.timestamp,
                  !session.completionReviewed else { return nil }
            keys = [key(["turn-stopped", session.id, event.turnID ?? event.id])]
        case .interrupted:
            guard session.execution == .interrupted, session.executionAt == event.timestamp else { return nil }
            keys = [key(["interrupted", session.id, event.turnID ?? event.id])]
        default:
            // Hook PermissionRequest is early evidence, including automatic review.
            // A delivered protocol request stays explicitly unconfirmed too.
            return nil
        }
        keys = keys.filter { submitted[$0] == nil }
        guard !keys.isEmpty else { return nil }
        return NotificationPlan(eventID: event.id, identifier: "aar-" + key(keys), receiptIDs: keys, kind: event.kind,
            questionCount: event.kind == .questionQueued ? keys.count : 0, sourceInstance: sourceInstance)
    }

    /// macOS accepted the submission; this is not proof of delivery or review.
    public static func recordSubmission(_ plan: NotificationPlan, in receipts: [String: Date],
                                        now: Date = Date(), limit: Int = 2_000) -> [String: Date] {
        var result = receipts.filter { now.timeIntervalSince($0.value) <= 30 * 86_400 }
        for key in plan.receiptIDs { result[key] = now }
        return Dictionary(uniqueKeysWithValues: result.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.prefix(max(0, limit)).map { ($0.key, $0.value) })
    }
}

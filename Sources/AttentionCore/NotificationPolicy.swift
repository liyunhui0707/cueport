import Foundation

public struct NotificationPlan: Equatable, Sendable {
    public let eventID: String
    public let identifier: String
    public let receiptIDs: [String]
    public let reviewKeys: [String]
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
        var reviewKeys: [String] = []
        func include(_ receipt: String, review: String? = nil) {
            guard submitted[receipt] == nil else { return }
            keys.append(receipt)
            if let review { reviewKeys.append(review) }
        }
        switch event.kind {
        case .approvalRequested:
            guard event.source == "codex-protocol", event.protocolBinding != nil,
                  let id = event.requestID, let request = session.requests[id],
                  request.kind == .approval, request.evidence == .observed else { return nil }
            include(key(["approval-delivered", session.id, id]), review: reviewKey(session.id, request))
        case .questionQueued:
            for id in Set(event.questionIDs).sorted() {
                guard let request = session.requests[id], request.kind == .question, request.answerSubmittedAt == nil,
                      request.evidence == .observed || request.evidence == .confirmed else { continue }
                include(key(["question", session.id, id]), review: reviewKey(session.id, request))
            }
        case .humanApprovalPending:
            guard event.source == "codex-protocol", let id = event.requestID,
                  let request = session.requests[id], request.kind == .approval,
                  request.evidence == .confirmed else { return nil }
            include(key(["human-approval", session.id, id]), review: reviewKey(session.id, request))
        case .turnStopped:
            guard session.execution == .idle, session.completionAt == event.timestamp, session.turnID == event.turnID,
                  !session.completionReviewed else { return nil }
            include(key(["turn-stopped", session.id, event.turnID ?? event.id]),
                    review: completionKey(session.id, event.timestamp, turnID: event.turnID))
        case .interrupted:
            guard session.execution == .interrupted, session.executionAt == event.timestamp else { return nil }
            include(key(["interrupted", session.id, event.turnID ?? event.id]))
        default:
            // Hook PermissionRequest is early evidence, including automatic review.
            // A delivered protocol request stays explicitly unconfirmed too.
            return nil
        }
        guard !keys.isEmpty else { return nil }
        return NotificationPlan(eventID: event.id, identifier: "aar-" + key(keys), receiptIDs: keys, reviewKeys: reviewKeys, kind: event.kind,
            questionCount: event.kind == .questionQueued ? keys.count : 0, sourceInstance: sourceInstance)
    }

    // An old banner can only review the state it advertised, even after restart.
    static func reviewKey(_ session: String, _ request: AttentionRequest) -> String {
        versionKey([session, request.kind.rawValue, request.id, request.evidence.rawValue] + [request.turnID].compactMap { $0 }, request.updatedAt)
    }
    static func completionKey(_ session: String, _ date: Date, turnID: String?) -> String {
        versionKey([session, "completion"] + [turnID].compactMap { $0 }, date)
    }
    private static func versionKey(_ fields: [String], _ date: Date) -> String {
        StableDigest.hex((try? JSONEncoder().encode(fields + [String(date.timeIntervalSinceReferenceDate.bitPattern)])) ?? Data())
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

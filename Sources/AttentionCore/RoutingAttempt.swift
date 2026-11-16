import Foundation

/// Bounded local routing diagnostics. No notification text, paths or input.
public struct RoutingAttempt: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case missingReference, refused, sourceChanged, dispatchFailed, dispatched
    }
    public let timestamp: Date
    public let sessionKey: String
    public let displayReference: String
    public let requestedSourceKey: String?
    public let currentSourceKey: String?
    public let notificationClick: Bool
    public let outcome: Outcome
    public init(sessionID: String, requestedSource: String?, currentSource: String?,
                notificationClick: Bool, outcome: Outcome, timestamp: Date = Date()) {
        self.timestamp = timestamp
        sessionKey = StableDigest.hex(Data(sessionID.utf8))
        displayReference = sessionID.count > 12 ? String(sessionID.prefix(4)) + "…" + String(sessionID.suffix(6)) : sessionKey.prefix(10).description
        requestedSourceKey = requestedSource.map { StableDigest.hex(Data($0.utf8)) }
        currentSourceKey = currentSource.map { StableDigest.hex(Data($0.utf8)) }
        self.notificationClick = notificationClick; self.outcome = outcome
    }
}

public enum ProtocolRoute {
    public static func authorize(_ session: AgentSession, reference: String?) throws -> ProtocolOriginBinding {
        guard let binding = session.verifiedProtocolBinding,
              reference.map({ $0 == binding.reference }) ?? true else { throw RouterError.unverifiedOrigin }
        return binding
    }
}

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
    public let elapsedMilliseconds: Double?
    public init(sessionID: String, requestedSource: String?, currentSource: String?,
                notificationClick: Bool, outcome: Outcome, timestamp: Date = Date(), elapsedMilliseconds: Double? = nil) {
        self.timestamp = timestamp
        sessionKey = StableDigest.hex(Data(sessionID.utf8))
        displayReference = sessionID.count > 12 ? String(sessionID.prefix(4)) + "…" + String(sessionID.suffix(6)) : sessionKey.prefix(10).description
        requestedSourceKey = requestedSource.map { StableDigest.hex(Data($0.utf8)) }
        currentSourceKey = currentSource.map { StableDigest.hex(Data($0.utf8)) }
        self.notificationClick = notificationClick; self.outcome = outcome
        self.elapsedMilliseconds = elapsedMilliseconds.flatMap { $0.isFinite && $0 >= 0 && $0 <= 3_600_000 ? $0 : nil }
    }
}

public struct LatencySummary: Codable, Equatable, Sendable {
    public let samples: Int
    public let p50Milliseconds: Double?
    public let p95Milliseconds: Double?
    public init(_ attempts: [RoutingAttempt], notificationOnly: Bool = true) {
        let values = attempts.filter {
            $0.outcome == .dispatched && (!notificationOnly || ($0.notificationClick &&
                $0.requestedSourceKey != nil && $0.requestedSourceKey == $0.currentSourceKey))
        }
            .compactMap(\.elapsedMilliseconds)
        self.init(milliseconds: values)
    }
    public init(milliseconds: [Double]) {
        let values = milliseconds.filter { $0.isFinite && $0 >= 0 }.sorted()
        samples = values.count
        p50Milliseconds = values.isEmpty ? nil : values[Int(ceil(Double(values.count) * 0.5)) - 1]
        p95Milliseconds = values.isEmpty ? nil : values[Int(ceil(Double(values.count) * 0.95)) - 1]
    }
}

public enum ProtocolRoute {
    public static func authorize(_ session: AgentSession, reference: String?) throws -> ProtocolOriginBinding {
        guard let binding = session.verifiedProtocolBinding,
              reference.map({ $0 == binding.reference }) ?? true else { throw RouterError.unverifiedOrigin }
        return binding
    }
}

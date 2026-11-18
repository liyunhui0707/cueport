import Foundation

/// A recovery budget, not permission to connect or replay requests. Every socket
/// is separately authenticated against the original live process and terminal.
public struct BridgeReconnectPolicy: Sendable {
    public struct Recovery: Equatable, Sendable {
        public let delay: TimeInterval
        public let deadline: Date
    }
    public static let maximumAttempts = 8
    public static let recoveryWindow: TimeInterval = 120
    public static let stableInterval: TimeInterval = 60
    public private(set) var attempts = 0
    public private(set) var deadline: Date?
    public init() {}

    public mutating func recovery(after connectionDuration: TimeInterval, now: Date) -> Recovery? {
        guard connectionDuration.isFinite, connectionDuration >= 0,
              now.timeIntervalSince1970.isFinite else { return nil }
        if connectionDuration >= Self.stableInterval { attempts = 0; deadline = nil }
        if deadline == nil { deadline = now.addingTimeInterval(Self.recoveryWindow) }
        guard let deadline, now < deadline, attempts < Self.maximumAttempts else { return nil }
        let delay = min(8, 0.25 * pow(2, Double(attempts)))
        guard now.addingTimeInterval(delay) < deadline else { return nil }
        attempts += 1
        return Recovery(delay: delay, deadline: deadline)
    }
}

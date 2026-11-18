import Foundation
import Darwin

/// Sequential socket admission shared by the worker and transport integration
/// checks. It never constructs protocol bytes. Exact terminal/dependency checks
/// are mandatory trusted-code callbacks, not event/configuration parameters.
public enum BridgeConnectionServer {
    public struct Result: Sendable {
        public let duration: TimeInterval
        public let endReason: String
        public let startupHandoff: Bool
        public init(duration: TimeInterval, endReason: String, startupHandoff: Bool) {
            self.duration = duration; self.endReason = endReason; self.startupHandoff = startupHandoff
        }
    }
    public struct Progress: Sendable {
        public let status: String
        public let reason: String?
        public let acceptedConnections: Int
        public let recoveryAttempts: Int
    }

    public static func run(listener: Int32, expected: ProcessOriginHint,
                           shouldStop: () -> Bool,
                           revalidate: () throws -> VerifiedTerminalOrigin,
                           handle: (Int32, VerifiedTerminalOrigin, Int) throws -> Result,
                           progress: (Progress) -> Void) throws {
        guard listener >= 0, expected.pid > 1, expected.uid == getuid() else { throw RouterError.unverifiedOrigin }
        var connectionIndex = 0, recovery = BridgeReconnectPolicy()
        var deadline = Date().addingTimeInterval(600), retryNotBefore = Date.distantPast
        var terminalFailure: String?
        func publish(_ status: String, reason: String? = nil) {
            if status == "recovery-failed" { terminalFailure = reason ?? "unknown" }
            progress(.init(status: status, reason: reason, acceptedConnections: connectionIndex, recoveryAttempts: recovery.attempts))
        }
        func originalIsLive() -> Bool {
            guard let live = ProcessOriginProbe.snapshot(expected.pid) else { return false }
            return live.instanceID == expected.instanceID
        }
        publish("waiting-for-client")
        defer { publish(terminalFailure == nil ? "stopped" : "recovery-failed", reason: terminalFailure) }
        while !shouldStop() {
            var client: Int32 = -1
            while Date() < deadline && !shouldStop() {
                guard originalIsLive() else { return }
                if Date() < retryNotBefore { usleep(50_000); continue }
                var pending = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pending, 1, 100)
                if ready < 0 {
                    if errno == EINTR { continue }
                    publish("recovery-failed", reason: "listener-io-failed"); throw RouterError.commandFailed
                }
                guard ready > 0 else { continue }
                guard pending.revents & Int16(POLLERR | POLLNVAL) == 0 else {
                    publish("recovery-failed", reason: "listener-io-failed"); throw RouterError.commandFailed
                }
                let candidate = accept(listener, nil, nil)
                guard candidate >= 0 else { continue }
                if BridgePeerVerifier.matches(candidate, pid: expected.pid, uid: expected.uid) { client = candidate; break }
                close(candidate)
            }
            if shouldStop() { if client >= 0 { close(client) }; return }
            guard client >= 0 else { publish("recovery-failed", reason: "client-deadline-exceeded"); return }
            let result: Result
            do {
                result = try autoreleasepool {
                    defer { close(client) }
                    guard fcntl(client, F_SETFD, FD_CLOEXEC) == 0 else { throw RouterError.commandFailed }
                    let origin = try revalidate()
                    guard origin.process.instanceID == expected.instanceID,
                          origin.process.terminalDevice == expected.terminalDevice,
                          origin.process.isDirectForegroundCandidate, origin.terminal.guid != nil
                    else { throw RouterError.unverifiedOrigin }
                    connectionIndex += 1; publish("connected")
                    return try handle(client, origin, connectionIndex)
                }
            } catch {
                publish("recovery-failed", reason: "origin-or-dependency-verification-failed")
                throw error
            }
            guard !shouldStop(), originalIsLive() else { return }
            if result.startupHandoff {
                deadline = Date().addingTimeInterval(30); retryNotBefore = .distantPast
            } else if let retry = recovery.recovery(after: result.duration, now: Date()) {
                deadline = retry.deadline; retryNotBefore = Date().addingTimeInterval(retry.delay)
                publish("recovering", reason: result.endReason)
            } else { publish("recovery-failed", reason: "retry-budget-exhausted"); return }
        }
    }
}

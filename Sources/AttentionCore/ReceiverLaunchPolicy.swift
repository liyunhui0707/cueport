import Foundation

/// Receiver startup only. This policy never authorizes terminal routing.
public enum ReceiverLaunchPolicy {
    public static func isEarlierInstance(pid: Int32, started: Date?, currentPID: Int32, currentStarted: Date?) -> Bool {
        guard pid != currentPID else { return false }
        if let started, let currentStarted, started != currentStarted { return started < currentStarted }
        // A deterministic tie-breaker for simultaneous launches, never a
        // terminal-identity or process-lifetime authorization.
        return pid < currentPID
    }
    public static func isExplicitRun(_ arguments: [String]) -> Bool {
        arguments.contains { ["--data-dir", "--bridge-poc", "--demo", "--render-previews", "--poc-origin-case"].contains($0) }
    }

    public static func reviewRunIsIsolated(_ arguments: [String], normalRoot: URL = LocalStore.defaultRoot) -> Bool {
        if arguments.contains("--demo") || arguments.contains("--render-previews") { return true }
        let flags = arguments.indices.filter { arguments[$0] == "--data-dir" }
        guard flags.count == 1, let index = flags.first, index + 1 < arguments.count,
              arguments[index + 1].hasPrefix("/"),
              !arguments[index + 1].unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        let root = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
        do { try LocalStore.requireSeparate(root, from: normalRoot); return true }
        catch { return false }
    }
}

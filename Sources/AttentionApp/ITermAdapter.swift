import Foundation
import AttentionCore
import Darwin

enum ITermAdapter {
    enum Stage: String, Sendable { case inventory, reveal, verification }
    struct CommandFailure: LocalizedError, Sendable {
        let stage: Stage
        var errorDescription: String? {
            switch stage {
            case .inventory: "iTerm2 did not return its session inventory. Review its API access, then retry."
            case .reveal: "iTerm2 could not accept the original-session reveal request. Retry from the attention list."
            case .verification: "iTerm2 did not confirm the original Pane. This return was not marked reviewed."
            }
        }
    }
    // No configurable executable and no shell. This interface cannot send text or approvals.
    static let binary = "/Applications/iTerm.app/Contents/Resources/utilities/it2"
    private enum Command: String, Sendable {
        case iterm = "/Applications/iTerm.app/Contents/Resources/utilities/it2"
        case open = "/usr/bin/open"
    }
    @MainActor static func focus(_ origin: VerifiedTerminalOrigin, revealIdentity: TerminalIdentity?,
                                isAuthorized: () -> Bool) async throws {
        let data = try await run(["session", "list", "--json"], stage: .inventory)
        let sessions = try JSONDecoder().decode([TerminalSession].self, from: data)
        var devices: [String: UInt32] = [:]
        for session in sessions {
            if let tty = session.tty, let device = ProcessOriginProbe.terminalDevice(tty) { devices[tty] = device }
        }
        let target = try ProcessOriginVerifier.revalidate(origin,
            live: ProcessOriginProbe.snapshot(origin.process.pid), sessions: sessions,
            devices: devices, currentUID: getuid())
        guard let revealIdentity, revealIdentity.guid == origin.terminal.guid,
              UUID(uuidString: target.id)?.uuidString == revealIdentity.guid else { throw RouterError.unverifiedOrigin }
        // Inventory can suspend long enough for a queued unsubscribe/close to
        // revoke the source. Check the lease again before revealing anything.
        guard isAuthorized() else { throw RouterError.unverifiedOrigin }
        let url = try SessionLocator.revealURL(revealIdentity)
        // Supported reveal handler was successful in the owner's cross-Space POC.
        // Dispatch to the fixed installed app, never a configurable URL/command handler.
        _ = try await run(["-a", "/Applications/iTerm.app", url.absoluteString], stage: .reveal, command: .open)
        for attempt in 0..<4 {
            let focus = try await run(["session", "get-var", "session.id", "--session", "active"], stage: .verification)
            if (try? SessionLocator.verifyFocus(origin.terminal, output: focus)) != nil { return }
            if attempt < 3 { try await Task.sleep(for: .milliseconds(250)) }
        }
        throw CommandFailure(stage: .verification)
    }
    private static func run(_ arguments: [String], stage: Stage, command: Command = .iterm) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            guard FileManager.default.isExecutableFile(atPath: command.rawValue) else { throw RouterError.terminalUnavailable }
            let process = Process(); process.executableURL = URL(fileURLWithPath: command.rawValue); process.arguments = arguments
            let output = Pipe(); let errors = FileHandle.nullDevice
            process.standardOutput = output; process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "LANG": "en_US.UTF-8"]
            try process.run()
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: deadline)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); deadline.cancel()
            guard process.terminationStatus == 0 else { throw CommandFailure(stage: stage) }
            guard data.count <= 1_048_576 else { throw RouterError.oversizedPayload }
            return data
        }.value
    }
}

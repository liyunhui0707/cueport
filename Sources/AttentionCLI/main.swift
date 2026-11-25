import Foundation
import AttentionCore
import Darwin

func option(_ key: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: key), CommandLine.arguments.count > index + 1 else { return nil }
    return CommandLine.arguments[index + 1]
}
let arguments = CommandLine.arguments
let action = arguments.dropFirst().first ?? "help"
let root = option("--data-dir").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? LocalStore.defaultRoot
do {
    switch action {
    case "inspect-bridge-migration":
        guard option("--data-dir") != nil else { throw RouterError.invalidEvent }
        let report = try BridgeMigration.inspect(root)
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    case "remember-bridge-startup":
        guard option("--data-dir") != nil else { throw RouterError.invalidEvent }
        try BridgeMigration.remember(root, apply: arguments.contains("--apply"))
    case "check-bridge-dependencies":
        let executable = option("--native-codex") ?? BridgeRuntime.nativeCodex
        let version = try BridgeRuntime.requireReviewedNativeExecutable(executable)
        guard FileManager.default.isExecutableFile(atPath: BridgeRuntime.iterm) else { throw RouterError.commandFailed }
        print("Native arm64 Codex \(version) and iTerm utility found. API permission and real terminal return are not checked.")
        print(CodexInstallation(nativeExecutable: executable).updateSummary)
    case "codex":
        try BridgeRuntime.launch(Array(arguments.dropFirst(2)))
    case "bridge-worker":
        guard arguments.count == 4, arguments[2] == "--configuration" else { throw RouterError.invalidEvent }
        try BridgeRuntime.worker(URL(fileURLWithPath: arguments[3]))
    case "hook":
        // Never write stdout: any output could change the agent's behavior.
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while data.count <= 1_048_576 {
            let limit = min(buffer.count, 1_048_577 - data.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress!, limit) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw RouterError.invalidEvent }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            // Some environment executors keep stdin open after sending the one
            // JSON object. Completion of that object is sufficient framing.
            if (try? JSONSerialization.jsonObject(with: data)) != nil { break }
        }
        let events = try CodexHookAdapter.events(data: data, environment: ProcessInfo.processInfo.environment,
            processOriginHint: ProcessOriginProbe.nearestCodexAncestor())
        if !events.isEmpty {
            let store = try LocalStore(root: root)
            for event in events { try store.enqueue(event) }
        }
    case "install-hooks", "uninstall-hooks":
        let path = option("--hooks-file").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json")
        let executable = option("--executable") ?? URL(fileURLWithPath: arguments[0]).standardizedFileURL.path
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable),
              !executable.contains("\n"), !root.path.contains("\n") else { throw RouterError.invalidEvent }
        let fm = FileManager.default
        let parent = path.deletingLastPathComponent()
        // The installer refuses symlinks and never changes config.toml or Hook trust.
        let values = try? path.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values?.isSymbolicLink == true { throw RouterError.unsafeStorage }
        let existing = fm.fileExists(atPath: path.path) ? try Data(contentsOf: path) : nil
        let command = HookConfiguration.command(executable: executable, dataRoot: option("--data-dir") == nil ? nil : root.path)
        let output = try HookConfiguration.merged(existing: existing, command: command, uninstall: action == "uninstall-hooks")
        if !arguments.contains("--apply") {
            print("Plan: \(action) for \(path.path)")
            print("Owned command: \(command)")
            print("Events: \(HookConfiguration.eventNames.joined(separator: ", "))")
            print("Existing handlers will be preserved. A private backup is created before any write. Add --apply to execute.")
        } else {
            guard fm.fileExists(atPath: parent.path) else { throw RouterError.unsafeStorage }
            if let existing {
                let backup = parent.appendingPathComponent("hooks.json.aar-backup-" + UUID().uuidString)
                guard fm.createFile(atPath: backup.path, contents: existing, attributes: [.posixPermissions: 0o600]) else { throw RouterError.unsafeStorage }
                print("Backup: \(backup.path)")
                // Detect edits during planning/backup; do not overwrite concurrent changes.
                guard try Data(contentsOf: path) == existing else { throw RouterError.unsafeStorage }
            } else if fm.fileExists(atPath: path.path) { throw RouterError.unsafeStorage }
            try output.write(to: path, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            print("Applied. Start a new Codex CLI session and review these Hooks with /hooks. Trust is never bypassed.")
        }
    case "replay":
        guard let file = option("--file") else { throw RouterError.invalidEvent }
        let event = try JSONDecoder().decode(AgentEvent.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        try LocalStore(root: root).enqueue(event)
        print("Queued sanitized event \(event.kind.rawValue).")
    case "status":
        let state = try LocalStore(root: root).load()
        print("\(state.sessions.count) sessions · \(state.sessions.values.filter(\.needsAttention).count) need attention")
        for session in state.sortedSessions { print("\(session.project) · \(session.execution.rawValue) · \(session.outstanding.count) requests") }
    case "doctor":
        print("Cueport · local diagnostics")
        let hooks = option("--hooks-file").map { URL(fileURLWithPath: $0) } ?? ConnectionDiagnostics.defaultHooks
        print("Hooks: " + ConnectionDiagnostics.hooks(at: hooks))
        print("Last transport end in this data folder: " + ConnectionDiagnostics.lastTransport(in: root))
        if arguments.contains("--check-backend") {
            print("Backend: " + ConnectionDiagnostics.checkBackend(option("--native-codex") ?? NativeCodex.defaultPath))
        }
        print("Loaded helper build: \(MachOBuildIdentity.loadedUUID() ?? "unverified")")
        print("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("iTerm2: \(FileManager.default.fileExists(atPath: "/Applications/iTerm.app") ? "installed" : "not found in /Applications")")
        print("Terminal identity: \(ProcessInfo.processInfo.environment["ITERM_SESSION_ID"].flatMap { TerminalIdentity(sessionID: $0).guid } == nil ? "not present in this process" : "valid")")
        print("Data directory: \(root.path)")
        print("Only diagnostic metadata and recognized helper paths are shown.")
    default:
        print("""
        Cueport — Never miss an agent that needs you.
        cueport hook                         Receive a Codex Hook on stdin; silent and observational
        cueport install-hooks [--apply]       Preview or merge lifecycle Hooks, with backup
        cueport uninstall-hooks [--apply]     Remove only this exact installation's handlers
          --executable /absolute/cueport      Stable helper path (use the same path to uninstall)
          --hooks-file /path/hooks.json   Override destination for isolated testing
          --data-dir /private/directory   Override private local storage
        cueport doctor [--hooks-file PATH]   Inspect local paths and the last transport end
          --check-backend [--native-codex PATH]  Also ask the selected native backend for its version
        cueport check-bridge-dependencies    Check exact native dependency version; no session/model task
        cueport status                       Read the persisted state
        cueport codex --data-dir PATH --     Connected native TUI (Codex \(BridgeCompatibility.supportedDescription))
        cueport codex --data-dir PATH -- resume [SESSION_UUID]
                                         Native restore picker or an explicit conversation
          --native-codex /path/codex       Optional native arm64 dependency before --; same exact version required
        cueport replay --file event.json      Queue a sanitized schema-v1 event
        """)
    }
} catch {
    // A monitoring failure must never block, approve or deny a Codex action.
    if action == "hook" { exit(0) }
    let commandName = URL(fileURLWithPath: arguments[0]).lastPathComponent
    FileHandle.standardError.write(Data("\(commandName): \(error.localizedDescription)\n".utf8)); exit(1)
}

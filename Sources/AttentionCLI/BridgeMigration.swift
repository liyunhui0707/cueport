import Foundation
import Darwin
import AttentionCore

/// Metadata-only preflight. No iTerm API, process arguments/environment, native
/// backend, terminal input or session content is accessed.
enum BridgeMigration {
    static func inspect(_ root: URL) throws -> [String: Int] {
        try LocalStore.ensurePrivateDirectory(root, createIfMissing: false)
        let state = try LocalStore(root: root).load()
        let expected = state.sessions.values.flatMap { ($0.protocolBindings ?? [:]).values }
            .filter { $0.connected || $0.recoveryDeadline != nil }.map(\.binding.origin.process)
        let active = Set(expected.compactMap { value -> String? in
            guard let live = ProcessOriginProbe.snapshot(value.pid), live.instanceID == value.instanceID else { return nil }
            return live.instanceID
        })
        let temporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        let directories = try FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)
            .filter { BridgeDirectoryPolicy.accepts($0) }
        guard directories.count <= 512 else { throw RouterError.unsafeStorage }
        var workers = 0, unknown = 0
        for directory in directories {
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_uid == getuid() else { continue }
            let file = directory.appendingPathComponent("ticket.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do {
                let ticket = try JSONDecoder().decode(BridgeRuntime.Ticket.self, from: BridgeRuntime.readPrivate(file))
                guard ticket.dataRoot.standardizedFileURL == root.standardizedFileURL else { continue }
                if let live = ProcessOriginProbe.snapshot(ticket.expected.pid), live.instanceID == ticket.expected.instanceID { workers += 1 }
            } catch { unknown += 1 }
        }
        return ["active_registered_clients": active.count, "active_bridge_workers": workers, "unknown_worker_tickets": unknown]
    }

    static func remember(_ root: URL, apply: Bool) throws {
        let profile = try BridgeStartupProfile(root: root)
        guard apply else { print("Plan: remember the selected private bridge folder for the daily application"); return }
        guard let preferences = UserDefaults(suiteName: "org.agentattentionrouter.local-development") else { throw RouterError.unsafeStorage }
        preferences.set(try profile.encoded(), forKey: BridgeStartupProfile.defaultsKey)
        guard preferences.synchronize(),
              let saved = preferences.data(forKey: BridgeStartupProfile.defaultsKey),
              try BridgeStartupProfile.decode(saved) == profile else { throw RouterError.unsafeStorage }
        print("Remembered verified private bridge folder. Running clients were not changed.")
    }
}

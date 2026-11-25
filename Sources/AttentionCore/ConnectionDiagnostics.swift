import Foundation
import Darwin

/// Read only when requested. Never run a Hook or interpret a command as shell input.
public enum ConnectionDiagnostics {
    public static let defaultHooks = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json")
    public static let transportFilename = "last-transport-end.json"

    private static func metadata(_ url: URL) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw RouterError.unsafeStorage
        }
        defer { close(fd) }
        var info = stat()
        let limit = 1_048_576
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size <= limit else { throw RouterError.unsafeStorage }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: limit + 1) ?? Data()
        guard data.count == info.st_size else { throw RouterError.unsafeStorage }
        return data
    }

    public static func hooks(at file: URL = defaultHooks) -> String {
        do {
            guard let data = try metadata(file) else { return "No Hooks file here. Explicit bridge connections can run independently." }
            guard let doc = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RouterError.invalidEvent }
            let hooks = doc["hooks"] ?? [String: Any]()
            guard let events = hooks as? [String: Any] else { throw RouterError.invalidEvent }
            var covered = 0, unknown = false
            var paths = Set<String>()
            for name in HookConfiguration.eventNames {
                guard let groups = (events[name] ?? []) as? [[String: Any]] else { throw RouterError.invalidEvent }
                var found = false
                for group in groups {
                    guard let handlers = group["hooks"] as? [[String: Any]] else { throw RouterError.invalidEvent }
                    for handler in handlers where handler["type"] as? String == "command" {
                        guard let command = handler["command"] as? String else { throw RouterError.invalidEvent }
                        guard let path = literalHelper(in: command) else {
                            if command.localizedCaseInsensitiveContains("cueport") || command.contains("/aar") { unknown = true }
                            continue
                        }
                        paths.insert(path)
                        found = true
                    }
                }
                if found { covered += 1 }
            }
            let missing = paths.filter { path in
                var info = stat()
                return stat(path, &info) != 0 || info.st_mode & S_IFMT != S_IFREG || access(path, X_OK) != 0
            }
            if !missing.isEmpty { return "Hook helper unavailable: " + missing.sorted().joined(separator: ", ") + ". Review the command in /hooks and use the installed Cueport helper." }
            let summary = "\(covered)/\(HookConfiguration.eventNames.count) event types have a direct helper command."
            let location = paths.isEmpty ? "" : " " + paths.sorted().joined(separator: ", ")
            return summary + location + (unknown ? " Custom commands require review in /hooks." : " Check trust and matchers in /hooks.")
        } catch { return "Hook metadata could not be verified. Review the file and its permissions in Codex." }
    }

    private static func literalHelper(in command: String) -> String? {
        // Accept only literal absolute paths and the optional quoted data directory emitted by the installer.
        let pattern = #"^(?:'([^'\n]+)'|"([^"$`\\\n]+)"|([^\s"'$;&|`\\<>]+)) hook(?: --data-dir '[^'\n]+')?\z"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) else { return nil }
        for i in 1...3 {
            guard let range = Range(match.range(at: i), in: command) else { continue }
            let path = String(command[range])
            guard path.hasPrefix("/"), ["aar", "cueport"].contains(URL(fileURLWithPath: path).lastPathComponent),
                  !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
            return path
        }
        return nil
    }

    /// Explicit user action only: ask the reviewed CLI for a read-only daemon version.
    public static func checkBackend(_ path: String) -> String {
        let version: String
        do { version = try NativeCodex.verifyVersion(path) }
        catch { return error.localizedDescription }
        do {
            let data = try BoundedProcess.output(URL(fileURLWithPath: path),
                arguments: ["app-server", "daemon", "version"], timeout: 5, maximumBytes: 16_384)
            return backendDescription(data, client: version)
        } catch BoundedProcess.Failure.timeout {
            return "Backend version query timed out. Check the normal Codex backend before resuming."
        } catch {
            return "Backend version query failed. Check that the official backend is installed and running under this user."
        }
    }
    static func backendDescription(_ data: Data, client: String) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let server = object["appServerVersion"] as? String,
              let numeric = BridgeCompatibility.reportedVersion(in: Data(("codex-cli " + server).utf8)),
              server == numeric else { return "The query returned no verifiable backend version. Check your Codex installation." }
        if server != client { return "Backend reports \(server); selected client is \(client). Review both installations before reconnecting." }
        return "Backend reported version \(server), matching the selected client."
    }

    public struct TransportEnd: Codable {
        public let reason: String
        public let date: Date
        public init(reason: String, date: Date) { self.reason = reason; self.date = date }
        public var guidance: String {
            switch reason {
            case "proxy-launch-failed": "Could not launch the native backend proxy. Check the selected executable and its installation."
            case "upstream-closed": "The backend proxy closed its stream. Check the native backend before resuming."
            case "client-closed": "The client closed its stream. If this was unexpected, save any draft and use Copy resume command."
            case "relay-io-failed": "Bridge I/O failed. Save any draft and reconnect from the original project."
            case "stopped": "The bridge worker stopped. Use Copy resume command to reconnect."
            default: "The transport ended for an unknown reason. Check the original terminal."
            }
        }
    }
    public static func lastTransport(in root: URL) -> String {
        do {
            guard let data = try metadata(root.appendingPathComponent(transportFilename)) else { return "No disconnect recorded by this worker version. Current backend reachability is unknown." }
            let end = try JSONDecoder().decode(TransportEnd.self, from: data)
            return end.date.formatted() + " · " + end.guidance
        } catch { return "The last transport record could not be verified." }
    }
}

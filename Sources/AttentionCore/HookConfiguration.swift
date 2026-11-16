import Foundation

public enum HookConfiguration {
    public static let eventNames = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop", "Interrupt", "SessionEnd"]
    public static func command(executable: String, dataRoot: String?) -> String {
        var result = quote(executable) + " hook"
        if let dataRoot { result += " --data-dir " + quote(dataRoot) }
        return result
    }
    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public static func merged(existing: Data?, command: String, uninstall: Bool = false) throws -> Data {
        var document: [String: Any]
        if let existing {
            guard let parsed = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else { throw RouterError.invalidEvent }
            document = parsed
        } else { document = [:] }
        if let value = document["hooks"], !(value is [String: Any]) { throw RouterError.invalidEvent }
        var hooks = document["hooks"] as? [String: Any] ?? [:]
        for name in eventNames {
            if let value = hooks[name], !(value is [[String: Any]]) { throw RouterError.invalidEvent }
            var groups = hooks[name] as? [[String: Any]] ?? []
            // Only remove an exact handler; retain other handlers even within the same group.
            groups = try groups.compactMap { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { throw RouterError.invalidEvent }
                let remaining = handlers.filter { !(($0["type"] as? String == "command") && ($0["command"] as? String == command)) }
                if remaining.count == handlers.count { return group }
                if remaining.isEmpty { return nil }
                var copy = group; copy["hooks"] = remaining; return copy
            }
            if !uninstall {
                // Keep synchronous and short: background Hooks may be cancelled at session end.
                groups.append(["hooks": [["type": "command", "command": command, "timeout": 1]]])
            }
            if !groups.isEmpty { hooks[name] = groups }
            else { hooks.removeValue(forKey: name) }
        }
        document["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
    }
}

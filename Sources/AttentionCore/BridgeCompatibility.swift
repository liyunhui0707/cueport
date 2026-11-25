import Foundation

/// Baselines can launch directly. Other eligible releases must pass the native protocol check.
public enum BridgeCompatibility {
    public static let supportedVersions = ["0.169.0", "0.170.0"]
    public static let supportedDescription = "0.169.0 / 0.170.0, or newer stable releases after a protocol check"
    public static func eligibleVersion(_ version: String) -> Bool {
        guard version.utf8.count <= 20,
              version.range(of: #"^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\z"#, options: .regularExpression) != nil else { return false }
        let parts = version.split(separator: ".")
        return parts[0] != "0" || (Int(parts[1]) ?? 0) >= 169
    }
    public static func nativeVersion(in data: Data) -> String? {
        guard data.count <= 128, let text = String(data: data, encoding: .utf8) else { return nil }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return supportedVersions.first { line == "codex-cli \($0)" }
    }
    /// Display only a plain numeric version. Never expose arbitrary subprocess output.
    public static func reportedVersion(in data: Data) -> String? {
        guard data.count <= 128, let text = String(data: data, encoding: .utf8) else { return nil }
        let line = text.trimmingCharacters(in: .newlines)
        guard line.range(of: #"^codex-cli [0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}\z"#, options: .regularExpression) != nil else { return nil }
        return String(line.dropFirst("codex-cli ".count))
    }
    public static func acceptsNativeVersionOutput(_ data: Data) -> Bool {
        nativeVersion(in: data) != nil
    }
}

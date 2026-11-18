import Foundation

/// An exact reviewed client target, not an open-ended SemVer compatibility claim.
public enum BridgeCompatibility {
    public static let supportedVersions = ["0.169.0", "0.170.0"]
    public static var supportedDescription: String { supportedVersions.joined(separator: " / ") }
    public static func nativeVersion(in data: Data) -> String? {
        guard data.count <= 128, let text = String(data: data, encoding: .utf8) else { return nil }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return supportedVersions.first { line == "codex-cli \($0)" }
    }
    public static func acceptsNativeVersionOutput(_ data: Data) -> Bool {
        nativeVersion(in: data) != nil
    }
}

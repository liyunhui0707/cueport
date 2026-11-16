import Foundation

/// An exact reviewed client target, not an open-ended SemVer compatibility claim.
public enum BridgeCompatibility {
    public static let nativeClientVersion = "0.169.0"
    public static func acceptsNativeVersionOutput(_ data: Data) -> Bool {
        guard data.count <= 128, let text = String(data: data, encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == "codex-cli \(nativeClientVersion)"
    }
}

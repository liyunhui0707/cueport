import Foundation
import Darwin

/// Installation metadata only. This never installs a package, executes a wrapper
/// or reads Codex configuration. Unknown native files use manual update guidance.
public struct CodexInstallation: Sendable {
    public enum Manager: String, Sendable { case npm, brew, manual }
    public let manager: Manager
    public let packageRoot: String?
    private static let managedKeys = ["CODEX_MANAGED_BY_NPM", "CODEX_MANAGED_BY_BUN",
        "CODEX_MANAGED_BY_PNPM", "CODEX_MANAGED_BY_VITE_PLUS", "CODEX_MANAGED_PACKAGE_ROOT"]

    public init(nativeExecutable: String) {
        let native = URL(fileURLWithPath: nativeExecutable).standardizedFileURL.resolvingSymlinksInPath()
        var parent = native.deletingLastPathComponent()
        var found: String?
        for _ in 0..<14 {
            if parent.lastPathComponent == "codex",
               parent.deletingLastPathComponent().lastPathComponent == "@openai",
               parent.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "node_modules",
               parent.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "lib",
               Self.hasNpmWrapper(parent),
               Self.isOfficialNpmPackage(parent.appendingPathComponent("package.json")) {
                found = parent.path; break
            }
            let next = parent.deletingLastPathComponent()
            if next == parent { break }; parent = next
        }
        packageRoot = found
        if found != nil { manager = .npm }
        else if native.path.hasPrefix("/opt/homebrew/Caskroom/codex/") || native.path.hasPrefix("/usr/local/Caskroom/codex/") {
            manager = .brew
        } else { manager = .manual }
    }

    private static func hasNpmWrapper(_ root: URL) -> Bool {
        var info = stat()
        return lstat(root.appendingPathComponent("bin/codex.js").path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    private static func isOfficialNpmPackage(_ file: URL) -> Bool {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 32_768 else { return false }
        guard let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 32_769),
              data.count <= 32_768,
              let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              value["name"] as? String == "@openai/codex" else { return false }
        return true
    }

    public func environment(inheriting original: [String: String]) -> [String: String] {
        var value = original
        for key in Self.managedKeys { value.removeValue(forKey: key) }
        if manager == .npm, let packageRoot {
            // Match the official npm wrapper's default when it has no bun/pnpm
            // invocation context. Preserve the selected package, never a stale root.
            value["CODEX_MANAGED_BY_NPM"] = "1"
            value["CODEX_MANAGED_PACKAGE_ROOT"] = packageRoot
        }
        return value
    }
    public var nativeUpdateArguments: [String] {
        manager == .manual ? ["-c", "check_for_update_on_startup=false"] : []
    }
    public var updateSummary: String {
        switch manager {
        case .npm: "npm installation · Native updater uses npm"
        case .brew: "Homebrew cask installation · Native updater uses Homebrew"
        case .manual: "Manual native file · Update separately; connected launch hides the package-manager update popup"
        }
    }
}

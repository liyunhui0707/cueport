import Foundation
import Darwin

/// An opt-in app preference, never a command or a terminal authorization.
/// Pin the existing private directory so a missing/replaced root cannot silently
/// turn a remembered connection into a new empty monitoring profile.
public struct BridgeStartupProfile: Codable, Equatable, Sendable {
    public static let defaultsKey = "rememberedBridgeStartup.v1"
    public let schema: Int
    public let rootPath: String
    public let device: Int64
    public let inode: UInt64

    public init(root: URL, normalRoot: URL = LocalStore.defaultRoot) throws {
        let root = root.standardizedFileURL
        try Self.checkPath(root.path)
        try LocalStore.requireSeparate(root, from: normalRoot)
        try LocalStore.ensurePrivateDirectory(root, createIfMissing: false)
        var info = stat()
        guard lstat(root.path, &info) == 0 else { throw RouterError.unsafeStorage }
        schema = 1; rootPath = root.path; device = Int64(info.st_dev); inode = UInt64(info.st_ino)
    }

    public func validatedRoot(normalRoot: URL = LocalStore.defaultRoot) throws -> URL {
        guard schema == 1 else { throw RouterError.invalidEvent }
        try Self.checkPath(rootPath)
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let current = try Self(root: root, normalRoot: normalRoot)
        guard self == current else { throw RouterError.unsafeStorage }
        return root
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 8192 else { throw RouterError.oversizedPayload }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schema == 1 else { throw RouterError.invalidEvent }
        try checkPath(value.rootPath)
        return value
    }
    private static func checkPath(_ path: String) throws {
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RouterError.unsafeStorage
        }
    }
}

public struct StartupSelection: Sendable {
    public enum Mode: Sendable { case ordinary, bridge, blocked }
    public let mode: Mode
    public let root: URL
    public let restored: BridgeStartupProfile?
    public let issue: String?

    /// Explicit experiment/data arguments never inherit the app's saved choice.
    /// Only a plain launch (including --settings/--show) restores that choice.
    public static func resolve(arguments: [String], saved: Data?, normalRoot: URL = LocalStore.defaultRoot) -> Self {
        let directoryFlags = arguments.indices.filter { arguments[$0] == "--data-dir" }
        let wantsBridge = arguments.contains("--bridge-poc")
        let isolated = arguments.contains("--demo") || arguments.contains("--render-previews") || arguments.contains("--poc-origin-case")
        func result(_ mode: Mode, _ root: URL = normalRoot, restored: BridgeStartupProfile? = nil, issue: String? = nil) -> Self {
            .init(mode: mode, root: root, restored: restored, issue: issue)
        }
        if !directoryFlags.isEmpty || wantsBridge {
            guard directoryFlags.count == 1, let index = directoryFlags.first, index + 1 < arguments.count,
                  arguments[index + 1].hasPrefix("/"),
                  !arguments[index + 1].unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                return result(.blocked, issue: "Startup requires one absolute data directory. Check the launch arguments.")
            }
            let root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true).standardizedFileURL
            if wantsBridge {
                do { try LocalStore.requireSeparate(root, from: normalRoot) }
                catch { return result(.blocked, root, issue: "The bridge requires a separate data directory. Exact return remains paused.") }
            }
            return result(wantsBridge ? .bridge : .ordinary, root)
        }
        if isolated || saved == nil { return result(.ordinary) }
        do {
            let profile = try BridgeStartupProfile.decode(saved!)
            let root = try profile.validatedRoot(normalRoot: normalRoot)
            return result(.bridge, root, restored: profile)
        } catch {
            return result(.blocked, issue: "Saved bridge startup is unavailable. Its folder or saved setting could not be verified. Choose the folder again in Settings, or forget the saved startup, then reopen the app.")
        }
    }
}

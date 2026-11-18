import Foundation
import Darwin

/// Private, same-user inbox. Atomic files keep Hooks independent of the UI process.
public final class LocalStore: @unchecked Sendable {
    public static let maximumSnapshotBytes = 67_108_864
    public let root: URL
    private var rootIdentity: (dev_t, ino_t)?
    public var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    public init(root: URL) throws {
        self.root = root.standardizedFileURL
        try Self.ensurePrivateDirectory(self.root)
        try Self.requireNotRelocated(self.root)
        try Self.ensurePrivateDirectory(inbox)
        var info = stat()
        guard lstat(self.root.path, &info) == 0 else { throw RouterError.unsafeStorage }
        rootIdentity = (info.st_dev, info.st_ino)
    }
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentAttentionRouter", isDirectory: true)
    }
    public static func requireSeparate(_ root: URL, from reference: URL = defaultRoot) throws {
        guard root.standardizedFileURL.path != reference.standardizedFileURL.path else { throw RouterError.unsafeStorage }
        // APFS is commonly case insensitive; different strings can name the
        // very same directory. Check identity before using a POC data root.
        var target = stat(), original = stat()
        if stat(root.path, &target) == 0, stat(reference.path, &original) == 0,
           target.st_dev == original.st_dev, target.st_ino == original.st_ino { throw RouterError.unsafeStorage }
    }
    public static func ensurePrivateDirectory(_ url: URL, createIfMissing: Bool = true) throws {
        let fm = FileManager.default
        // Reject symlink ancestors as well as a symlink final component.
        var path = url
        while path.path != "/" {
            var info = stat()
            if lstat(path.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                // Foundation canonicalizes /private/var back to /var on macOS.
                // Only Apple's two root-owned system aliases are accepted.
                let target = try? fm.destinationOfSymbolicLink(atPath: path.path)
                let systemAlias = ["/var", "/tmp"].contains(path.path) && info.st_uid == 0 &&
                    (target == "/private" + path.path || target == "private" + path.path)
                if !systemAlias { throw RouterError.unsafeStorage }
            }
            path.deleteLastPathComponent()
        }
        if createIfMissing && !fm.fileExists(atPath: url.path) {
            try mkdirPrivate(url)
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw RouterError.unsafeStorage }
    }
    private static func mkdirPrivate(_ url: URL) throws {
        if mkdir(url.path, 0o700) == 0 { return }
        if errno == EEXIST { return } // Rechecked with lstat by the caller.
        if errno == ENOENT {
            try mkdirPrivate(url.deletingLastPathComponent())
            guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else { throw RouterError.unsafeStorage }
            return
        }
        throw RouterError.unsafeStorage
    }
    private func safeData(_ url: URL, limit: Int64 = 1_048_576) throws -> Data {
        try verifyRoot()
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw RouterError.unsafeStorage }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size <= limit else { throw RouterError.unsafeStorage }
        return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
    }
    private func verifyRoot() throws {
        var info = stat()
        guard lstat(root.path, &info) == 0, let original = rootIdentity,
              info.st_dev == original.0, info.st_ino == original.1 else { throw RouterError.unsafeStorage }
        try Self.ensurePrivateDirectory(root)
        try Self.requireNotRelocated(root)
    }
    /// Recover a missing inbox while preserving the locked root/snapshot. A
    /// replaced root or a symlink/public replacement requires explicit repair.
    public func prepareInbox() throws {
        try verifyRoot()
        try Self.ensurePrivateDirectory(inbox)
    }
    public func enqueue(_ event: AgentEvent) throws {
        try event.validate()
        try prepareInbox()
        let data = try JSONEncoder().encode(event)
        // IDs are hashed again; an input ID is never interpreted as a path.
        let name = StableDigest.hex(Data(event.id.utf8)) + ".json"
        let target = inbox.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) { return }
        let staging = inbox.appendingPathComponent(".pending-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw RouterError.unsafeStorage }
        do { try FileManager.default.moveItem(at: staging, to: target) }
        catch {
            try? FileManager.default.removeItem(at: staging)
            if !FileManager.default.fileExists(atPath: target.path) { throw error }
        }
    }
    public func pending() throws -> [(URL, AgentEvent)] {
        try scan().events
    }
    public func scan() throws -> (events: [(URL, AgentEvent)], rejected: Int) {
        try prepareInbox()
        let files = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var events: [(URL, AgentEvent)] = []
        var rejected = max(0, files.count - 10_000)
        for url in files.prefix(10_000) {
            do {
                let event = try JSONDecoder().decode(AgentEvent.self, from: safeData(url))
                try event.validate(); events.append((url, event))
            } catch { rejected += 1 }
        }
        events.sort { $0.1.timestamp == $1.1.timestamp ? $0.1.id < $1.1.id : $0.1.timestamp < $1.1.timestamp }
        return (events, rejected)
    }
    public func lockConsumer() throws -> FileHandle {
        try verifyRoot()
        let url = root.appendingPathComponent("consumer.lock")
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RouterError.unsafeStorage }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              (info.st_mode & S_IFMT) == S_IFREG else { close(fd); throw RouterError.unsafeStorage }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw RouterError.consumerAlreadyRunning }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    public func lockBridgeWriter() throws -> FileHandle {
        try verifyRoot()
        let file = root.appendingPathComponent("writers.lock")
        let fd = open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RouterError.unsafeStorage }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_mode & S_IFMT == S_IFREG else { close(fd); throw RouterError.unsafeStorage }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { close(fd); throw RouterError.profileMigrating }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    private static func requireNotRelocated(_ root: URL) throws {
        var info = stat()
        if lstat(root.appendingPathComponent("bridge-relocated.json").path, &info) == 0 { throw RouterError.relocatedStorage }
        guard errno == ENOENT else { throw RouterError.unsafeStorage }
    }
    public func load() throws -> RouterState {
        try verifyRoot()
        let url = root.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return RouterState() }
        let state = try JSONDecoder().decode(RouterState.self, from: safeData(url, limit: Int64(Self.maximumSnapshotBytes)))
        guard state.schema == 1 else { throw RouterError.invalidEvent }
        return state
    }
    public func save(_ state: RouterState) throws {
        try verifyRoot()
        let url = root.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: url.path) { _ = try safeData(url, limit: Int64(Self.maximumSnapshotBytes)) }
        let data = try JSONEncoder().encode(state)
        guard data.count <= Self.maximumSnapshotBytes else { throw RouterError.oversizedPayload }
        // A private parent directory protects the atomic temporary file.
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func acknowledge(_ url: URL) throws {
        try prepareInbox()
        guard url.deletingLastPathComponent().resolvingSymlinksInPath().path == inbox.resolvingSymlinksInPath().path,
              url.pathExtension == "json" else { throw RouterError.unsafeStorage }
        try FileManager.default.removeItem(at: url)
    }
    public func snapshotBytes() throws -> Int64? {
        try verifyRoot()
        let file = root.appendingPathComponent("state.json")
        var info = stat()
        if lstat(file.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw RouterError.unsafeStorage
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw RouterError.unsafeStorage }
        return info.st_size
    }
    /// Fixed metadata-only diagnostic destination. Never used as routing/state authority.
    public func saveRuntimeDiagnostics(_ data: Data) throws {
        try verifyRoot()
        guard data.count <= 16_384 else { throw RouterError.oversizedPayload }
        let file = root.appendingPathComponent("runtime-health.json")
        var info = stat()
        if lstat(file.path, &info) == 0 { _ = try safeData(file, limit: 16_384) }
        else if errno != ENOENT { throw RouterError.unsafeStorage }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

import Foundation
import Darwin
import AttentionCore

/// Private local test fixture, never an automatic binding or distribution setting.
struct OriginPOC {
    struct Payload: Codable {
        let schema: Int
        let sessionID: String
        let origin: VerifiedTerminalOrigin
    }
    let payload: Payload
    let file: URL
    private static func readPrivate(_ file: URL, limit: Int64) throws -> Data {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw RouterError.unsafeStorage }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size <= limit else { throw RouterError.unsafeStorage }
        return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
    }
    static func load(_ file: URL) throws -> OriginPOC {
        let data = try readPrivate(file, limit: 65_536)
        let value = try JSONDecoder().decode(Payload.self, from: data)
        guard value.schema == 1, !value.sessionID.isEmpty, value.sessionID.utf8.count <= 256,
              value.origin.terminal.type == "iterm2", value.origin.terminal.guid != nil,
              value.origin.process.uid == getuid(), value.origin.process.isDirectForegroundCandidate else {
            throw RouterError.unverifiedOrigin
        }
        return OriginPOC(payload: value, file: file)
    }
    func record(action: String, success: Bool, milliseconds: Double, failureStage: String? = nil) {
        // Content-free evidence, separate from the product state and raw event data.
        var result: [String: Any] = ["action": action, "focus_request_succeeded": success,
            "return_method": "verified preflight + iterm2:reveal",
            "focus_latency_ms": (milliseconds * 100).rounded() / 100,
            "recorded_at": Date().timeIntervalSince1970,
            "space_switch": "requires user visual confirmation"]
        if let failureStage { result["failure_stage"] = failureStage }
        let url = file.deletingLastPathComponent().appendingPathComponent("routing-click-result.json")
        let historyURL = file.deletingLastPathComponent().appendingPathComponent("routing-click-history.json")
        do {
            try LocalStore.ensurePrivateDirectory(file.deletingLastPathComponent())
            let previous = (try? Self.readPrivate(historyURL, limit: 131_072))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let history = Array((previous + [result]).suffix(20))
            try JSONSerialization.data(withJSONObject: history, options: [.prettyPrinted, .sortedKeys]).write(to: historyURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
        } catch { /* POC evidence failure must not affect monitoring or focus. */ }
    }
}

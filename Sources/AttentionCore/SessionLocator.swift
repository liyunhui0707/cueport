import Foundation

public struct TerminalSession: Codable, Equatable, Sendable {
    public var id: String
    public var window_id: String
    public var tab_id: String
    public var tty: String?
    public init(id: String, windowID: String, tabID: String, tty: String? = nil) { self.id = id; window_id = windowID; tab_id = tabID; self.tty = tty }
}

public enum SessionLocator {
    public static func verifyFocus(_ identity: TerminalIdentity, output: Data) throws {
        guard output.count <= 1_048_576 else { throw RouterError.oversizedPayload }
        // Explicit server-side `active`, not it2 app get-focus: that command
        // prints the last Session across all windows in the inspected version.
        guard identity.type == "iterm2", let expected = identity.guid,
              let value = try? JSONDecoder().decode(String.self, from: output),
              value.utf8.count == 36, let actual = UUID(uuidString: value),
              actual.uuidString == expected else { throw RouterError.unverifiedOrigin }
    }
    public static func revealURL(_ identity: TerminalIdentity) throws -> URL {
        guard identity.type == "iterm2", identity.guid != nil else { throw RouterError.missingIdentity }
        var parts = URLComponents()
        parts.scheme = "iterm2"; parts.path = "reveal"
        parts.queryItems = [URLQueryItem(name: "sessionid", value: identity.sessionID)]
        guard let url = parts.url else { throw RouterError.missingIdentity }
        return url
    }
    public static func exact(_ identity: TerminalIdentity?, in sessions: [TerminalSession]) throws -> TerminalSession {
        guard let identity, identity.type == "iterm2", let guid = identity.guid else { throw RouterError.missingIdentity }
        let matches = sessions.filter { UUID(uuidString: $0.id)?.uuidString == guid }
        guard !matches.isEmpty else { throw RouterError.sessionNotFound }
        guard matches.count == 1 else { throw RouterError.ambiguousSession }
        return matches[0]
    }
}

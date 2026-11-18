import Foundation

public enum BridgeDirectoryPolicy {
    public static func accepts(_ directory: URL) -> Bool {
        // Foundation can canonicalize an existing /private/tmp URL to /tmp.
        // Permit only those two system spellings and one exact mkdtemp leaf.
        directory.path.range(of: #"^/(?:private/)?tmp/aar-bridge-[A-Za-z0-9]{6}$"#, options: .regularExpression) != nil
    }
}

/// A single explicitly launched TUI connection, independent of daemon environment.
public struct ProtocolOriginBinding: Codable, Equatable, Sendable {
    public let id: String
    public let origin: VerifiedTerminalOrigin
    public init(id: String = UUID().uuidString, origin: VerifiedTerminalOrigin) {
        self.id = id; self.origin = origin
    }
    public var reference: String { StableDigest.hex(Data("\(id):\(origin.process.instanceID)".utf8)) }
    public func validate() throws {
        guard !id.isEmpty, id.utf8.count <= 128, origin.terminal.type == "iterm2",
              origin.terminal.guid != nil, origin.process.isDirectForegroundCandidate else { throw RouterError.unverifiedOrigin }
    }
}

public struct ProtocolBindingState: Codable, Equatable, Sendable {
    public var binding: ProtocolOriginBinding
    public var connected: Bool
    public var updatedAt: Date
    public var workerBuildUUID: String?
    public var workerBuildConflict: Bool?
    public var recoveryDeadline: Date?
    public var nativeClientVersion: String?
    public init(binding: ProtocolOriginBinding, connected: Bool, updatedAt: Date, workerBuildUUID: String? = nil, workerBuildConflict: Bool? = nil) {
        self.binding = binding; self.connected = connected; self.updatedAt = updatedAt
        self.workerBuildUUID = workerBuildUUID; self.workerBuildConflict = workerBuildConflict
    }
}

import Foundation

/// Presentation only: a recorded source is not proof of liveness or the thread
/// currently displayed in a TUI. Grouping never grants routing authorization.
public struct SessionSourceGroup: Identifiable, Sendable {
    public let id: String
    public let sourceKey: String?
    public let sessions: [AgentSession]
    public var attentionCount: Int { sessions.filter(\.needsAttention).count }
    public var title: String {
        let projects = Set(sessions.map(\.project))
        return projects.count == 1 ? sessions[0].project : "Shared terminal source"
    }
}

public struct SessionOverview: Sendable {
    public let groups: [SessionSourceGroup]
    public let history: [AgentSession]
    public let archived: [AgentSession]
    public let registeredSourceCount: Int
    public var registeredThreads: [AgentSession] { groups.flatMap(\.sessions) }
    public var attentionCount: Int { (registeredThreads + history).filter(\.needsAttention).count }
    public var historyAttentionCount: Int { history.filter(\.needsAttention).count }
    public var workingCount: Int { registeredThreads.filter { $0.execution == .running }.count }
    public var unarchivedCount: Int { registeredThreads.count + history.count }

    private static func sourceKey(_ binding: ProtocolOriginBinding) -> String? {
        guard (try? binding.validate()) != nil else { return nil }
        guard let guid = binding.origin.terminal.guid else { return nil }
        let process = binding.origin.process
        return StableDigest.hex(Data("\(guid):\(process.instanceID):\(process.terminalDevice)".utf8))
    }
    public init(state: RouterState, bridgeMode: Bool, visibleThreadIDs: Set<String>? = nil) {
        var groups: [String: [AgentSession]] = [:], sourceKeys: [String: String] = [:]
        var sources = Set<String>(), history: [AgentSession] = [], archived: [AgentSession] = []
        for session in state.sortedSessions {
            if let visibleThreadIDs, !visibleThreadIDs.contains(session.id) { continue }
            if session.archivedAt != nil { archived.append(session); continue }
            let active = (session.protocolBindings ?? [:]).values.filter(\.connected)
            let keys = active.compactMap { Self.sourceKey($0.binding) }
            sources.formUnion(keys)
            if bridgeMode && active.isEmpty { history.append(session); continue }
            // Multiple bindings stay visibly ambiguous, even if their terminal
            // metadata agrees. Never pick the latest binding/thread to route.
            if active.count == 1, let key = keys.first {
                groups[key, default: []].append(session); sourceKeys[key] = key
            } else {
                groups["unverified-" + session.id] = [session]
            }
        }
        let order = state.sortedSessions.enumerated().reduce(into: [String: Int]()) { $0[$1.element.id] = $1.offset }
        self.groups = groups.map { SessionSourceGroup(id: $0.key, sourceKey: sourceKeys[$0.key], sessions: $0.value) }
            .sorted { (order[$0.sessions[0].id] ?? 0) < (order[$1.sessions[0].id] ?? 0) }
        self.history = history; self.archived = archived; registeredSourceCount = sources.count
    }
}

extension AgentSession {
    /// Archiving hides a quiet/uncertain record, never an active turn or an
    /// observed/confirmed outstanding prompt. Unknown evidence is retained.
    public var canArchive: Bool {
        execution != .running && outstanding.allSatisfy { $0.evidence == .unknown }
    }
}

extension RouterState {
    @discardableResult public mutating func setArchived(_ id: String, archived: Bool, now: Date = Date()) -> Bool {
        guard var session = sessions[id], !archived || session.canArchive else { return false }
        session.archivedAt = archived ? now : nil
        sessions[id] = session
        return true
    }
}

import Foundation

public enum Execution: String, Codable, Sendable { case running, idle, interrupted, ended, unknown }
public enum EventKind: String, Codable, Sendable {
    case sessionStarted, turnStarted, turnStopped, interrupted, sessionEnded
    case activity, approvalRequested, humanApprovalPending, questionQueued
    case requestResolved, requestCancelled, inputSubmitted, sourceLost, observationGap
}
public enum RequestKind: String, Codable, Sendable { case approval, question }
public enum Evidence: String, Codable, Sendable {
    /// A Hook observed creation. This is not proof that a human is blocked.
    case observed
    /// A supported protocol reports a live, outstanding request.
    case confirmed
    case unknown, resolved, cancelled
    public var outstanding: Bool { self != .resolved && self != .cancelled }
}

public struct TerminalIdentity: Codable, Equatable, Sendable {
    public var type: String
    public var sessionID: String
    public init(type: String = "iterm2", sessionID: String) { self.type = type; self.sessionID = sessionID }

    /// iTerm's positional prefix is a historical hint, never a routing key.
    public var guid: String? {
        let parts = sessionID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              let uuid = UUID(uuidString: String(parts.last!)) else { return nil }
        if parts.count == 2 {
            guard parts[0].range(of: #"^w[0-9]+t[0-9]+p[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        }
        return uuid.uuidString
    }
}

public struct AgentEvent: Codable, Equatable, Sendable {
    public var schema = 1
    public var id: String
    public var kind: EventKind
    public var sessionID: String
    public var turnID: String?
    public var requestID: String?
    public var questionIDs: [String]
    public var terminal: TerminalIdentity?
    public var terminalHints: [TerminalIdentity]?
    public var processOriginHint: ProcessOriginHint?
    public var protocolBinding: ProtocolOriginBinding?
    /// Diagnostic metadata from the worker's mapped executable; never a routing key.
    public var workerBuildUUID: String?
    public var nativeClientVersion: String?
    public var coverageIssue: ProtocolCoverageIssue?
    /// Current runtime status from a correlated protocol registration, not a new turn.
    public var executionObservation: Execution?
    /// Transport recovery only; never authorizes routing or resolves requests.
    public var transportRecoveryDeadline: Date?
    /// A matching previously observed active turn was explicitly completed in
    /// native resume metadata. Timestamp is observation time, not model latency.
    public var recoveredFromHistory: Bool?
    public var project: String
    public var timestamp: Date
    public var source: String
    public init(id: String = UUID().uuidString, kind: EventKind, sessionID: String,
                turnID: String? = nil, requestID: String? = nil, questionIDs: [String] = [],
                terminal: TerminalIdentity? = nil, terminalHints: [TerminalIdentity]? = nil,
                processOriginHint: ProcessOriginHint? = nil, protocolBinding: ProtocolOriginBinding? = nil,
                workerBuildUUID: String? = nil, nativeClientVersion: String? = nil,
                executionObservation: Execution? = nil, project: String = "Unknown project",
                timestamp: Date = Date(), source: String = "codex-hook") {
        self.id = id; self.kind = kind; self.sessionID = sessionID; self.turnID = turnID
        self.requestID = requestID; self.questionIDs = questionIDs; self.terminal = terminal; self.terminalHints = terminalHints
        self.processOriginHint = processOriginHint
        self.protocolBinding = protocolBinding
        self.workerBuildUUID = workerBuildUUID
        self.nativeClientVersion = nativeClientVersion
        self.executionObservation = executionObservation
        self.project = project; self.timestamp = timestamp; self.source = source
    }
    public func validate() throws {
        guard schema == 1, !id.isEmpty, id.utf8.count <= 256,
              !sessionID.isEmpty, sessionID.utf8.count <= 256,
              project.utf8.count <= 512, questionIDs.count <= 64,
              questionIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }),
              requestID.map({ !$0.isEmpty && $0.utf8.count <= 1024 }) ?? true,
              terminal.map({ $0.type == "iterm2" && $0.guid != nil }) ?? true,
              terminalHints.map({ $0.count <= 2 && $0.allSatisfy { $0.type == "iterm2" && $0.guid != nil } }) ?? true,
              processOriginHint.map({ $0.pid > 1 && $0.startMicroseconds > 0 }) ?? true,
              timestamp.timeIntervalSince1970.isFinite else { throw RouterError.invalidEvent }
        if let protocolBinding {
            guard source == "codex-protocol" else { throw RouterError.invalidEvent }
            try protocolBinding.validate()
        }
        if let workerBuildUUID {
            guard source == "codex-protocol", protocolBinding != nil,
                  MachOBuildIdentity.canonicalUUID(workerBuildUUID) == workerBuildUUID else { throw RouterError.invalidEvent }
        }
        if let nativeClientVersion {
            guard source == "codex-protocol", protocolBinding != nil,
                  BridgeCompatibility.supportedVersions.contains(nativeClientVersion) else { throw RouterError.invalidEvent }
        }
        if coverageIssue != nil {
            guard kind == .activity, source == "codex-protocol", protocolBinding != nil, requestID == id,
                  id.range(of: #"^coverage-[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw RouterError.invalidEvent }
        }
        if let executionObservation {
            guard kind == .sessionStarted, source == "codex-protocol", protocolBinding != nil,
                  [.running, .idle, .unknown].contains(executionObservation) else { throw RouterError.invalidEvent }
        }
        if let deadline = transportRecoveryDeadline {
            guard kind == .sourceLost, source == "codex-protocol", protocolBinding != nil,
                  deadline.timeIntervalSince1970.isFinite,
                  (0...BridgeReconnectPolicy.recoveryWindow).contains(deadline.timeIntervalSince(timestamp))
            else { throw RouterError.invalidEvent }
        }
        if let recoveredFromHistory {
            guard recoveredFromHistory, [.turnStopped, .interrupted].contains(kind),
                  source == "codex-protocol", protocolBinding != nil,
                  turnID.map({ !$0.isEmpty && $0.utf8.count <= 256 }) == true
            else { throw RouterError.invalidEvent }
        }
    }
}

public struct AttentionRequest: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: RequestKind
    public var evidence: Evidence
    public var updatedAt: Date
    public var turnID: String?
    public var reviewed = false
    public var answerSubmittedAt: Date?
    public init(id: String, kind: RequestKind, evidence: Evidence, updatedAt: Date, turnID: String? = nil, reviewed: Bool = false, answerSubmittedAt: Date? = nil) {
        self.id = id; self.kind = kind; self.evidence = evidence; self.updatedAt = updatedAt; self.turnID = turnID; self.reviewed = reviewed
        self.answerSubmittedAt = answerSubmittedAt
    }
}

public struct AgentSession: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var project: String
    public var terminal: TerminalIdentity?
    public var terminalHints: [TerminalIdentity]?
    public var processOriginHint: ProcessOriginHint?
    public var processOriginObservedAt: Date?
    /// Conservatively retained when two OS process lifetimes report one thread.
    public var processOriginConflict: Bool?
    public var protocolBindings: [String: ProtocolBindingState]?
    public var verifiedProtocolBinding: ProtocolOriginBinding? {
        let active = (protocolBindings ?? [:]).values.filter(\.connected)
        return active.count == 1 ? active.first?.binding : nil
    }
    public var execution: Execution = .unknown
    public var executionAt: Date = .distantPast
    public var turnID: String?
    public var lastSeen: Date = .distantPast
    public var requests: [String: AttentionRequest] = [:]
    public var completionAt: Date?
    public var completionReviewed = false
    public var routeError: String?
    public var protocolGapAt: Date?
    public var protocolCoverageNotice: ProtocolCoverageNotice?
    /// Optional UI choice only. Never an answer, review, deletion or disconnect.
    public var archivedAt: Date?
    public var displayReference: String { id.count > 12 ? String(id.prefix(4)) + "…" + String(id.suffix(6)) : id }
    public var outstanding: [AttentionRequest] {
        requests.values.filter { $0.evidence.outstanding }.sorted { $0.updatedAt < $1.updatedAt }
    }
    public var needsAttention: Bool { !outstanding.isEmpty || (completionAt != nil && !completionReviewed) || execution == .interrupted || protocolGapAt != nil || protocolCoverageNotice?.reviewed == false }
    public var queuedQuestions: [AttentionRequest] {
        outstanding.filter { $0.kind == .question && $0.answerSubmittedAt == nil && $0.evidence != .unknown }
    }
    public var submittedQuestions: [AttentionRequest] {
        outstanding.filter { $0.kind == .question && $0.answerSubmittedAt != nil }
    }
    public var uncertainQuestions: [AttentionRequest] {
        outstanding.filter { $0.kind == .question && $0.answerSubmittedAt == nil && $0.evidence == .unknown }
    }
    public var priority: Int {
        if outstanding.contains(where: { $0.kind == .approval && $0.evidence == .confirmed }) { return 0 }
        if !queuedQuestions.isEmpty { return 1 }
        if outstanding.contains(where: { $0.kind == .approval && $0.evidence == .observed }) || execution == .interrupted || protocolGapAt != nil || protocolCoverageNotice?.reviewed == false { return 2 }
        if completionAt != nil && !completionReviewed { return 3 }
        if !outstanding.isEmpty { return 4 }
        return execution == .running ? 5 : 6
    }
    public init(id: String, project: String, terminal: TerminalIdentity? = nil) {
        self.id = id; self.project = project; self.terminal = terminal
    }
}

public enum RouterError: Error, LocalizedError {
    case invalidEvent, unsafeStorage, oversizedPayload, missingIdentity, terminalUnavailable, sessionNotFound, ambiguousSession, commandFailed, consumerAlreadyRunning, unverifiedOrigin, profileMigrating, relocatedStorage
    public var errorDescription: String? {
        switch self {
        case .invalidEvent: "The event does not match the supported schema."
        case .unsafeStorage: "The local data directory must be private, owned by you, and contain no symbolic links."
        case .oversizedPayload: "The event exceeds the 1 MiB input limit."
        case .missingIdentity: "No verified iTerm2 session identity was recorded. Start a new Codex session in iTerm2 after installing Hooks."
        case .terminalUnavailable: "iTerm2’s API is unavailable. Enable its Python API in Settings → General → Magic, then authorize the connection."
        case .sessionNotFound: "The original terminal session could not be found. It may have closed. No other session was selected."
        case .ambiguousSession: "More than one terminal matched. No session was selected."
        case .commandFailed: "The terminal could not be focused. Check Diagnostics and iTerm2’s API permissions."
        case .consumerAlreadyRunning: "Another Cueport instance is already monitoring this data directory."
        case .profileMigrating: "This bridge profile is being migrated. Wait for migration to finish, then copy a new launch/resume command from the installed app."
        case .relocatedStorage: "This bridge profile was relocated. Open the installed application and use its current Copy launch/resume command; the retained old profile will not be reopened."
        case .unverifiedOrigin: "The original foreground Codex process could not be verified. No other terminal was selected."
        }
    }
}

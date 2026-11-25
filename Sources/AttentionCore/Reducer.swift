import Foundation

public struct RouterState: Codable, Equatable, Sendable {
    public var schema = 1
    public var sessions: [String: AgentSession] = [:]
    public var processed: Set<String> = []
    public var recentEvents: [AgentEvent]?
    public var notificationReceipts: [String: Date]?
    public var pendingNotifications: [String: PendingNotification]?
    public var routingAttempts: [RoutingAttempt]?
    public init() {}
    public mutating func recordRoutingAttempt(_ attempt: RoutingAttempt) {
        routingAttempts = Array(((routingAttempts ?? []) + [attempt]).suffix(100))
    }
    public var sortedSessions: [AgentSession] {
        sessions.values.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.lastSeen != $1.lastSeen { return $0.lastSeen > $1.lastSeen }
            return $0.id < $1.id
        }
    }

    @discardableResult public mutating func apply(_ event: AgentEvent) throws -> Bool {
        try event.validate()
        guard !processed.contains(event.id) else { return false }
        var session = sessions[event.sessionID] ?? AgentSession(id: event.sessionID, project: event.project)
        if let binding = event.protocolBinding {
            let previous = session.protocolBindings?[binding.id]
            // A disconnected connection is a tombstone. Delayed traffic cannot
            // re-open it; reconnects must receive a new connection identity.
            if previous?.connected == false {
                processed.insert(event.id); return true
            }
            guard previous.map({ $0.binding == binding }) ?? true else { throw RouterError.unverifiedOrigin }
            if previous.map({ $0.updatedAt <= event.timestamp }) ?? true {
                let conflictingBuilds = previous?.workerBuildConflict == true ||
                    (previous?.workerBuildUUID != nil && event.workerBuildUUID != nil && previous?.workerBuildUUID != event.workerBuildUUID)
                session.protocolBindings = session.protocolBindings ?? [:]
                var entry = ProtocolBindingState(binding: binding,
                    connected: event.kind != .sourceLost, updatedAt: event.timestamp,
                    workerBuildUUID: previous?.workerBuildUUID ?? event.workerBuildUUID,
                    workerBuildConflict: conflictingBuilds ? true : nil)
                entry.recoveryDeadline = event.kind == .sourceLost ? event.transportRecoveryDeadline : nil
                entry.nativeClientVersion = previous?.nativeClientVersion ?? event.nativeClientVersion
                session.protocolBindings?[binding.id] = entry
                if event.kind == .sessionStarted {
                    // Retire the recovery presentation of older transports from
                    // this same verified TUI. Their routing tombstones remain.
                    for id in Array(session.protocolBindings?.keys ?? Dictionary<String, ProtocolBindingState>().keys) where id != binding.id {
                        guard var old = session.protocolBindings?[id], !old.connected,
                              old.binding.origin.process.instanceID == binding.origin.process.instanceID,
                              old.binding.origin.terminal.guid == binding.origin.terminal.guid else { continue }
                        old.recoveryDeadline = nil; session.protocolBindings?[id] = old
                    }
                }
            }
            if let verified = session.verifiedProtocolBinding {
                session.terminal = verified.origin.terminal
                session.processOriginHint = verified.origin.process
                session.processOriginObservedAt = event.timestamp
            }
        }
        // Conflicting identities are not silently rebound: resumed sessions may move,
        // but need a fresh SessionStart event to establish their new terminal.
        if let terminal = event.terminal, event.timestamp >= session.lastSeen {
            if event.kind == .sessionStarted || session.terminal == nil { session.terminal = terminal }
            else if session.terminal?.guid != terminal.guid { session.routeError = "Terminal identity changed. Restart the Codex session to verify its location." }
        }
        if event.timestamp >= session.lastSeen { session.project = event.project }
        if event.timestamp >= session.lastSeen, let hints = event.terminalHints { session.terminalHints = hints }
        if event.protocolBinding == nil, let previous = session.processOriginHint, let current = event.processOriginHint,
           previous.instanceID != current.instanceID {
            // Never last-writer-win a thread shared/resumed by multiple clients.
            // This feasibility gate stays conservative even after one client exits.
            session.processOriginConflict = true
        }
        if event.protocolBinding == nil, [.sessionStarted, .inputSubmitted].contains(event.kind),
           event.timestamp >= (session.processOriginObservedAt ?? session.processOriginHint?.capturedAt ?? .distantPast) {
            // Missing evidence from a new input invalidates an older association.
            session.processOriginHint = event.processOriginHint
            session.processOriginObservedAt = event.timestamp
        }
        session.lastSeen = max(session.lastSeen, event.timestamp)
        if let archived = session.archivedAt, event.timestamp > archived {
            switch event.kind {
            case .sessionStarted, .turnStarted, .inputSubmitted, .questionQueued,
                 .approvalRequested, .humanApprovalPending, .turnStopped, .interrupted, .observationGap:
                session.archivedAt = nil
            case .activity where event.coverageIssue != nil:
                session.archivedAt = nil
            default: break
            }
        }
        if let issue = event.coverageIssue,
           event.timestamp >= (session.protocolCoverageNotice?.observedAt ?? .distantPast),
           session.protocolCoverageNotice?.id != event.id {
            session.protocolCoverageNotice = .init(id: event.id, issue: issue, observedAt: event.timestamp)
        }

        func upsert(_ id: String, _ kind: RequestKind, _ evidence: Evidence) {
            if let old = session.requests[id] {
                guard old.updatedAt <= event.timestamp, old.evidence.outstanding else { return }
                // Replayed creation cannot reopen a question with a submitted answer.
                if kind == .question, old.answerSubmittedAt != nil { return }
            }
            session.requests[id] = AttentionRequest(id: id, kind: kind, evidence: evidence, updatedAt: event.timestamp, turnID: event.turnID)
            session.requests[id]?.creationEventID = event.id
        }
        func makeUncertain() {
            for id in session.requests.keys {
                guard var request = session.requests[id], request.evidence.outstanding,
                      request.updatedAt <= event.timestamp else { continue }
                request.evidence = .unknown; request.updatedAt = event.timestamp
                session.requests[id] = request
            }
        }
        switch event.kind {
        case .approvalRequested:
            upsert(event.requestID ?? event.id, .approval, .observed)
        case .humanApprovalPending:
            // This event is reserved for a validated protocol adapter, never inferred by a timer.
            guard event.source == "codex-protocol" else { throw RouterError.invalidEvent }
            guard let id = event.requestID else { throw RouterError.invalidEvent }
            upsert(id, .approval, .confirmed)
        case .questionQueued:
            for id in event.questionIDs { upsert(id, .question, .observed) }
        case .requestResolved, .requestCancelled:
            // Resolution requires exact identifiers, including before-create tombstones.
            guard event.source == "codex-protocol" else { throw RouterError.invalidEvent }
            let ids = event.questionIDs + (event.requestID.map { [$0] } ?? [])
            guard !ids.isEmpty else { throw RouterError.invalidEvent }
            for id in ids {
                guard session.requests[id].map({ $0.updatedAt <= event.timestamp }) ?? true else { continue }
                session.requests[id] = AttentionRequest(id: id, kind: session.requests[id]?.kind ?? .question,
                    evidence: event.kind == .requestResolved ? .resolved : .cancelled,
                    updatedAt: event.timestamp, turnID: event.turnID, answerSubmittedAt: session.requests[id]?.answerSubmittedAt)
            }
        case .inputSubmitted:
            if event.questionIDs.isEmpty { makeUncertain() }
            else {
                for id in event.questionIDs {
                    if let old = session.requests[id] {
                        guard old.kind == .question, old.evidence.outstanding,
                              old.updatedAt <= event.timestamp else { continue }
                    }
                    var request = session.requests[id] ?? AttentionRequest(id: id, kind: .question,
                        evidence: .unknown, updatedAt: event.timestamp, turnID: event.turnID)
                    request.answerSubmittedAt = event.timestamp
                    request.evidence = .unknown; request.updatedAt = event.timestamp
                    session.requests[id] = request
                }
            }
        case .turnStopped, .interrupted, .sessionEnded, .sourceLost, .observationGap:
            // A normal chat answer or Stop is not evidence that each question was answered.
            makeUncertain()
        default: break
        }
        if event.timestamp >= session.executionAt {
            switch event.kind {
            case .sessionStarted:
                session.execution = event.executionObservation ?? .idle
                session.routeError = nil
            case .turnStarted: session.execution = .running; session.protocolGapAt = nil
            case .inputSubmitted:
                // Protocol send intent may still be rejected; wait for turn/started.
                if event.protocolBinding == nil { session.execution = .running }
            case .activity: break // A late tool result cannot prove a turn is still executing.
            case .turnStopped:
                session.execution = .idle; session.completionAt = event.timestamp; session.completionReviewed = false
            case .interrupted: session.execution = .interrupted
            case .sessionEnded: session.execution = .ended
            case .sourceLost: session.execution = .unknown; session.protocolGapAt = nil
            case .observationGap: session.execution = .unknown; session.protocolGapAt = event.timestamp
            default: break
            }
            if [.sessionStarted, .turnStarted, .inputSubmitted, .turnStopped, .interrupted, .sessionEnded, .sourceLost, .observationGap].contains(event.kind) {
                session.executionAt = event.timestamp; session.turnID = event.turnID
            }
        }
        sessions[session.id] = session; processed.insert(event.id)
        recentEvents = Array(((recentEvents ?? []) + [event]).suffix(400))
        NotificationOutbox.prune(in: &self)
        NotificationOutbox.record(event, in: &self)
        return true
    }

    public mutating func age(now: Date, lease: TimeInterval = 600) {
        for id in sessions.keys {
            guard var session = sessions[id] else { continue }
            if now.timeIntervalSince(session.lastSeen) > lease && session.execution != .ended { session.execution = .unknown }
            for key in session.requests.keys {
                guard var request = session.requests[key], request.evidence.outstanding,
                      now.timeIntervalSince(request.updatedAt) > lease else { continue }
                request.evidence = .unknown; session.requests[key] = request
            }
            sessions[id] = session
        }
    }

    public mutating func reviewNotification(_ id: String, keys: [String]) {
        guard !keys.isEmpty, keys.count <= 64, var session = sessions[id] else { return }
        let advertised = Set(keys)
        if session.execution == .idle, let date = session.completionAt,
           advertised.contains(NotificationPolicy.completionKey(id, date, turnID: session.turnID)) {
            session.completionReviewed = true
        }
        for request in session.requests.values where !request.reviewed && advertised.contains(NotificationPolicy.reviewKey(id, request)) {
            session.requests[request.id]?.reviewed = true
        }
        sessions[id] = session
    }

    /// Match only the uncertain records the owner saw. Protocol evidence and approvals stay intact.
    public mutating func clearCheckedReminders(from snapshot: CheckedReminderBatch, now: Date = Date()) {
        guard var session = sessions[snapshot.sessionID] else { return }
        for seen in snapshot.questions {
            guard let current = session.requests[seen.id], current.canManuallyCheck,
                  current.manuallyCheckedAt == nil, current.creationEventID == seen.creationEventID else { continue }
            session.requests[seen.id]?.manuallyCheckedAt = now
        }
        if let seen = snapshot.notice, let current = session.visibleCoverageNotice,
           current.id == seen.id, current.observedAt == seen.observedAt {
            session.protocolCoverageNotice?.manuallyCheckedAt = now
            session.protocolCoverageNotice?.reviewed = true
        }
        sessions[snapshot.sessionID] = session
    }

    public mutating func markReviewed(_ id: String, asSeen snapshot: AgentSession? = nil) {
        guard var session = sessions[id] else { return }
        let seen = snapshot ?? session
        guard seen.id == id else { return }
        if seen.completionAt == session.completionAt { session.completionReviewed = true }
        if let notice = seen.protocolCoverageNotice, notice.id == session.protocolCoverageNotice?.id,
           notice.observedAt == session.protocolCoverageNotice?.observedAt {
            session.protocolCoverageNotice?.reviewed = true
        }
        for (key, request) in seen.requests where session.requests[key] == request {
            session.requests[key]?.reviewed = true
        }
        sessions[id] = session
    }
}

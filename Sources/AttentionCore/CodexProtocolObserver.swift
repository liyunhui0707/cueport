import Foundation
import CoreFoundation

public enum ProtocolDirection: Sendable { case client, server }

/// Observes complete JSON messages after byte forwarding. No content is retained.
/// This type cannot produce transport bytes, answers, approvals or API requests.
public struct CodexProtocolObserver {
    private let binding: ProtocolOriginBinding
    private let project: String
    private let workerBuildUUID: String?
    private let nativeClientVersion: String?
    private var threadProjects: [String: String] = [:]
    private var pendingStarts: [String: Int] = [:]
    private var retirementSequence = 0
    private var retiredAt: [String: Int] = [:]
    private var approvals: [String: (thread: String, request: String)] = [:]
    private var inputs: [String: (thread: String, questions: [String])] = [:]
    private var coverageNotices: [String: Set<ProtocolCoverageIssue>] = [:]
    public private(set) var coverageNoticeCount = 0
    private static let nonInteractiveServerRequests: Set<String> = ["item/tool/call", "account/chatgptAuthTokens/refresh", "attestation/generate", "currentTime/read"]
    private var threads: Set<String> = []
    /// IDs only, carried within the same authenticated worker lifetime. A new
    /// launcher starts empty and never guesses completion from old history.
    public private(set) var recoveryTurns: [String: String] = [:]
    // Keep retired identities so a resume gets a fresh reference. An old
    // notification must not follow another subscription in the same TUI.
    private var subscriptions: [String: ProtocolOriginBinding] = [:]
    private var stopped = false
    /// Monotonic intent guard for the optional startup-picker handoff. A failed
    /// session/turn request or interactive server request is not a picker handoff.
    public private(set) var hasThreadSessionRequest = false
    private var ignoredResponses: [String: String] = [:]
    public private(set) var ignoredOversizedMethods: [String: Int] = [:]
    public private(set) var pickerMetadataRequestCount = 0
    private static let pickerMetadataMethods: Set<String> = ["thread/list", "thread/read", "thread/turns/list", "thread/items/list"]
    private static let quietMetadataMethods: Set<String> = ["model/list", "app/list", "skills/list", "plugin/list",
        "mcpServerStatus/list", "config/read", "configRequirements/read", "thread/list", "thread/read", "thread/turns/list", "thread/items/list"]
    public init(binding: ProtocolOriginBinding, project: String, workerBuildUUID: String? = nil, nativeClientVersion: String? = nil,
                recoveryTurns: [String: String] = [:]) {
        self.binding = binding; self.project = String(project.prefix(128))
        self.workerBuildUUID = MachOBuildIdentity.canonicalUUID(workerBuildUUID)
        self.nativeClientVersion = nativeClientVersion.flatMap { BridgeCompatibility.eligibleVersion($0) ? $0 : nil }
        self.recoveryTurns = Dictionary(uniqueKeysWithValues: recoveryTurns.filter {
            !$0.key.isEmpty && $0.key.utf8.count <= 256 && !$0.value.isEmpty && $0.value.utf8.count <= 256
        }.prefix(128).map { ($0.key, $0.value) })
    }
    private func identifier(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let text = value as? String, !text.isEmpty, text.utf8.count <= 256 { return "s:" + text }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue {
            return "n:" + number.stringValue
        }
        return nil
    }
    private func textID(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 256 else { return nil }
        return text
    }
    private func submittedQuestionIDs(_ content: Any?) -> [String] {
        guard let parts = content as? [[String: Any]], parts.count <= 64 else { return [] }
        let text = parts.compactMap { part -> String? in
            guard part["type"] as? String == "text" else { return nil }
            return part["text"] as? String
        }.joined(separator: "")
        return CodexReplyMetadata.submittedIDs(text)
    }
    private func event(_ kind: EventKind, thread: String, turn: String? = nil,
                       request: String? = nil, questions: [String] = [], now: Date) -> AgentEvent {
        AgentEvent(kind: kind, sessionID: thread, turnID: turn, requestID: request,
            questionIDs: questions, protocolBinding: subscriptions[thread] ?? binding, workerBuildUUID: workerBuildUUID, nativeClientVersion: nativeClientVersion,
            project: threadProjects[thread] ?? project, timestamp: now, source: "codex-protocol")
    }
    private mutating func coverage(_ issue: ProtocolCoverageIssue, thread: String, now: Date) -> [AgentEvent] {
        guard threads.contains(thread) else { return [] }
        let source = (subscriptions[thread] ?? binding).reference
        let key = "coverage-" + StableDigest.hex((try? JSONEncoder().encode([source, thread, issue.rawValue])) ?? Data())
        guard coverageNotices[thread]?.contains(issue) != true else { return [] }
        coverageNotices[thread, default: []].insert(issue)
        if coverageNoticeCount < Int.max { coverageNoticeCount += 1 }
        var notice = event(.activity, thread: thread, request: key, now: now)
        notice.id = key; notice.coverageIssue = issue
        return [notice]
    }
    private mutating func inputRequest(_ id: String, thread: String, turn: String?, keys: [String], now: Date) -> [AgentEvent] {
        if let prior = inputs[id] {
            guard prior.thread == thread, prior.questions == keys else { return coverage(.unsupportedInput, thread: thread, now: now) }
        } else {
            guard approvals[id] == nil else { return coverage(.unsupportedInput, thread: thread, now: now) }
            guard inputs.count + approvals.count < 512 else { return coverage(.requestLimit, thread: thread, now: now) }
            inputs[id] = (thread, keys)
        }
        var queued = event(.questionQueued, thread: thread, turn: turn, questions: keys, now: now)
        queued.id = "bridge-input-" + StableDigest.hex((try? JSONEncoder().encode(keys)) ?? Data())
        return [queued]
    }
    private func inputKey(_ id: String, thread: String, components: [String]) -> String {
        "protocol-input-" + StableDigest.hex((try? JSONEncoder().encode([(subscriptions[thread] ?? binding).reference, id] + components)) ?? Data())
    }
    private mutating func retire(_ thread: String, now: Date) -> [AgentEvent] {
        recoveryTurns.removeValue(forKey: thread)
        guard threads.remove(thread) != nil else { return [] }
        retirementSequence += 1; retiredAt[thread] = retirementSequence
        approvals = approvals.filter { $0.value.thread != thread }
        inputs = inputs.filter { $0.value.thread != thread }
        coverageNotices.removeValue(forKey: thread)
        // Observation loss is not thread exit, answer, cancellation or approval.
        return [event(.sourceLost, thread: thread, now: now)]
    }
    public mutating func observe(_ data: Data, from direction: ProtocolDirection, now: Date = Date()) -> [AgentEvent] {
        guard !stopped, data.count <= 1_048_576,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let method = object["method"] as? String
        let params = object["params"] as? [String: Any] ?? [:]
        let id = identifier(object["id"])
        if direction == .server, id != nil, let method,
           !Self.nonInteractiveServerRequests.contains(method) { hasThreadSessionRequest = true }
        if direction == .client {
            if ["thread/start", "thread/resume", "thread/fork", "thread/unsubscribe"].contains(method ?? "")
                || method?.hasPrefix("turn/") == true { hasThreadSessionRequest = true }
            // A diagnostic counter, never a role, binding or resolution signal.
            if id != nil, let rawID = object["id"] as? String, rawID.hasPrefix("picker-"),
               let method, Self.pickerMetadataMethods.contains(method), pickerMetadataRequestCount < Int.max {
                pickerMetadataRequestCount += 1
            }
            if method == "thread/unsubscribe", let thread = textID(params["threadId"]) {
                // Revoke at send intent, before the TUI can display another
                // thread. A failed unsubscribe stays conservative until a
                // positively correlated start/resume re-establishes it.
                return retire(thread, now: now)
            }
            if let id, let method, Self.quietMetadataMethods.contains(method), ignoredResponses.count < 512 {
                ignoredResponses[id] = method
            }
            if let id, ["thread/start", "thread/resume", "thread/fork"].contains(method), pendingStarts.count < 128 {
                pendingStarts[id] = retirementSequence
            }
            // Sending input is intent, not acceptance. Extract only strict editor
            // IDs so answering one question does not downgrade its siblings.
            if ["turn/start", "turn/steer"].contains(method), let thread = textID(params["threadId"]), threads.contains(thread) {
                return [event(.inputSubmitted, thread: thread, questions: submittedQuestionIDs(params["input"]), now: now)]
            }
            return []
        }
        if let id, object["result"] != nil || object["error"] != nil { ignoredResponses.removeValue(forKey: id) }
        if let id, let requestedAt = pendingStarts.removeValue(forKey: id),
           let result = object["result"] as? [String: Any], let thread = result["thread"] as? [String: Any],
           let threadID = textID(thread["id"]) {
            guard (retiredAt[threadID] ?? 0) <= requestedAt else { return [] }
            // Match the pinned official TUI's hidden-helper filter. User-owned
            // ephemeral sessions and explicitly selected subagents still count.
            if thread["ephemeral"] as? Bool == true,
               ["system", "thread_title"].contains(thread["threadSource"] as? String) { return [] }
            if let cwd = (thread["cwd"] as? String) ?? (result["cwd"] as? String), cwd.hasPrefix("/") {
                threadProjects[threadID] = String(URL(fileURLWithPath: cwd).lastPathComponent.prefix(128))
            }
            if threads.contains(threadID) { return [] } // A resume is not a new idle turn.
            if subscriptions[threadID] != nil {
                subscriptions[threadID] = .init(origin: binding.origin)
            } else {
                guard subscriptions.count < 128 else { return disconnect(now: now) }
                subscriptions[threadID] = binding
            }
            threads.insert(threadID)
            var registration = event(.sessionStarted, thread: threadID, now: now)
            switch (thread["status"] as? [String: Any])?["type"] as? String {
            case "active": registration.executionObservation = .running
            case "idle": registration.executionObservation = .idle
            default: registration.executionObservation = .unknown
            }
            var events = [registration]
            if let turns = thread["turns"] as? [[String: Any]], turns.count <= 10_000 {
                let active = turns.filter { $0["status"] as? String == "inProgress" }
                if registration.executionObservation == .idle, active.isEmpty,
                   let expected = recoveryTurns[threadID] {
                    let matching = turns.filter { textID($0["id"]) == expected }
                    if matching.count == 1, let status = matching[0]["status"] as? String,
                       ["completed", "interrupted", "failed"].contains(status) {
                        recoveryTurns.removeValue(forKey: threadID)
                        var stopped = event(status == "completed" ? .turnStopped : .interrupted,
                            thread: threadID, turn: expected, now: now)
                        stopped.recoveredFromHistory = true
                        events.append(stopped)
                    }
                }
                if registration.executionObservation == .running, active.count == 1,
                   let turn = textID(active[0]["id"]) { recoveryTurns[threadID] = turn }
            }
            return events
        }
        let legacyApproval = ["execCommandApproval", "applyPatchApproval"].contains(method ?? "")
        guard let thread = textID(params["threadId"]) ?? (legacyApproval ? textID(params["conversationId"]) : nil), threads.contains(thread) else {
            // A connection-level coverage notice does not assign the request to
            // a thread or create pending questions. Only already-owned sources
            // may display it; no directory/title/active-pane fallback exists.
            guard id != nil, let method, !Self.nonInteractiveServerRequests.contains(method) else { return [] }
            return threads.sorted().flatMap { coverage(.unscopedRequest, thread: $0, now: now) }
        }
        let turn = textID(params["turnId"])
        switch method {
        case "thread/closed", "thread/archived", "thread/deleted":
            return retire(thread, now: now)
        case "turn/started":
            let started = textID((params["turn"] as? [String: Any])?["id"]) ?? turn
            recoveryTurns[thread] = started
            return [event(.turnStarted, thread: thread, turn: started, now: now)]
        case "turn/completed":
            let completed = params["turn"] as? [String: Any] ?? [:]
            let status = completed["status"] as? String
            guard ["completed", "interrupted", "failed"].contains(status) else { return disconnect(now: now) }
            let completedID = textID(completed["id"]) ?? turn
            if recoveryTurns[thread] == completedID { recoveryTurns.removeValue(forKey: thread) }
            return [event(status == "completed" ? .turnStopped : .interrupted, thread: thread,
                turn: completedID, now: now)]
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval", "mcpServer/elicitation/request":
            if method == "mcpServer/elicitation/request" {
                guard let id else { return coverage(.unsupportedInput, thread: thread, now: now) }
                let mode = params["mode"] as? String ?? ""
                guard ["form", "openai/form", "openaiForm", "url", "openai/userVerification"].contains(mode) else { return coverage(.unsupportedInput, thread: thread, now: now) }
                let approval = (params["_meta"] as? [String: Any])?["codex_approval_kind"] as? String == "mcp_tool_call"
                if !approval {
                    return inputRequest(id, thread: thread, turn: turn, keys: [inputKey(id, thread: thread, components: ["mcp"])], now: now)
                }
                guard ["form", "openai/form", "openaiForm"].contains(mode) else { return coverage(.unsupportedInput, thread: thread, now: now) }
            }
            guard let id else { return coverage(.unsupportedInput, thread: thread, now: now) }
            guard inputs[id] == nil, approvals[id].map({ $0.thread == thread }) ?? true else { return coverage(.unsupportedInput, thread: thread, now: now) }
            guard approvals[id] != nil || inputs.count + approvals.count < 512 else { return coverage(.requestLimit, thread: thread, now: now) }
            let request = "protocol-approval-" + StableDigest.hex(Data("\(binding.id):\(id)".utf8))
            approvals[id] = (thread, request)
            // Delivered to this TUI is stronger than an early Hook, but not yet
            // certified as truly human-pending in every approval reviewer mode.
            return [event(.approvalRequested, thread: thread, turn: turn, request: request, now: now)]
        case "item/tool/requestUserInput":
            guard let id, let item = textID(params["itemId"]), let turn,
                  let blocking = params["isBlocking"] as? NSNumber, CFGetTypeID(blocking) == CFBooleanGetTypeID(),
                  let questions = params["questions"] as? [[String: Any]], (1...64).contains(questions.count) else {
                return coverage(.unsupportedInput, thread: thread, now: now)
            }
            var rawIDs: [String] = []
            for question in questions {
                guard let raw = question["id"] as? String, !raw.isEmpty, raw.utf8.count <= 512, !rawIDs.contains(raw) else {
                    return coverage(.unsupportedInput, thread: thread, now: now)
                }
                rawIDs.append(raw)
            }
            if !blocking.boolValue {
                guard inputs[id] == nil, approvals[id] == nil else { return coverage(.unsupportedInput, thread: thread, now: now) }
                // A queued RPC can finish before any answer. Only the pinned
                // async envelope shares IDs/deduplication with agentMessage.
                let canonical = questions.indices.compactMap { index in
                    (try? JSONSerialization.data(withJSONObject: ["request_user_input_async", item, index], options: .withoutEscapingSlashes)).map { String(decoding: $0, as: UTF8.self) }
                }
                guard rawIDs == canonical else { return coverage(.unsupportedInput, thread: thread, now: now) }
                var queued = event(.questionQueued, thread: thread, turn: turn, questions: canonical, now: now)
                queued.id = "bridge-question-" + StableDigest.hex((try? JSONEncoder().encode([thread, item])) ?? Data())
                return [queued]
            }
            return inputRequest(id, thread: thread, turn: turn, keys: rawIDs.map { inputKey(id, thread: thread, components: ["sync", item, $0]) }, now: now)
        case "serverRequest/resolved":
            guard let id = identifier(params["requestId"]) else { return [] }
            if let approval = approvals[id], approval.thread == thread {
                approvals.removeValue(forKey: id)
                return [event(.requestResolved, thread: thread, turn: turn, request: approval.request, now: now)]
            }
            if let input = inputs[id], input.thread == thread {
                inputs.removeValue(forKey: id)
                // The server cleared this blocking/form prompt, possibly on
                // interruption. This does not prove an answer or successful auth.
                return [event(.requestResolved, thread: thread, turn: turn, questions: input.questions, now: now)]
            }
            return []
        case "item/completed":
            guard let item = params["item"] as? [String: Any] else { return [] }
            // The pinned ThreadItem schema serializes a normal agent reply's
            // optional questions as null. It declares no input request.
            let declaresQuestions = item["questions"] != nil && !(item["questions"] is NSNull)
            guard let itemID = textID(item["id"]) else {
                return item["type"] as? String == "agentMessage" && declaresQuestions ? coverage(.unsupportedInput, thread: thread, now: now) : []
            }
            if item["type"] as? String == "agentMessage", declaresQuestions {
                guard let questions = item["questions"] as? [[String: Any]], questions.count <= 64 else { return coverage(.unsupportedInput, thread: thread, now: now) }
                if questions.isEmpty { return [] }
                let ids = questions.indices.compactMap { index -> String? in
                    guard let data = try? JSONSerialization.data(withJSONObject: ["request_user_input_async", itemID, index], options: [.withoutEscapingSlashes]) else { return nil }
                    return String(decoding: data, as: UTF8.self)
                }
                var queued = event(.questionQueued, thread: thread, turn: turn, questions: ids, now: now)
                queued.id = "bridge-question-" + StableDigest.hex((try? JSONEncoder().encode([thread, itemID])) ?? Data())
                return [queued]
            }
            if item["type"] as? String == "userMessage", let content = item["content"] as? [[String: Any]], content.count <= 64 {
                let ids = submittedQuestionIDs(content)
                if !ids.isEmpty { return [event(.requestResolved, thread: thread, turn: turn, questions: ids, now: now)] }
            }
            return []
        default:
            if id != nil, let method, !Self.nonInteractiveServerRequests.contains(method) {
                return coverage(.unsupportedRequest, thread: thread, now: now)
            }
            return []
        }
    }
    /// A gap/close revokes routing and marks uncertainty; never ends the thread.
    public mutating func disconnect(now: Date = Date(), recoveringUntil: Date? = nil) -> [AgentEvent] {
        guard !stopped else { return [] }; stopped = true
        return threads.sorted().map {
            var value = event(.sourceLost, thread: $0, now: now)
            value.transportRecoveryDeadline = recoveringUntil
            return value
        }
    }
    public mutating func observationGap(now: Date = Date()) -> [AgentEvent] {
        guard !stopped else { return [] }
        pendingStarts.removeAll()
        return threads.sorted().map { event(.observationGap, thread: $0, now: now) }
    }
    /// Only a correlated response to a known metadata-only RPC can be skipped
    /// without declaring a lifecycle gap. Unknown IDs/notifications stay uncertain.
    public mutating func ignoreOversizedServerResponse(_ prefix: Data) -> Bool {
        guard let id = JSONRPCPrefix.responseID(prefix), let method = ignoredResponses.removeValue(forKey: id) else { return false }
        ignoredOversizedMethods[method, default: 0] += 1
        return true
    }
}

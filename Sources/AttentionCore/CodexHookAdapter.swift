import Foundation
import CryptoKit

/// An allowlist: prompts, tool commands/results, question titles/options and transcript paths never leave this adapter.
public enum CodexHookAdapter {
    public static func events(data: Data, environment: [String: String], now: Date = Date(), processOriginHint: ProcessOriginHint? = nil) throws -> [AgentEvent] {
        guard data.count <= 1_048_576 else { throw RouterError.oversizedPayload }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["hook_event_name"] as? String,
              let session = object["session_id"] as? String, !session.isEmpty else { throw RouterError.invalidEvent }
        let turn = object["turn_id"] as? String
        let tool = object["tool_name"] as? String ?? ""
        let call = object["tool_use_id"] as? String
        let terminal = environment["ITERM_SESSION_ID"].flatMap { value -> TerminalIdentity? in
            let identity = TerminalIdentity(sessionID: value); return identity.guid == nil ? nil : identity
        }
        // Diagnostic hints remain unverified. A shared daemon can inherit another
        // TUI's environment; neither variable is sufficient origin evidence alone.
        var hints: [TerminalIdentity] = []
        for key in ["ITERM_SESSION_ID", "TERM_SESSION_ID"] {
            if let value = environment[key] {
                let hint = TerminalIdentity(sessionID: value)
                if hint.guid != nil && !hints.contains(where: { $0.guid == hint.guid }) { hints.append(hint) }
            }
        }
        let project = (object["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown project"
        let kind: EventKind
        var questionIDs: [String] = []
        switch name {
        case "SessionStart": kind = .sessionStarted
        case "UserPromptSubmit":
            kind = .inputSubmitted
            questionIDs = CodexReplyMetadata.submittedIDs(object["prompt"] as? String)
        case "Stop": kind = .turnStopped
        case "Interrupt": kind = .interrupted
        case "SessionEnd": kind = .sessionEnded
        case "PermissionRequest": kind = .approvalRequested
        case "PostToolUse":
            let canonical = tool.components(separatedBy: ".").last ?? tool
            if canonical == "request_user_input_async" {
                guard let call, !call.isEmpty,
                      let input = object["tool_input"] as? [String: Any],
                      let questions = input["questions"] as? [[String: Any]], !questions.isEmpty, questions.count <= 64,
                      accepted(object["tool_response"]) else { return [] }
                kind = .questionQueued
                questionIDs = try questions.indices.map { index in
                    let data = try JSONSerialization.data(withJSONObject: ["request_user_input_async", call, index], options: [.fragmentsAllowed, .withoutEscapingSlashes])
                    return String(decoding: data, as: UTF8.self)
                }
            } else { kind = .activity }
        default: return []
        }
        // A call ID is stable. A turn ID alone is not an event ID: Stop can run
        // repeatedly when another Hook continues a turn, as can same-turn input.
        let discriminator = call ?? UUID().uuidString
        let idData = try JSONSerialization.data(withJSONObject: [session, turn ?? "", name, tool, discriminator])
        let id = SHA256.hash(data: idData).map { String(format: "%02x", $0) }.joined()
        let event = AgentEvent(id: id, kind: kind, sessionID: session, turnID: turn,
            requestID: kind == .approvalRequested ? call : nil, questionIDs: questionIDs,
            terminal: terminal, terminalHints: hints, processOriginHint: processOriginHint,
            project: String(project.prefix(128)), timestamp: now)
        try event.validate(); return [event]
    }

    private static func accepted(_ value: Any?) -> Bool {
        if let object = value as? [String: Any] { return object["accepted"] as? Bool == true }
        if let text = value as? String, let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object["accepted"] as? Bool == true
        }
        return false
    }
}

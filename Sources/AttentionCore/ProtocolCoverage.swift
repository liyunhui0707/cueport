import Foundation

/// A bounded diagnostic about observation coverage, not an outstanding question,
/// proof of human waiting, answer, or terminal authorization.
public enum ProtocolCoverageIssue: String, Codable, Hashable, Sendable {
    case unsupportedRequest, unsupportedInput, requestLimit, unscopedRequest
    public var explanation: String {
        switch self {
        case .unsupportedRequest: "An interaction was not recognized. Check the original Codex session."
        case .unsupportedInput: "An input request had an unsupported shape. Check the original Codex session."
        case .requestLimit: "Interaction tracking reached its safety limit. Check pending prompts in Codex."
        case .unscopedRequest: "This bridge received an interaction without a verified thread. Check the original Codex connection."
        }
    }
}

public struct ProtocolCoverageNotice: Codable, Equatable, Sendable {
    public let id: String
    public let issue: ProtocolCoverageIssue
    public let observedAt: Date
    public var reviewed: Bool
    public init(id: String, issue: ProtocolCoverageIssue, observedAt: Date, reviewed: Bool = false) {
        self.id = id; self.issue = issue; self.observedAt = observedAt; self.reviewed = reviewed
    }
    public var detail: String {
        issue.explanation + "\n" + (reviewed ? "Notice reviewed; coverage remains unconfirmed." : "Coverage notice unreviewed; no answer or approval was inferred.")
    }
}

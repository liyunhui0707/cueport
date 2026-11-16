import Foundation

/// Version-specific editor reply envelope. Only canonical IDs leave this parser.
/// It observes submission intent; a pre-submit Hook cannot certify acceptance.
enum CodexReplyMetadata {
    private struct QuestionID: Decodable {
        let call: String
        let index: Int
        init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            let tool = try values.decode(String.self)
            call = try values.decode(String.self); index = try values.decode(Int.self)
            guard values.isAtEnd, tool == "request_user_input_async", !call.isEmpty,
                  call.utf8.count <= 256, (0..<64).contains(index) else { throw RouterError.invalidEvent }
        }
    }
    static func submittedIDs(_ prompt: String?) -> [String] {
        guard let prompt else { return [] }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = "<send_user_message_question_reply>"
        let end = "</send_user_message_question_reply>"
        guard text.hasPrefix(start), text.hasSuffix(end), text.utf8.count <= 1_048_576 else { return [] }
        let body = String(text.dropFirst(start.count).dropLast(end.count))
        guard let replies = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [[String: Any]],
              !replies.isEmpty, replies.count <= 64 else { return [] }
        var ids: [String] = []
        for reply in replies {
            guard let raw = reply["questionItemId"] as? String, raw.utf8.count <= 512,
                  let answer = reply["answer"] as? String, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let id = try? JSONDecoder().decode(QuestionID.self, from: Data(raw.utf8)),
                  let canonical = try? JSONSerialization.data(withJSONObject: ["request_user_input_async", id.call, id.index], options: .withoutEscapingSlashes) else { return [] }
            let value = String(decoding: canonical, as: UTF8.self)
            if !ids.contains(value) { ids.append(value) }
        }
        return ids
    }
}

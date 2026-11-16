import Foundation
import CoreFoundation

/// Reads only an ID before the top-level result/error field, within a 4 KiB
/// prefix. Never searches nested bodies or mistakes a server request for a reply.
enum JSONRPCPrefix {
    static func responseID(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(4096)); var index = 0
        func whitespace(_ value: UInt8) -> Bool { [9, 10, 13, 32].contains(value) }
        func skip() { while index < bytes.count && whitespace(bytes[index]) { index += 1 } }
        func string() -> String? {
            guard index < bytes.count, bytes[index] == 34 else { return nil }
            let start = index; index += 1
            while index < bytes.count {
                if bytes[index] == 92 { index += 2; continue }
                if bytes[index] == 34 {
                    index += 1
                    return (try? JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed])) as? String
                }
                index += 1
            }
            return nil
        }
        skip(); guard index < bytes.count, bytes[index] == 123 else { return nil }; index += 1
        var id: String?, seen: Set<String> = []
        for _ in 0..<3 {
            skip(); guard let key = string(), seen.insert(key).inserted else { return nil }
            skip(); guard index < bytes.count, bytes[index] == 58 else { return nil }; index += 1
            if key == "result" || key == "error" { return id }
            guard key == "id" || key == "jsonrpc" else { return nil }
            skip(); let start = index
            if index < bytes.count && bytes[index] == 34 { guard string() != nil else { return nil } }
            else { while index < bytes.count && ![44, 125, 9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
            guard index > start, let value = try? JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed]) else { return nil }
            if key == "jsonrpc" { guard value as? String == "2.0" else { return nil } }
            else if let text = value as? String, !text.isEmpty, text.utf8.count <= 256 { id = "s:" + text }
            else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                    number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue { id = "n:" + number.stringValue }
            else { return nil }
            skip(); guard index < bytes.count, bytes[index] == 44 else { return nil }; index += 1
        }
        return nil
    }
}

import Foundation

public enum WebSocketObservation: Equatable, Sendable {
    case message(Data)
    case oversizedPrefix(Data)
}

/// Bounded passive tap. Original HTTP/WebSocket bytes are forwarded elsewhere.
/// Unsupported/oversized framing disables observation, never rewrites traffic.
public struct WebSocketTap {
    public private(set) var failed = false
    public private(set) var failureReason: String?
    public private(set) var gapCount = 0
    public private(set) var largestSkippedPayloadBytes: UInt64 = 0
    private let masked: Bool
    private let limit: Int
    private var upgraded = false
    private var buffer = Data()
    private var fragments = Data()
    private var fragmentOpen = false
    private var skipBytes: UInt64 = 0
    private var skipContinuation = false
    private var skipMask: [UInt8] = []
    private var skipOffset: UInt64 = 0
    private var skipPrefix = Data()
    private var prefixPending = false
    private var observations: [WebSocketObservation] = []
    private mutating func reportPrefix(force: Bool = false) {
        if prefixPending && (skipPrefix.count == 4096 || force) {
            observations.append(.oversizedPrefix(skipPrefix)); skipPrefix = Data(); prefixPending = false
        }
    }
    public init(masked: Bool, limit: Int = 1_048_576) { self.masked = masked; self.limit = limit }
    private mutating func fail(_ reason: String = "invalid-framing") { failed = true; failureReason = reason; buffer = Data(); fragments = Data() }
    public mutating func feed(_ bytes: Data) -> [Data] {
        feedEvents(bytes).compactMap { if case .message(let data) = $0 { data } else { nil } }
    }
    public mutating func feedEvents(_ bytes: Data) -> [WebSocketObservation] {
        observations.removeAll(keepingCapacity: true)
        guard !failed else { return [] }
        // Relay reads are bounded to 64 KiB. Also fail safely for oversized callers.
        guard bytes.count <= 65_536 else { fail("oversized-read"); return [] }
        buffer.append(bytes)
        if !upgraded {
            let delimiter = Data([13, 10, 13, 10])
            guard let end = buffer.range(of: delimiter) else {
                if buffer.count > 16_384 { fail("oversized-upgrade") }; return []
            }
            guard end.upperBound <= 16_384 else { fail("oversized-upgrade"); return [] }
            let header = String(decoding: buffer[..<end.upperBound], as: UTF8.self)
            guard masked ? header.hasPrefix("GET ") : header.hasPrefix("HTTP/1.1 101 "),
                  header.lowercased().contains("upgrade: websocket") else { fail("unsupported-upgrade"); return [] }
            buffer = Data(buffer[end.upperBound...]); upgraded = true
        }
        while true {
            if skipBytes > 0 {
                guard !buffer.isEmpty else { break }
                let count = min(skipBytes, UInt64(buffer.count))
                if prefixPending && skipPrefix.count < 4096 {
                    let raw = [UInt8](buffer.prefix(min(Int(count), 4096 - skipPrefix.count)))
                    skipPrefix.append(contentsOf: raw.enumerated().map {
                        skipMask.isEmpty ? $0.element : $0.element ^ skipMask[Int((skipOffset + UInt64($0.offset)) % 4)]
                    })
                }
                skipOffset += count
                buffer = Data(buffer.dropFirst(Int(count))); skipBytes -= count
                reportPrefix(force: skipBytes == 0 && !skipContinuation)
                if skipBytes > 0 { break }
                continue
            }
            guard buffer.count >= 2 else { break }
            let header = [UInt8](buffer.prefix(14))
            let final = header[0] & 0x80 != 0
            let opcode = header[0] & 0x0f
            guard header[0] & 0x70 == 0 else { fail("unsupported-extension"); break }
            guard (header[1] & 0x80 != 0) == masked else { fail("unexpected-masking"); break }
            var size = UInt64(header[1] & 0x7f)
            var offset = 2
            if size == 126 {
                guard header.count >= 4 else { break }
                size = UInt64(header[2]) << 8 | UInt64(header[3]); offset = 4
            } else if size == 127 {
                guard header.count >= 10, header[2] & 0x80 == 0 else { if header.count >= 10 { fail() }; break }
                size = header[2..<10].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }; offset = 10
            }
            guard [0, 1, 8, 9, 10].contains(opcode),
                  opcode < 8 || (final && size <= 125) else { fail(); break }
            let maskOffset = offset
            if masked { offset += 4 }
            guard buffer.count >= offset else { break }
            let exceedsLimit = size > limit || (opcode < 8 && UInt64(fragments.count) + size > UInt64(limit))
            if opcode < 8 && (exceedsLimit || skipContinuation) {
                guard (opcode == 1 && !fragmentOpen && !skipContinuation) || (opcode == 0 && (fragmentOpen || skipContinuation)) else { fail(); break }
                if !skipContinuation {
                    gapCount += 1; prefixPending = true; skipPrefix = Data(fragments.prefix(4096))
                }
                largestSkippedPayloadBytes = max(largestSkippedPayloadBytes, UInt64(fragments.count) + size)
                skipMask = masked ? Array(header[maskOffset..<(maskOffset + 4)]) : []
                skipOffset = 0
                skipContinuation = !final; fragmentOpen = false; fragments = Data()
                buffer = Data(buffer.dropFirst(offset)); skipBytes = size
                reportPrefix(force: size == 0 && final)
                continue
            }
            guard buffer.count >= offset + Int(size) else { break }
            let all = [UInt8](buffer.prefix(offset + Int(size)))
            var payload = Array(all[offset...])
            if masked {
                for index in payload.indices { payload[index] ^= all[maskOffset + index % 4] }
            }
            buffer = Data(buffer.dropFirst(offset + Int(size)))
            if opcode >= 8 { continue } // Control frames never contain JSON metadata.
            if opcode == 1 {
                guard !fragmentOpen else { fail(); break }
                fragments = Data(payload)
            } else {
                guard fragmentOpen else { fail(); break }
                fragments.append(contentsOf: payload)
            }
            fragmentOpen = !final
            if final { observations.append(.message(fragments)); fragments = Data() }
        }
        return observations
    }
}

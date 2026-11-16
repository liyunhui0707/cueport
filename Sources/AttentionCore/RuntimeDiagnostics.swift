import Foundation
import MachO

/// Thin 64-bit little-endian Mach-O, matching the supported local build.
/// Unknown formats are unverified, never assumed to match a running image.
public enum MachOBuildIdentity {
    public static let maximumHeaderBytes = 1_048_576
    public static func fileUUID(_ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 32), header.count == 32,
              Array(header.prefix(4)) == [0xcf, 0xfa, 0xed, 0xfe] else { return nil }
        let bytes = Array(header)
        let size = Int(bytes[20]) | Int(bytes[21]) << 8 | Int(bytes[22]) << 16 | Int(bytes[23]) << 24
        guard size >= 8, size <= maximumHeaderBytes - 32,
              let commands = try? handle.read(upToCount: size), commands.count == size else { return nil }
        return uuid(in: header + commands)
    }
    public static func canonicalUUID(_ value: String?) -> String? {
        guard let value, let uuid = UUID(uuidString: value), uuid.uuidString != "00000000-0000-0000-0000-000000000000" else { return nil }
        return uuid.uuidString
    }
    public static func loadedUUID() -> String? {
        guard let image = _dyld_get_image_header(0), image.pointee.magic == MH_MAGIC_64 else { return nil }
        let size = Int(image.pointee.sizeofcmds) + MemoryLayout<mach_header_64>.size
        guard size >= 32, size <= maximumHeaderBytes else { return nil }
        // The mapped main image survives atomic replacement of the executable.
        return uuid(in: Data(bytes: image, count: size))
    }
    public static func uuid(in data: Data) -> String? {
        let bytes = Array(data.prefix(maximumHeaderBytes))
        guard bytes.count >= 32, Array(bytes[0..<4]) == [0xcf, 0xfa, 0xed, 0xfe] else { return nil }
        func word(_ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        let count = word(16), size = word(20), end = 32 + size
        guard count > 0, count <= size / 8, end <= bytes.count else { return nil }
        var offset = 32, result: String?
        for _ in 0..<count {
            guard offset + 8 <= end else { return nil }
            let command = word(offset), length = word(offset + 4)
            guard length >= 8, length <= end - offset else { return nil }
            if command == 0x1b { // LC_UUID
                guard length == 24, result == nil else { return nil }
                let value = bytes[(offset + 8)..<(offset + 24)]
                guard value.contains(where: { $0 != 0 }) else { return nil }
                let digits = Array("0123456789ABCDEF".utf8)
                var textBytes = [UInt8](); textBytes.reserveCapacity(36)
                for (index, byte) in value.enumerated() {
                    if index == 4 || index == 6 || index == 8 || index == 10 { textBytes.append(45) }
                    textBytes.append(digits[Int(byte >> 4)])
                    textBytes.append(digits[Int(byte & 15)])
                }
                let text = String(decoding: textBytes, as: UTF8.self)
                result = UUID(uuidString: text)?.uuidString
            }
            offset += length
        }
        return offset == end ? result : nil
    }
}

/// Advisory build comparison only. Never authorizes routing, resolves requests,
/// proves process liveness or substitutes for the fresh exact-origin checks.
public struct BridgeWorkerBuildStatus: Equatable, Sendable {
    public enum Status: String, Sendable { case current, reconnectNeeded, unverified, helperUnavailable, disconnected, ambiguous, notRegistered, conflicting }
    public let status: Status
    public let running: String?
    public let installed: String?
    public init(session: AgentSession, installedHelper: String?) {
        installed = MachOBuildIdentity.canonicalUUID(installedHelper)
        let bindings = Array((session.protocolBindings ?? [:]).values)
        let active = bindings.filter(\.connected)
        running = active.count == 1 ? MachOBuildIdentity.canonicalUUID(active[0].workerBuildUUID) : nil
        if bindings.isEmpty { status = .notRegistered }
        else if active.isEmpty { status = .disconnected }
        else if active.count > 1 { status = .ambiguous }
        else if active[0].workerBuildConflict == true { status = .conflicting }
        else if installed == nil { status = .helperUnavailable }
        else if running == nil { status = .unverified }
        else { status = running == installed ? .current : .reconnectNeeded }
    }
    public var summary: String {
        switch status {
        case .current: "Bridge build matches this app"
        case .reconnectNeeded: "Bridge build differs · Reconnect when ready"
        case .unverified: "Bridge build unverified · Reconnect to verify"
        case .helperUnavailable: "Installed bridge build unavailable"
        case .disconnected: "Bridge disconnected"
        case .ambiguous: "Multiple bridge connections · Build unverified"
        case .notRegistered: "No registered bridge connection"
        case .conflicting: "Bridge build reports conflict · Reconnect to verify"
        }
    }
    public var detail: String {
        var lines = [summary]
        if let running { lines.append("Reported worker · " + running) }
        if let installed { lines.append("Installed helper · " + installed) }
        switch status {
        case .reconnectNeeded, .unverified, .conflicting:
            lines.append("Finish current work in Codex, then start a new connected client and resume the thread yourself. Restarting this app does not update an existing bridge.")
        case .helperUnavailable:
            lines.append("The packaged helper could not be identified. Check the app installation before reconnecting.")
        case .ambiguous:
            lines.append("More than one connection reports this thread. Exact return remains unavailable until the source is unique.")
        case .disconnected, .notRegistered:
            lines.append("Start a connected client from the project directory to establish a new source.")
        case .current:
            lines.append("Build match only. Live terminal identity and request state are checked separately.")
        }
        return lines.joined(separator: "\n")
    }
}

public struct BuildStatus: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case current, restartNeeded, unverified }
    public let running: String?
    public let onDisk: String?
    public init(running: String?, onDisk: String?) { self.running = running; self.onDisk = onDisk }
    public var status: Status {
        guard let running, let onDisk else { return .unverified }
        return running == onDisk ? .current : .restartNeeded
    }
}

public struct NotificationSubmissionObservation: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case accepted, failed }
    public let outcome: Outcome
    public let recordedAt: Date
    public init(outcome: Outcome, recordedAt: Date) { self.outcome = outcome; self.recordedAt = recordedAt }
}

public struct NotificationSaveFailure: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable { case reservation, receipt }
    public let stage: Stage
    public let recordedAt: Date
    public init(stage: Stage, recordedAt: Date) { self.stage = stage; self.recordedAt = recordedAt }
}

/// Counts refer to reminders, not question counts or proof of human waiting.
public struct NotificationDeliveryHealth: Codable, Equatable, Sendable {
    public var waiting = 0
    public var retrying = 0
    public var submitting = 0
    public var receiptsAwaitingSave = 0
    public var nextRetryAt: Date?
    public var lastSubmission: NotificationSubmissionObservation?
    public var lastSaveFailure: NotificationSaveFailure?
    public init() {}
}

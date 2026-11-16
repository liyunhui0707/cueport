import Foundation
import Darwin

/// Metadata only. No argv, environment, terminal input or process memory.
public struct ProcessOriginHint: Codable, Equatable, Sendable {
    public var pid: Int32
    public var uid: UInt32
    public var startMicroseconds: UInt64
    public var processGroup: UInt32
    public var terminalGroup: UInt32
    public var terminalDevice: UInt32
    public var hasControllingTerminal: Bool
    public var isCodex: Bool
    public var capturedAt: Date
    public init(pid: Int32, uid: UInt32, startMicroseconds: UInt64, processGroup: UInt32,
                terminalGroup: UInt32, terminalDevice: UInt32, hasControllingTerminal: Bool,
                isCodex: Bool, capturedAt: Date = Date()) {
        self.pid = pid; self.uid = uid; self.startMicroseconds = startMicroseconds
        self.processGroup = processGroup; self.terminalGroup = terminalGroup
        self.terminalDevice = terminalDevice; self.hasControllingTerminal = hasControllingTerminal
        self.isCodex = isCodex; self.capturedAt = capturedAt
    }
    public var isDirectForegroundCandidate: Bool {
        pid > 1 && isCodex && startMicroseconds > 0 && hasControllingTerminal &&
            terminalDevice != UInt32.max && terminalDevice != 0 &&
            UInt32(pid) == processGroup && processGroup == terminalGroup
    }
    /// Opaque reference for a single OS process lifetime, not just a reusable PID.
    public var instanceID: String {
        StableDigest.hex(Data("\(uid):\(pid):\(startMicroseconds)".utf8))
    }
}

public enum ProcessOriginProbe {
    private static func snapshotAndParent(_ pid: Int32, now: Date) -> (ProcessOriginHint, Int32)? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let count = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(size)) }
        guard count == size, info.pbi_uid == getuid() else { return nil }
        let bytes = withUnsafeBytes(of: info.pbi_comm) { Array($0) }
        let name = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        return (ProcessOriginHint(pid: pid, uid: info.pbi_uid,
            startMicroseconds: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec,
            processGroup: info.pbi_pgid, terminalGroup: info.e_tpgid, terminalDevice: info.e_tdev,
            hasControllingTerminal: info.pbi_flags & UInt32(PROC_FLAG_CTTY) != 0,
            isCodex: name == "codex", capturedAt: now), Int32(info.pbi_ppid))
    }
    public static func snapshot(_ pid: Int32, now: Date = Date()) -> ProcessOriginHint? {
        snapshotAndParent(pid, now: now)?.0
    }
    public static func nearestCodexAncestor(now: Date = Date()) -> ProcessOriginHint? {
        var pid = getppid()
        var visited: Set<Int32> = []
        for _ in 0..<16 {
            guard visited.insert(pid).inserted, let (hint, parent) = snapshotAndParent(pid, now: now) else { return nil }
            // Do not skip a detached/background Codex daemon to find an older
            // foreground TUI in its ancestry: that would bind the wrong client.
            if hint.isCodex { return hint }
            pid = parent
        }
        return nil
    }
    public static func terminalDevice(_ path: String) -> UInt32? {
        guard path.range(of: #"^/dev/ttys[0-9A-Za-z]+$"#, options: .regularExpression) != nil else { return nil }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFCHR,
              info.st_uid == getuid() else { return nil }
        return UInt32(bitPattern: info.st_rdev)
    }
}

public struct VerifiedTerminalOrigin: Codable, Equatable, Sendable {
    public let terminal: TerminalIdentity
    public let process: ProcessOriginHint
    public init(terminal: TerminalIdentity, process: ProcessOriginHint) {
        self.terminal = terminal; self.process = process
    }
}

public enum ProcessOriginVerifier {
    /// A previously recorded binding must never follow a reused TTY to a new pane.
    public static func revalidate(_ origin: VerifiedTerminalOrigin, live: ProcessOriginHint?,
                                  sessions: [TerminalSession], devices: [String: UInt32],
                                  currentUID: UInt32) throws -> TerminalSession {
        let fresh = try match(hint: origin.process, live: live, sessions: sessions,
                              devices: devices, currentUID: currentUID)
        guard fresh.terminal.guid == origin.terminal.guid else { throw RouterError.unverifiedOrigin }
        return try SessionLocator.exact(origin.terminal, in: sessions)
    }
    /// Experimental direct-TUI gate. The environment GUID is deliberately absent.
    public static func match(hint: ProcessOriginHint?, live: ProcessOriginHint?,
                             sessions: [TerminalSession], devices: [String: UInt32],
                             currentUID: UInt32) throws -> VerifiedTerminalOrigin {
        guard let hint, let live, hint.isDirectForegroundCandidate,
              live.isDirectForegroundCandidate, hint.uid == currentUID, live.uid == currentUID,
              hint.pid == live.pid, hint.startMicroseconds == live.startMicroseconds,
              hint.terminalDevice == live.terminalDevice else { throw RouterError.unverifiedOrigin }
        let matches = sessions.filter { session in
            guard let tty = session.tty, let device = devices[tty] else { return false }
            return device == live.terminalDevice && UUID(uuidString: session.id) != nil
        }
        guard !matches.isEmpty else { throw RouterError.sessionNotFound }
        guard matches.count == 1 else { throw RouterError.ambiguousSession }
        return VerifiedTerminalOrigin(terminal: TerminalIdentity(sessionID: matches[0].id), process: live)
    }
}

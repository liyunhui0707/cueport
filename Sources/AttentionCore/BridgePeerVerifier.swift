import Darwin

/// Kernel socket credentials only. A match still requires a fresh process-life
/// and exact iTerm identity check before any new connection is admitted.
public enum BridgePeerVerifier {
    public static func matches(_ socket: Int32, pid expectedPID: Int32, uid expectedUID: UInt32) -> Bool {
        guard socket >= 0, expectedPID > 1 else { return false }
        var uid: uid_t = 0, gid: gid_t = 0, pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        return getpeereid(socket, &uid, &gid) == 0 && uid == expectedUID &&
            getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 && pid == expectedPID
    }
}

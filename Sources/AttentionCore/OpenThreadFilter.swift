import Foundation
import Darwin

public enum RegisteredProcessStatus: Sendable {
    case present(ProcessOriginHint)
    case absent
    case unavailable
}

/// Presentation only. An open registered process does not prove a request is
/// pending, identify the displayed thread or authorize terminal navigation.
public struct OpenThreadFilter: Sendable {
    public let visibleThreadIDs: Set<String>
    public let unavailableProcessIDs: Set<Int32>

    public init(state: RouterState, processes: [Int32: RegisteredProcessStatus], currentUID: UInt32) {
        var visible = Set<String>(), unavailable = Set<Int32>()
        for session in state.sessions.values {
            for entry in (session.protocolBindings ?? [:]).values where entry.connected || entry.recoveryDeadline != nil {
                guard (try? entry.binding.validate()) != nil else { continue }
                let expected = entry.binding.origin.process
                switch processes[expected.pid] ?? .unavailable {
                case .present(let actual):
                    // A suspended/background job is not an exited client. Do not
                    // turn terminal foreground-group changes into disappearance.
                    if actual.uid == currentUID, expected.uid == currentUID,
                       actual.instanceID == expected.instanceID, actual.isCodex,
                       actual.hasControllingTerminal, actual.terminalDevice == expected.terminalDevice {
                        visible.insert(session.id)
                    }
                case .absent: break
                case .unavailable:
                    // A failed inspection is not proof of exit. Retain the
                    // registered record and expose a separate check warning.
                    visible.insert(session.id); unavailable.insert(expected.pid)
                }
            }
        }
        visibleThreadIDs = visible; unavailableProcessIDs = unavailable
    }

    /// Only inspect already registered PIDs. kill(pid, 0) sends no signal; it
    /// distinguishes a missing process from a denied/unavailable metadata read.
    public static func inspect(_ pid: Int32) -> RegisteredProcessStatus {
        guard pid > 1 else { return .absent }
        if let snapshot = ProcessOriginProbe.snapshot(pid) { return .present(snapshot) }
        if Darwin.kill(pid, 0) == -1 && errno == ESRCH { return .absent }
        return .unavailable
    }
}

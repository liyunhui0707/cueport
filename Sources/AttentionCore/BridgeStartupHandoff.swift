/// Permit only one sequential connection handoff, before any thread session or
/// turn intent/registration, with an intact observer and a client-originated EOF.
/// This never identifies a thread, grants routing or admits a different process.
public enum BridgeStartupHandoff {
    public static func permits(pickerLaunch: Bool, connectionIndex: Int,
                               end: BridgeRelay.EndReason, observerHealthy: Bool,
                               eventCount: Int, hasThreadSessionRequest: Bool) -> Bool {
        pickerLaunch && connectionIndex == 1 && end == .clientClosed && observerHealthy
            && eventCount == 0 && !hasThreadSessionRequest
    }
}

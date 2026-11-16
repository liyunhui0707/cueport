import XCTest
import Darwin
@testable import AttentionCore

final class BridgeStartupHandoffTests: XCTestCase {
    func testOnlyPickerLaunchPermitsOnePreThreadClientClosedHandoff() throws {
        XCTAssertTrue(try BridgeLaunchOptions(codexArguments: ["resume"]).permitsStartupPickerHandoff)
        XCTAssertFalse(try BridgeLaunchOptions(codexArguments: []).permitsStartupPickerHandoff)
        XCTAssertFalse(try BridgeLaunchOptions(codexArguments: ["resume", "12345678-1234-1234-1234-123456789abc"]).permitsStartupPickerHandoff)
        func permits(_ picker: Bool = true, _ index: Int = 1, _ end: BridgeRelay.EndReason = .clientClosed,
                     _ healthy: Bool = true, _ events: Int = 0, _ intent: Bool = false) -> Bool {
            BridgeStartupHandoff.permits(pickerLaunch: picker, connectionIndex: index, end: end,
                observerHealthy: healthy, eventCount: events, hasThreadSessionRequest: intent)
        }
        XCTAssertTrue(permits())
        XCTAssertFalse(permits(false)); XCTAssertFalse(permits(true, 2)); XCTAssertFalse(permits(true, 0))
        XCTAssertFalse(permits(true, 1, .upstreamClosed)); XCTAssertFalse(permits(true, 1, .stopped))
        XCTAssertFalse(permits(true, 1, .clientClosed, false))
        XCTAssertFalse(permits(true, 1, .clientClosed, true, 1))
        XCTAssertFalse(permits(true, 1, .clientClosed, true, 0, true))
    }

    func observer() -> CodexProtocolObserver {
        let process = ProcessOriginHint(pid: 500, uid: 501, startMicroseconds: 10,
            processGroup: 500, terminalGroup: 500, terminalDevice: 20, hasControllingTerminal: true, isCodex: true)
        return .init(binding: .init(id: "synthetic-picker", origin: .init(
            terminal: .init(sessionID: "12345678-1234-1234-1234-123456789ABC"), process: process)), project: "Synthetic")
    }
    func message(_ method: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": 1, "method": method, "params": [:]])
    }
    func testFailedOrUnscopedThreadIntentPreventsHandoffWhileReadsDoNot() throws {
        for method in ["thread/start", "thread/resume", "thread/fork", "thread/unsubscribe", "turn/start", "turn/steer"] {
            var o = observer()
            _ = o.observe(try message(method), from: .client)
            _ = o.observe(Data("{\"id\":1,\"error\":{\"code\":-1}}".utf8), from: .server)
            XCTAssertTrue(o.hasThreadSessionRequest, method)
        }
        var o = observer()
        for method in ["initialize", "thread/list", "thread/read", "model/list", "account/read"] {
            _ = o.observe(try message(method), from: .client)
        }
        XCTAssertFalse(o.hasThreadSessionRequest)
    }
    func testInteractiveServerRequestWithoutThreadStillPreventsHandoff() throws {
        var o = observer()
        XCTAssertTrue(o.observe(try message("item/commandExecution/requestApproval"), from: .server).isEmpty)
        XCTAssertTrue(o.hasThreadSessionRequest)
        var nonInteractive = observer()
        _ = nonInteractive.observe(try message("currentTime/read"), from: .server)
        XCTAssertFalse(nonInteractive.hasThreadSessionRequest)
    }
    func testRelayReportsFirstEOFAndDistinguishesAnExplicitStop() throws {
        for expected in [BridgeRelay.EndReason.clientClosed, .upstreamClosed, .stopped] {
            var client: [Int32] = [0, 0], server: [Int32] = [0, 0]
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &client), 0)
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &server), 0)
            defer { (client + server).forEach { close($0) } }
            if expected == .clientClosed { shutdown(client[0], SHUT_WR) }
            if expected == .upstreamClosed { shutdown(server[1], SHUT_WR) }
            let deadline = Date().addingTimeInterval(0.2)
            let actual = try BridgeRelay.run(clientRead: client[1], clientWrite: client[1],
                upstreamRead: server[0], upstreamWrite: server[0],
                shouldStop: { expected == .stopped || Date() >= deadline }, observe: { _, _ in })
            XCTAssertEqual(actual, expected)
        }
    }
}

import XCTest
@testable import AttentionCore

final class RoutingAttemptTests: XCTestCase {
    func testRetiredNotificationCannotFollowResumedThreadOrSharedSource() throws {
        let old = ProtocolOriginBinding(id: "old-subscription", origin: .init(
            terminal: .init(sessionID: "12345678-1234-1234-1234-123456789ABC"),
            process: .init(pid: 500, uid: 501, startMicroseconds: 100, processGroup: 500,
                terminalGroup: 500, terminalDevice: 20, hasControllingTerminal: true,
                isCodex: true, capturedAt: Date())))
        let new = ProtocolOriginBinding(id: "new-subscription", origin: old.origin)
        var state = RouterState(); let now = Date()
        try state.apply(.init(kind: .sessionStarted, sessionID: "s", protocolBinding: old, timestamp: now, source: "codex-protocol"))
        XCTAssertEqual(try ProtocolRoute.authorize(state.sessions["s"]!, reference: old.reference), old)
        try state.apply(.init(kind: .sourceLost, sessionID: "s", protocolBinding: old, timestamp: now.addingTimeInterval(1), source: "codex-protocol"))
        XCTAssertThrowsError(try ProtocolRoute.authorize(state.sessions["s"]!, reference: old.reference))
        try state.apply(.init(kind: .sessionStarted, sessionID: "s", protocolBinding: new, timestamp: now.addingTimeInterval(2), source: "codex-protocol"))
        XCTAssertThrowsError(try ProtocolRoute.authorize(state.sessions["s"]!, reference: old.reference))
        XCTAssertEqual(try ProtocolRoute.authorize(state.sessions["s"]!, reference: new.reference), new)
        try state.apply(.init(kind: .sessionStarted, sessionID: "s", protocolBinding: .init(id: "shared", origin: old.origin), timestamp: now.addingTimeInterval(3), source: "codex-protocol"))
        XCTAssertThrowsError(try ProtocolRoute.authorize(state.sessions["s"]!, reference: new.reference))
    }
    func testRoutingAuditIsBoundedAndSurvivesSnapshotRoundTrip() throws {
        var state = RouterState()
        for i in 0..<105 {
            state.recordRoutingAttempt(.init(sessionID: "session", requestedSource: "source", currentSource: nil,
                notificationClick: true, outcome: .refused, timestamp: Date(timeIntervalSince1970: Double(i))))
        }
        let decoded = try JSONDecoder().decode(RouterState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.routingAttempts?.count, 100)
        XCTAssertEqual(decoded.routingAttempts?.first?.timestamp, Date(timeIntervalSince1970: 5))
        XCTAssertEqual(decoded.routingAttempts?.last?.outcome, .refused)
    }
    func testAuditOmitsRawSourceReferencesAndShortArbitraryIdentifiers() throws {
        let attempt = RoutingAttempt(sessionID: "SECRET", requestedSource: "SECRET-SOURCE", currentSource: "SECRET-CURRENT",
            notificationClick: true, outcome: .sourceChanged)
        let encoded = String(decoding: try JSONEncoder().encode(attempt), as: UTF8.self)
        XCTAssertFalse(encoded.contains("SECRET"))
        XCTAssertNotEqual(attempt.requestedSourceKey, attempt.currentSourceKey)
        XCTAssertEqual(attempt.sessionKey.count, 64)
    }
}

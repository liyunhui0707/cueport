import XCTest
@testable import AttentionCore

final class RoutingAttemptTests: XCTestCase {
    func testLatencyKeepsLegacyAuditAndDoesNotCountFailuresOrUntimedVisits() throws {
        let legacy = Data(#"{"timestamp":0,"sessionKey":"hash","displayReference":"sample","notificationClick":true,"outcome":"dispatched"}"#.utf8)
        let old = try JSONDecoder().decode(RoutingAttempt.self, from: legacy)
        XCTAssertNil(old.elapsedMilliseconds)
        var attempts = [old]
        for index in 1...20 {
            attempts.append(.init(sessionID: "s", requestedSource: "same-origin", currentSource: "same-origin",
                notificationClick: true, outcome: .dispatched, elapsedMilliseconds: Double(index)))
        }
        attempts.append(.init(sessionID: "s", requestedSource: nil, currentSource: nil,
            notificationClick: true, outcome: .dispatchFailed, elapsedMilliseconds: 9999))
        attempts.append(.init(sessionID: "s", requestedSource: nil, currentSource: nil,
            notificationClick: false, outcome: .dispatched, elapsedMilliseconds: 9999))
        let result = LatencySummary(attempts)
        XCTAssertEqual(result.samples, 20); XCTAssertEqual(result.p50Milliseconds, 10)
        XCTAssertEqual(result.p95Milliseconds, 19)
        let invalid = RoutingAttempt(sessionID: "s", requestedSource: nil, currentSource: nil,
            notificationClick: true, outcome: .dispatched, elapsedMilliseconds: .nan)
        XCTAssertNil(invalid.elapsedMilliseconds)
        XCTAssertNoThrow(try JSONEncoder().encode(invalid))
    }
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

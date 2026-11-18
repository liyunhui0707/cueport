import XCTest
import Darwin
@testable import AttentionCore

private final class ConnectionProbe: @unchecked Sendable {
    let lock = NSLock()
    var validations = 0
    var handled = 0
    var stopped = false
    var failure: String?
    var statuses: [String] = []
    func read<T>(_ body: (ConnectionProbe) -> T) -> T { lock.withLock { body(self) } }
    func update(_ body: (ConnectionProbe) -> Void) { lock.withLock { body(self) } }
}

final class BridgeConnectionServerTests: XCTestCase {
    func testActualUnixReconnectRevalidatesAndDoesNotReplayPreviousBytes() throws {
        try exercise(rejectSecondOrigin: false)
    }
    func testChangedOriginOnReplacementSocketFailsBeforeForwarding() throws {
        try exercise(rejectSecondOrigin: true)
    }

    private func exercise(rejectSecondOrigin: Bool) throws {
        let directory = URL(fileURLWithPath: "/private/tmp/aar-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("socket").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0); defer { close(listener) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard listen(listener, 2) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let process = try XCTUnwrap(ProcessOriginProbe.snapshot(getpid()))
        let synthetic = ProcessOriginHint(pid: process.pid, uid: process.uid, startMicroseconds: process.startMicroseconds,
            processGroup: UInt32(process.pid), terminalGroup: UInt32(process.pid), terminalDevice: 20,
            hasControllingTerminal: true, isCodex: true)
        let origin = VerifiedTerminalOrigin(terminal: .init(sessionID: "12345678-1234-1234-1234-123456789ABC"), process: synthetic)
        let probe = ConnectionProbe()
        let finished = expectation(description: "bounded connection server stopped")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                try BridgeConnectionServer.run(listener: listener, expected: synthetic,
                    shouldStop: { probe.read { $0.stopped } },
                    revalidate: {
                        probe.update { $0.validations += 1 }
                        if rejectSecondOrigin && probe.read({ $0.validations }) == 2 {
                            var changed = synthetic; changed.startMicroseconds += 1
                            return .init(terminal: origin.terminal, process: changed)
                        }
                        return origin
                    }, handle: { fd, _, index in
                        var wait = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                        guard poll(&wait, 1, 2000) > 0 else { throw RouterError.commandFailed }
                        var buffer = [UInt8](repeating: 0, count: 128)
                        let count = Darwin.read(fd, &buffer, buffer.count)
                        let expected = index == 1 ? "first-unique-request" : "replacement-unique-request"
                        XCTAssertEqual(Data(buffer.prefix(max(0, count))), Data(expected.utf8))
                        let response = Array("ack".utf8)
                        XCTAssertEqual(Darwin.write(fd, response, response.count), response.count)
                        probe.update { $0.handled += 1; $0.stopped = index == 2 }
                        return .init(duration: 0, endReason: "upstream-closed", startupHandoff: false)
                    }, progress: { progress in probe.update { $0.statuses.append(progress.status) } })
            } catch { probe.update { $0.failure = "verification-failed" } }
        }
        for index in 1...2 {
            let client = socket(AF_UNIX, SOCK_STREAM, 0)
            XCTAssertGreaterThanOrEqual(client, 0)
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            XCTAssertEqual(connected, 0)
            if index == 1 || !rejectSecondOrigin {
                let request = Array((index == 1 ? "first-unique-request" : "replacement-unique-request").utf8)
                XCTAssertEqual(Darwin.write(client, request, request.count), request.count)
                var wait = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
                XCTAssertGreaterThan(poll(&wait, 1, 3000), 0)
                var buffer = [UInt8](repeating: 0, count: 16)
                let count = Darwin.read(client, &buffer, buffer.count)
                XCTAssertEqual(Data(buffer.prefix(max(0, count))), Data("ack".utf8))
            } else {
                // Keep the socket alive until the second peer has actually
                // reached the verifier; an already-closed peer has no claim.
                var pending = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
                XCTAssertGreaterThan(poll(&pending, 1, 3000), 0)
                var byte: UInt8 = 0
                XCTAssertEqual(Darwin.read(client, &byte, 1), 0)
            }
            close(client)
        }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(probe.read { $0.validations }, 2)
        XCTAssertEqual(probe.read { $0.handled }, rejectSecondOrigin ? 1 : 2)
        XCTAssertTrue(probe.read { $0.statuses.contains("recovering") })
        XCTAssertEqual(probe.read { $0.failure }, rejectSecondOrigin ? "verification-failed" : nil)
    }
}

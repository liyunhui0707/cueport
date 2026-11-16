import XCTest
import Darwin
@testable import AttentionCore

final class BridgeTransportTests: XCTestCase {
    let request = Data("GET / HTTP/1.1\r\nUpgrade: websocket\r\n\r\n".utf8)
    func frame(_ text: Data, opcode: UInt8 = 1, final: Bool = true, masked: Bool = true) -> Data {
        var bytes: [UInt8] = [(final ? 128 : 0) | opcode]
        if text.count < 126 { bytes.append((masked ? 128 : 0) | UInt8(text.count)) }
        else { bytes += [(masked ? 128 : 0) | 126, UInt8(text.count >> 8), UInt8(text.count & 255)] }
        let mask: [UInt8] = [1, 2, 3, 4]
        if masked { bytes += mask }
        bytes += text.enumerated().map { masked ? $0.element ^ mask[$0.offset % 4] : $0.element }
        return Data(bytes)
    }
    func testFragmentedUpgradeMaskedContinuationAndInterleavedPing() {
        var tap = WebSocketTap(masked: true)
        let stream = request + frame(Data("{\"id\":".utf8), final: false)
            + frame(Data("ping".utf8), opcode: 9) + frame(Data("1}".utf8), opcode: 0)
        var messages: [Data] = []
        for byte in stream { messages += tap.feed(Data([byte])) }
        XCTAssertEqual(messages, [Data("{\"id\":1}".utf8)]); XCTAssertFalse(tap.failed)
    }
    func testOversizedMessageIsSkippedAndNextMetadataFrameRemainsObservable() {
        var tap = WebSocketTap(masked: true, limit: 256)
        _ = tap.feed(request)
        XCTAssertTrue(tap.feed(frame(Data(repeating: 65, count: 300))).isEmpty)
        XCTAssertFalse(tap.failed); XCTAssertEqual(tap.gapCount, 1)
        XCTAssertEqual(tap.feed(frame(Data("{}".utf8))), [Data("{}".utf8)])
        var compressed = WebSocketTap(masked: false)
        _ = compressed.feed(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n".utf8))
        XCTAssertTrue(compressed.feed(Data([0xc1, 0])).isEmpty); XCTAssertTrue(compressed.failed)
    }
    func testByteRelayPreservesLargeBidirectionalTrafficUnderBackpressure() throws {
        var client: [Int32] = [0, 0], upstream: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &client), 0)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &upstream), 0)
        let c0 = client[0], c1 = client[1], u0 = upstream[0], u1 = upstream[1]
        defer { [c0, c1, u0, u1].forEach { close($0) } }
        let finish = expectation(description: "relay stopped on disconnect")
        let end = Date().addingTimeInterval(5)
        DispatchQueue.global().async {
            do { try BridgeRelay.run(clientRead: c1, clientWrite: c1, upstreamRead: u0, upstreamWrite: u0,
                shouldStop: { Date() > end }, observe: { _, _ in }) }
            catch { XCTFail("byte relay failed") }
            finish.fulfill()
        }
        // Data is deliberately larger than the relay buffer and contains no JSON.
        let payload = Data((0..<180_000).map { UInt8($0 % 251) })
        func transfer(_ source: Int32, _ target: Int32) throws {
            let writerDone = expectation(description: "writer drained")
            DispatchQueue.global().async {
                var sent = 0
                payload.withUnsafeBytes { bytes in
                    while sent < bytes.count {
                        let n = Darwin.write(source, bytes.baseAddress!.advanced(by: sent), min(8192, bytes.count - sent))
                        if n <= 0 { break }; sent += n
                    }
                }
                XCTAssertEqual(sent, payload.count); writerDone.fulfill()
            }
            var received = Data(); var buffer = [UInt8](repeating: 0, count: 4000)
            while received.count < payload.count {
                var item = pollfd(fd: target, events: Int16(POLLIN), revents: 0)
                guard poll(&item, 1, 2000) > 0 else { XCTFail("relay stalled"); break }
                let n = Darwin.read(target, &buffer, buffer.count)
                guard n > 0 else { break }; received.append(contentsOf: buffer.prefix(n))
            }
            XCTAssertEqual(received, payload); wait(for: [writerDone], timeout: 3)
        }
        try transfer(c0, u1); try transfer(u1, c0)
        shutdown(c0, SHUT_WR)
        wait(for: [finish], timeout: 3)
    }
    func testClientHalfCloseStillReceivesUpstreamResponse() throws {
        var client: [Int32] = [0, 0], upstream: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &client), 0)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &upstream), 0)
        let c0 = client[0], c1 = client[1], u0 = upstream[0], u1 = upstream[1]
        defer { [c0, c1, u0, u1].forEach { close($0) } }
        let finish = expectation(description: "both ends drained")
        DispatchQueue.global().async {
            try? BridgeRelay.run(clientRead: c1, clientWrite: c1, upstreamRead: u0, upstreamWrite: u0,
                shouldStop: { false }, observe: { _, _ in })
            finish.fulfill()
        }
        let request = Array("request".utf8), response = Array("response".utf8)
        XCTAssertEqual(Darwin.write(c0, request, request.count), request.count)
        shutdown(c0, SHUT_WR)
        var buffer = [UInt8](repeating: 0, count: 32)
        var waitFD = pollfd(fd: u1, events: Int16(POLLIN), revents: 0)
        XCTAssertGreaterThan(poll(&waitFD, 1, 1000), 0)
        XCTAssertEqual(Darwin.read(u1, &buffer, buffer.count), request.count)
        XCTAssertEqual(Darwin.write(u1, response, response.count), response.count)
        shutdown(u1, SHUT_WR)
        waitFD = pollfd(fd: c0, events: Int16(POLLIN), revents: 0)
        XCTAssertGreaterThan(poll(&waitFD, 1, 1000), 0)
        let count = Darwin.read(c0, &buffer, buffer.count)
        XCTAssertEqual(Array(buffer.prefix(max(0, count))), response)
        wait(for: [finish], timeout: 2)
    }
    func testLargeFramePrefixIsBoundedUnmaskedAndOrderedBetweenMessages() {
        var tap = WebSocketTap(masked: true, limit: 256)
        let payload = Data(("{\"id\":1,\"result\":\"" + String(repeating: "x", count: 10_000) + "\"}").utf8)
        let stream = request + frame(Data("before".utf8)) + frame(payload) + frame(Data("after".utf8))
        var observed: [WebSocketObservation] = []
        for offset in stride(from: 0, to: stream.count, by: 37) {
            observed += tap.feedEvents(Data(stream.dropFirst(offset).prefix(37)))
        }
        XCTAssertEqual(observed, [.message(Data("before".utf8)), .oversizedPrefix(Data(payload.prefix(4096))), .message(Data("after".utf8))])
        XCTAssertFalse(tap.failed)
    }
    func testResponsePrefixNeverFindsIDsInsideBodiesOrServerRequests() {
        let good = ["{\"id\":12,\"result\":", "{ \"jsonrpc\":\"2.0\", \"id\":12,\"error\":"]
        for value in good { XCTAssertEqual(JSONRPCPrefix.responseID(Data(value.utf8)), "n:12") }
        let bad = ["{\"result\":{\"id\":12}", "{\"id\":12,\"method\":\"requestApproval\",\"params\":", "{\"id\":true,\"result\":", "{\"id\":12,\"id\":13,\"result\":", "{\"id\":\"fake\\\"result\":\",\"params\":"]
        for value in bad { XCTAssertNil(JSONRPCPrefix.responseID(Data(value.utf8))) }
    }
}

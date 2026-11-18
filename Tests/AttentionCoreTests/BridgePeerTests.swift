import XCTest
import Darwin
@testable import AttentionCore

final class BridgePeerTests: XCTestCase {
    func testKernelPeerMustMatchExactOriginalProcessAndUser() throws {
        var sockets: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { sockets.forEach { close($0) } }
        XCTAssertTrue(BridgePeerVerifier.matches(sockets[0], pid: getpid(), uid: getuid()))
        XCTAssertFalse(BridgePeerVerifier.matches(sockets[0], pid: getpid() + 1, uid: getuid()))
        XCTAssertFalse(BridgePeerVerifier.matches(sockets[0], pid: getpid(), uid: getuid() + 1))
        XCTAssertFalse(BridgePeerVerifier.matches(-1, pid: getpid(), uid: getuid()))
    }
}

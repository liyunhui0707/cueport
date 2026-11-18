import XCTest
import Darwin
@testable import AttentionCore

final class BridgeDataLeaseTests: XCTestCase {
    func testMultipleWritersExcludeMigrationAndReleaseCleanly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(root: root)
        let first = try store.lockBridgeWriter(), second = try store.lockBridgeWriter()
        let fd = open(root.appendingPathComponent("writers.lock").path, O_RDWR | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), -1)
        try first.close(); XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), -1)
        try second.close(); XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try store.lockBridgeWriter())
    }

    func testRelocatedRootCannotBeReopenedAsAnEmptyOrStaleProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try LocalStore(root: root)
        try Data(#"{"schema":1,"destination":"/synthetic/new-root"}"#.utf8)
            .write(to: root.appendingPathComponent("bridge-relocated.json"))
        XCTAssertThrowsError(try LocalStore(root: root))
    }
}

import XCTest
import Darwin
@testable import AttentionCore

final class StorageConfigurationTests: XCTestCase {
    func testBridgeTemporaryDirectoryAcceptsOnlySystemAliasesAndExactLeaf() throws {
        var template = Array("/private/tmp/aar-bridge-XXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else { return XCTFail("temporary fixture unavailable") }
        let directory = URL(fileURLWithPath: String(cString: created), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(BridgeDirectoryPolicy.accepts(directory))
        XCTAssertTrue(BridgeDirectoryPolicy.accepts(directory.standardizedFileURL))
        XCTAssertFalse(BridgeDirectoryPolicy.accepts(directory.appendingPathComponent("nested")))
        XCTAssertFalse(BridgeDirectoryPolicy.accepts(URL(fileURLWithPath: "/private/tmp/aar-bridge-toolong")))
        XCTAssertFalse(BridgeDirectoryPolicy.accepts(URL(fileURLWithPath: "/Users/aar-bridge-ABC123")))
    }
    func testPOCDirectoryCannotAliasNormalDirectory() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let normal = parent.appendingPathComponent("NormalStore"), isolated = parent.appendingPathComponent("SeparateStore")
        _ = try LocalStore(root: normal); _ = try LocalStore(root: isolated)
        XCTAssertThrowsError(try LocalStore.requireSeparate(normal, from: normal))
        XCTAssertNoThrow(try LocalStore.requireSeparate(isolated, from: normal))
        let caseAlias = parent.appendingPathComponent("normalstore")
        if FileManager.default.fileExists(atPath: caseAlias.path) {
            XCTAssertThrowsError(try LocalStore.requireSeparate(caseAlias, from: normal))
        }
    }
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("aar-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func testMergeAndUninstallPreserveOtherHandlersAndFields() throws {
        let original = Data(#"{"description":"keep me","other":{"custom":true},"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"other-tool","timeout":9}]}],"Custom":[{"hooks":[{"type":"command","command":"custom"}]}]}}"#.utf8)
        let command = HookConfiguration.command(executable: "/tmp/it's a helper/aar", dataRoot: nil)
        let once = try HookConfiguration.merged(existing: original, command: command)
        let twice = try HookConfiguration.merged(existing: once, command: command)
        XCTAssertEqual(once, twice)
        let restored = try HookConfiguration.merged(existing: twice, command: command, uninstall: true)
        let a = try JSONSerialization.jsonObject(with: original) as! NSDictionary
        let b = try JSONSerialization.jsonObject(with: restored) as! NSDictionary
        XCTAssertEqual(a, b)
        XCTAssertTrue(command.contains("'\\''"))
    }
    func testMalformedConfigurationFailsClosed() {
        for text in ["[]", #"{"hooks":[]}"#, #"{"hooks":{"Stop":"wrong"}}"#, #"{"hooks":{"Stop":[{}]}}"#] {
            XCTAssertThrowsError(try HookConfiguration.merged(existing: Data(text.utf8), command: "aar hook"))
        }
    }
    func testPrivateInboxPersistsAndReplaysIdempotently() throws {
        let store = try LocalStore(root: temporary())
        let event = AgentEvent(id: "../../untrusted/name", kind: .questionQueued, sessionID: "agent", questionIDs: ["q"])
        try store.enqueue(event); try store.enqueue(event)
        XCTAssertEqual(try store.pending().count, 1)
        let (file, value) = try XCTUnwrap(store.pending().first)
        var state = try store.load(); try state.apply(value); try store.save(state)
        let loaded = try store.load(); XCTAssertEqual(loaded, state)
        XCTAssertEqual(file.deletingLastPathComponent().resolvingSymlinksInPath().path, store.inbox.resolvingSymlinksInPath().path)
        try store.acknowledge(file); XCTAssertTrue(try store.pending().isEmpty)
        var replayed = loaded; XCTAssertFalse(try replayed.apply(value))
    }
    func testSymlinkAndPublicDirectoryRejected() throws {
        let parent = try temporary()
        let destination = parent.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let link = parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        XCTAssertThrowsError(try LocalStore(root: link))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        XCTAssertThrowsError(try LocalStore(root: destination))
    }
    func testInvalidInboxCannotBlockValidEvents() throws {
        let store = try LocalStore(root: temporary())
        try store.enqueue(AgentEvent(kind: .turnStopped, sessionID: "valid"))
        let bad = store.inbox.appendingPathComponent("bad.json")
        FileManager.default.createFile(atPath: bad.path, contents: Data("invalid".utf8), attributes: [.posixPermissions: 0o600])
        let scan = try store.scan()
        XCTAssertEqual(scan.rejected, 1); XCTAssertEqual(scan.events.count, 1)
        XCTAssertEqual(scan.events.first?.1.sessionID, "valid")
    }
    func testOnlyOneConsumerCanWriteSnapshot() throws {
        let store = try LocalStore(root: temporary())
        let lock = try store.lockConsumer()
        XCTAssertThrowsError(try store.lockConsumer())
        try lock.close()
        let next = try store.lockConsumer(); try next.close()
    }
    func testRecreatedInboxRetainsSnapshotAndAcceptsNewEvents() throws {
        let store = try LocalStore(root: temporary())
        var state = RouterState()
        try state.apply(.init(kind: .questionQueued, sessionID: "existing", questionIDs: ["q"]))
        try store.save(state)
        // Recoverable stand-in for removal: preserve the original empty inbox.
        try FileManager.default.moveItem(at: store.inbox, to: store.root.appendingPathComponent("old-inbox"))
        XCTAssertTrue(try store.scan().events.isEmpty)
        try store.enqueue(.init(kind: .turnStarted, sessionID: "new"))
        XCTAssertEqual(try store.scan().events.first?.1.sessionID, "new")
        XCTAssertEqual(try store.load().sessions["existing"]?.outstanding.count, 1)
        let mode = try FileManager.default.attributesOfItem(atPath: store.inbox.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
    }
    func testReplacedInboxSymlinkIsRefusedWithoutWritingItsDestination() throws {
        let store = try LocalStore(root: temporary())
        let other = try temporary()
        try FileManager.default.moveItem(at: store.inbox, to: store.root.appendingPathComponent("old-inbox"))
        try FileManager.default.createSymbolicLink(at: store.inbox, withDestinationURL: other)
        XCTAssertThrowsError(try store.scan())
        XCTAssertThrowsError(try store.enqueue(.init(kind: .turnStopped, sessionID: "s")))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
    }
    func testReplacedRootCannotReuseOriginalConsumerLock() throws {
        let root = try temporary(), store = try LocalStore(root: root)
        let lock = try store.lockConsumer()
        defer { try? lock.close() }
        let preserved = root.appendingPathExtension("preserved")
        defer { try? FileManager.default.removeItem(at: preserved) }
        try FileManager.default.moveItem(at: root, to: preserved)
        let replacement = try LocalStore(root: root)
        let newLock = try replacement.lockConsumer()
        defer { try? newLock.close() }
        XCTAssertThrowsError(try store.scan())
        XCTAssertThrowsError(try store.save(RouterState()))
        XCTAssertThrowsError(try store.enqueue(.init(kind: .turnStopped, sessionID: "old")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json").path))
    }
    func testRuntimeDiagnosticsArePrivateAndCannotChangeTheAuthoritativeSnapshot() throws {
        let store = try LocalStore(root: temporary())
        XCTAssertNil(try store.snapshotBytes())
        var state = RouterState(); try state.apply(.init(kind: .questionQueued, sessionID: "s", questionIDs: ["q"]))
        try store.save(state)
        let snapshot = try Data(contentsOf: store.root.appendingPathComponent("state.json"))
        XCTAssertEqual(try store.snapshotBytes(), Int64(snapshot.count))
        try store.saveRuntimeDiagnostics(Data(#"{"monitoring":"ready"}"#.utf8))
        XCTAssertEqual(try store.load(), state)
        XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent("state.json")), snapshot)
        let file = store.root.appendingPathComponent("runtime-health.json")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try store.saveRuntimeDiagnostics(Data(repeating: 0, count: 16_385)))
        XCTAssertEqual(LocalStore.maximumSnapshotBytes, 64 * 1_048_576)
    }
    func testRuntimeDiagnosticsRefuseDanglingSymlinksAndReplacedRoots() throws {
        let root = try temporary(), store = try LocalStore(root: root)
        let file = root.appendingPathComponent("runtime-health.json"), target = root.appendingPathComponent("missing-target")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try store.saveRuntimeDiagnostics(Data("{}".utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let preserved = root.appendingPathExtension("preserved")
        defer { try? FileManager.default.removeItem(at: preserved) }
        try FileManager.default.moveItem(at: root, to: preserved)
        _ = try LocalStore(root: root)
        XCTAssertThrowsError(try store.snapshotBytes())
        XCTAssertThrowsError(try store.saveRuntimeDiagnostics(Data("{}".utf8)))
    }
}

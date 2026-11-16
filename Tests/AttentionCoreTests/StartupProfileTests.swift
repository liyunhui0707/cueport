import XCTest
import Foundation
@testable import AttentionCore

final class StartupProfileTests: XCTestCase {
    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let normal = base.appendingPathComponent("normal"), bridge = base.appendingPathComponent("bridge")
        try LocalStore.ensurePrivateDirectory(normal)
        try LocalStore.ensurePrivateDirectory(bridge)
        try body(normal, bridge)
    }

    func testPlainReopenRestoresOnlyExplicitlySavedBridge() throws {
        try fixture { normal, bridge in
            let plain = StartupSelection.resolve(arguments: ["app"], saved: nil, normalRoot: normal)
            XCTAssertEqual(plain.mode, .ordinary)
            let profile = try BridgeStartupProfile(root: bridge, normalRoot: normal)
            let saved = try profile.encoded()
            let restored = StartupSelection.resolve(arguments: ["app", "--settings"], saved: saved, normalRoot: normal)
            XCTAssertEqual(restored.mode, .bridge)
            XCTAssertEqual(restored.root, bridge.standardizedFileURL)
            XCTAssertEqual(try BridgeStartupProfile.decode(saved), profile)
        }
    }

    func testExplicitDirectoryNeverAdoptsOrOverwritesSavedSelection() throws {
        try fixture { normal, bridge in
            for saved in [Data("invalid".utf8), try BridgeStartupProfile(root: bridge, normalRoot: normal).encoded()] {
                let explicit = StartupSelection.resolve(arguments: ["app", "--data-dir", normal.path], saved: saved, normalRoot: normal)
                XCTAssertEqual(explicit.mode, .ordinary)
                XCTAssertEqual(explicit.root, normal.standardizedFileURL)
                let connected = StartupSelection.resolve(arguments: ["app", "--bridge-poc", "--data-dir", bridge.path], saved: saved, normalRoot: normal)
                XCTAssertEqual(connected.mode, .bridge)
            }
        }
    }

    func testPreviewAndOriginExperimentsIgnoreRememberedBridge() throws {
        try fixture { normal, _ in
            for args in [["--demo"], ["--render-previews", "/synthetic/previews"], ["--poc-origin-case", "/synthetic/fixture"]] {
                let result = StartupSelection.resolve(arguments: ["app"] + args, saved: Data(), normalRoot: normal)
                XCTAssertEqual(result.mode, .ordinary)
            }
        }
    }

    func testInvalidExplicitBridgeDoesNotFallBackToSavedOrNormal() throws {
        try fixture { normal, bridge in
            let saved = try BridgeStartupProfile(root: bridge, normalRoot: normal).encoded()
            for args in [["--bridge-poc"], ["--bridge-poc", "--data-dir", normal.path],
                         ["--data-dir"], ["--data-dir", "relative"],
                         ["--data-dir", normal.path, "--data-dir", bridge.path]] {
                XCTAssertEqual(StartupSelection.resolve(arguments: ["app"] + args, saved: saved, normalRoot: normal).mode, .blocked)
            }
        }
    }

    func testMissingOrReplacedSavedRootIsBlockedWithoutRecreation() throws {
        try fixture { normal, bridge in
            let saved = try BridgeStartupProfile(root: bridge, normalRoot: normal).encoded()
            let moved = bridge.appendingPathExtension("retained")
            try FileManager.default.moveItem(at: bridge, to: moved)
            XCTAssertEqual(StartupSelection.resolve(arguments: ["app"], saved: saved, normalRoot: normal).mode, .blocked)
            XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.path))
            try LocalStore.ensurePrivateDirectory(bridge)
            XCTAssertEqual(StartupSelection.resolve(arguments: ["app"], saved: saved, normalRoot: normal).mode, .blocked)
        }
    }

    func testPrivateDirectoryAndNoSymlinkRulesApplyToSavingAndRestore() throws {
        try fixture { normal, bridge in
            XCTAssertThrowsError(try BridgeStartupProfile(root: normal, normalRoot: normal))
            let alias = bridge.appendingPathExtension("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: bridge)
            XCTAssertThrowsError(try BridgeStartupProfile(root: alias, normalRoot: normal))
            let saved = try BridgeStartupProfile(root: bridge, normalRoot: normal).encoded()
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridge.path)
            XCTAssertThrowsError(try BridgeStartupProfile(root: bridge, normalRoot: normal))
            XCTAssertEqual(StartupSelection.resolve(arguments: ["app"], saved: saved, normalRoot: normal).mode, .blocked)
        }
    }

    func testCorruptUnsupportedAndExecutableLookingPreferencesFailClosed() throws {
        try fixture { normal, bridge in
            for raw in ["{}", "{\"schema\":99}", "{\"schema\":1,\"rootPath\":\"/bin/sh -c anything\"}", String(repeating: "x", count: 9000)] {
                XCTAssertEqual(StartupSelection.resolve(arguments: ["app"], saved: Data(raw.utf8), normalRoot: normal).mode, .blocked)
            }
            let valid = try BridgeStartupProfile(root: bridge, normalRoot: normal).encoded()
            var future = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
            future["schema"] = 99
            XCTAssertEqual(StartupSelection.resolve(arguments: ["app"], saved: try JSONSerialization.data(withJSONObject: future), normalRoot: normal).mode, .blocked)
            future["schema"] = 1; future["rootPath"] = "relative/folder"
            XCTAssertEqual(StartupSelection.resolve(arguments: ["app"], saved: try JSONSerialization.data(withJSONObject: future), normalRoot: normal).mode, .blocked)
        }
    }

    func testForgettingOnlyChangesNextLaunchAndPreservesData() throws {
        try fixture { normal, bridge in
            let marker = bridge.appendingPathComponent("retained-marker")
            try Data("retained".utf8).write(to: marker)
            let saved = try BridgeStartupProfile(root: bridge, normalRoot: normal).encoded()
            XCTAssertEqual(StartupSelection.resolve(arguments: ["app"], saved: saved, normalRoot: normal).mode, .bridge)
            XCTAssertEqual(StartupSelection.resolve(arguments: ["app"], saved: nil, normalRoot: normal).mode, .ordinary)
            XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "retained")
        }
    }
}

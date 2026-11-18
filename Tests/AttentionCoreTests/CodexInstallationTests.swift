import XCTest
@testable import AttentionCore

final class CodexInstallationTests: XCTestCase {
    func testNpmLayoutPreservesOfficialUpdaterContextWithoutExecutingWrapper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("lib/node_modules/@openai/codex")
        let native = package.appendingPathComponent("node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex")
        try FileManager.default.createDirectory(at: native.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data("not executed".utf8).write(to: package.appendingPathComponent("bin/codex.js"))
        try Data(#"{"name":"@openai/codex","version":"0.169.0"}"#.utf8).write(to: package.appendingPathComponent("package.json"))
        let context = CodexInstallation(nativeExecutable: native.path)
        XCTAssertEqual(context.manager, .npm)
        let environment = context.environment(inheriting: ["KEEP": "literal", "CODEX_MANAGED_BY_BUN": "1"])
        XCTAssertEqual(environment["KEEP"], "literal")
        XCTAssertEqual(environment["CODEX_MANAGED_BY_NPM"], "1")
        XCTAssertNil(environment["CODEX_MANAGED_BY_BUN"])
        XCTAssertEqual(environment["CODEX_MANAGED_PACKAGE_ROOT"], package.path)
        XCTAssertTrue(context.nativeUpdateArguments.isEmpty)
    }

    func testManualBinaryCannotInheritAnUnrelatedPackageManagerOrRoot() {
        let context = CodexInstallation(nativeExecutable: "/opt/homebrew/unrelated/manual/codex")
        XCTAssertEqual(context.manager, .manual)
        let environment = context.environment(inheriting: ["ITERM_SESSION_ID": "literal",
            "CODEX_MANAGED_BY_NPM": "1", "CODEX_MANAGED_PACKAGE_ROOT": "/unrelated"])
        XCTAssertNil(environment["CODEX_MANAGED_BY_NPM"])
        XCTAssertNil(environment["CODEX_MANAGED_PACKAGE_ROOT"])
        XCTAssertEqual(environment["ITERM_SESSION_ID"], "literal")
        XCTAssertEqual(context.nativeUpdateArguments, ["-c", "check_for_update_on_startup=false"])
    }

    func testOnlySpecificBrewCaskLayoutUsesBrewContext() {
        XCTAssertEqual(CodexInstallation(nativeExecutable: "/opt/homebrew/Caskroom/codex/0.169.0/codex-aarch64-apple-darwin").manager, .brew)
        XCTAssertEqual(CodexInstallation(nativeExecutable: "/usr/local/Caskroom/codex/0.169.0/codex").manager, .brew)
        XCTAssertEqual(CodexInstallation(nativeExecutable: "/opt/homebrew/unrelated/bin/codex").manager, .manual)
        XCTAssertEqual(CodexInstallation(nativeExecutable: "/opt/homebrew/Caskroom/other/0/codex").manager, .manual)
    }
    func testProjectLocalNpmPackageDoesNotOfferAnUnrelatedGlobalUpgrade() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("project/node_modules/@openai/codex")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data(#"{"name":"@openai/codex"}"#.utf8).write(to: package.appendingPathComponent("package.json"))
        try Data("not executed".utf8).write(to: package.appendingPathComponent("bin/codex.js"))
        let context = CodexInstallation(nativeExecutable: package.appendingPathComponent("vendor/bin/codex").path)
        XCTAssertEqual(context.manager, .manual)
        XCTAssertFalse(context.nativeUpdateArguments.isEmpty)
    }
}

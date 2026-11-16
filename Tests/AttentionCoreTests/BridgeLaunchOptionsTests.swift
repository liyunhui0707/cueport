import XCTest
@testable import AttentionCore

final class BridgeLaunchOptionsTests: XCTestCase {
    let id = "12345678-1234-1234-1234-123456789abc"

    func testExplicitNativeDependencyDoesNotAllowNativeArgumentPassthrough() throws {
        let value = try BridgeInvocation(arguments: ["--data-dir", "/private/test", "--native-codex", "/private/dependency/codex", "--", "resume"])
        XCTAssertEqual(value.nativeExecutable, "/private/dependency/codex")
        XCTAssertEqual(value.launch.mode, .resume(threadID: nil))
        XCTAssertNil(try BridgeInvocation(arguments: ["--data-dir", "/private/test", "--"]).nativeExecutable)
        for args in [["--data-dir", "relative", "--"],
                     ["--data-dir", "/a", "--native-codex", "relative/codex", "--"],
                     ["--data-dir", "/a", "--native-codex", "/path/script", "--"],
                     ["--data-dir", "/a", "--native-codex", "/path/codex\n", "--"],
                     ["--data-dir", "/a", "--native-codex", "/path/codex", "--", "--remote", "unix:///foreign"],
                     ["--data-dir", "/a", "--native-codex", "/path/codex", "--", "--approve-for-me"]] {
            XCTAssertThrowsError(try BridgeInvocation(arguments: args))
        }
    }

    func testFreshLaunchRetainsExistingInlineFlagSupport() throws {
        XCTAssertEqual(try BridgeLaunchOptions(codexArguments: []).mode, .fresh)
        let inline = try BridgeLaunchOptions(codexArguments: ["--no-alt-screen", "--no-alt-screen"])
        XCTAssertEqual(inline.mode, .fresh)
        XCTAssertEqual(inline.codexArguments, ["--no-alt-screen"])
    }

    func testResumePickerAndExplicitUUIDUseNativeResumeSubcommand() throws {
        let picker = try BridgeLaunchOptions(codexArguments: ["resume"])
        XCTAssertEqual(picker.mode, .resume(threadID: nil))
        XCTAssertEqual(picker.nativeArguments(endpoint: "unix:///private/tmp/synthetic/socket", directory: "/Synthetic project"),
            ["--remote", "unix:///private/tmp/synthetic/socket", "--cd", "/Synthetic project", "resume"])
        let exact = try BridgeLaunchOptions(codexArguments: ["resume", id.uppercased(), "--no-alt-screen"])
        XCTAssertEqual(exact.mode, .resume(threadID: UUID(uuidString: id)))
        XCTAssertEqual(exact.codexArguments, ["--no-alt-screen", "resume", id])
    }

    func testRejectsPromptLatestGuessEndpointAndPermissionOverrides() {
        let invalid = [["resume", "--last"], ["resume", "--all"], ["resume", "session name"],
            ["resume", id, "PRIVATE PROMPT"], ["resume", "--remote", "unix:///foreign"],
            ["resume", "--dangerously-bypass-hook-trust"], ["resume", "--approve-for-me"],
            ["resume", "--config", "value=true"], ["resume", "--cd", "/foreign"],
            ["resume", "{" + id + "}"], ["resume", id + "\n"], ["resume", id, id],
            ["resume", "--", id], ["PRIVATE PROMPT"], ["fork"]]
        for arguments in invalid { XCTAssertThrowsError(try BridgeLaunchOptions(codexArguments: arguments)) }
    }

    func testCopiedCommandsQuoteExecutableAndRootAndDoNotChooseAThread() throws {
        let picker = try BridgeLaunchOptions(codexArguments: ["resume"])
        XCTAssertEqual(picker.shellCommand(executable: "/Synthetic App's/aar", dataDirectory: "/Data/$(literal)`literal`'folder"),
            "'/Synthetic App'\\''s/aar' codex --data-dir '/Data/$(literal)`literal`'\\''folder' -- resume")
        let fresh = try BridgeLaunchOptions(codexArguments: [])
        XCTAssertEqual(fresh.shellCommand(executable: "/app/aar", dataDirectory: "/data"),
            "'/app/aar' codex --data-dir '/data' --")
    }
}

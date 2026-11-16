import Foundation

/// Helper options stay outside the native argument separator. A manually
/// selected native dependency does not broaden accepted Codex arguments.
public struct BridgeInvocation: Sendable {
    public let dataRoot: URL
    public let nativeExecutable: String?
    public let launch: BridgeLaunchOptions
    public init(arguments: [String]) throws {
        guard arguments.count >= 3, arguments[0] == "--data-dir", arguments[1].hasPrefix("/"),
              !arguments[1].unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw RouterError.invalidEvent }
        dataRoot = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
        let separator: Int
        if arguments[2] == "--" { nativeExecutable = nil; separator = 2 }
        else {
            guard arguments.count >= 5, arguments[2] == "--native-codex", arguments[3].hasPrefix("/"),
                  !arguments[3].unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  URL(fileURLWithPath: arguments[3]).lastPathComponent == "codex", arguments[4] == "--" else { throw RouterError.invalidEvent }
            nativeExecutable = URL(fileURLWithPath: arguments[3]).standardizedFileURL.path; separator = 4
        }
        launch = try BridgeLaunchOptions(codexArguments: Array(arguments.dropFirst(separator + 1)))
    }
}

/// Explicit launch choices only. No prompt, endpoint, configuration or permission
/// passthrough, and no implicit choice of the owner's latest conversation.
public struct BridgeLaunchOptions: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case fresh
        case resume(threadID: UUID?)
    }
    public let mode: Mode
    public let noAltScreen: Bool
    public var permitsStartupPickerHandoff: Bool { mode == .resume(threadID: nil) }

    public init(codexArguments: [String]) throws {
        let positional = codexArguments.filter { $0 != "--no-alt-screen" }
        noAltScreen = codexArguments.contains("--no-alt-screen")
        switch positional.count {
        case 0: mode = .fresh
        case 1 where positional[0] == "resume": mode = .resume(threadID: nil)
        case 2 where positional[0] == "resume":
            guard positional[1].utf8.count == 36, let id = UUID(uuidString: positional[1]) else {
                throw RouterError.invalidEvent
            }
            mode = .resume(threadID: id)
        default: throw RouterError.invalidEvent
        }
    }

    public var codexArguments: [String] {
        let flags = noAltScreen ? ["--no-alt-screen"] : []
        switch mode {
        case .fresh: return flags
        case .resume(let id): return flags + ["resume"] + (id.map { [$0.uuidString.lowercased()] } ?? [])
        }
    }

    public func nativeArguments(endpoint: String, directory: String) -> [String] {
        ["--remote", endpoint, "--cd", directory] + codexArguments
    }

    public func shellCommand(executable: String, dataDirectory: String) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return ([quote(executable), "codex", "--data-dir", quote(dataDirectory), "--"] + codexArguments).joined(separator: " ")
    }
}

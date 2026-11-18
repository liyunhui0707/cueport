import Foundation
import Darwin

/// A user-selected dependency, never an event-supplied command or PATH lookup.
public enum NativeCodex {
    public static let defaultPath = "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
    public enum Failure: LocalizedError, Equatable, Sendable {
        case invalidPath, unavailable, nativeRequired, unsupportedVersion, probeFailed
        public var errorDescription: String? {
            switch self {
            case .invalidPath: "Choose an absolute path to the native executable named codex."
            case .unavailable: "The selected Codex file is missing, inaccessible or not executable. Choose it again or use the default."
            case .nativeRequired: "Choose the native arm64 Codex binary named codex. Shell/npm wrappers and non-regular files are not accepted."
            case .unsupportedVersion: "This connection supports native Codex \(BridgeCompatibility.nativeClientVersion) only. Other versions are not enabled."
            case .probeFailed: "The native version check failed or exceeded 30 seconds. Review the selected installation and retry."
            }
        }
    }
    public static func validatedPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              URL(fileURLWithPath: path).lastPathComponent == "codex" else { throw Failure.invalidPath }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
    public static func inspect(_ path: String) throws {
        let path = try validatedPath(path)
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Failure.unavailable }
        guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.nativeRequired }
        guard FileManager.default.isExecutableFile(atPath: path) else { throw Failure.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let header = try handle.read(upToCount: 8),
              Array(header) == [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01] else { throw Failure.nativeRequired }
    }
    @discardableResult public static func verifyVersion(_ path: String) throws -> String {
        try inspect(path)
        let output: Data
        do { output = try BoundedProcess.output(URL(fileURLWithPath: path), arguments: ["--version"], timeout: 30, maximumBytes: 4096) }
        catch { throw Failure.probeFailed }
        guard BridgeCompatibility.acceptsNativeVersionOutput(output) else { throw Failure.unsupportedVersion }
        return BridgeCompatibility.nativeClientVersion
    }
}

/// App preference only. Existing running workers and Codex configuration do not change.
public struct NativeCodexPreference: Codable, Equatable, Sendable {
    public static let defaultsKey = "nativeCodexExecutable.v1"
    public let schema: Int
    public let path: String
    public init(path: String) throws { self.schema = 1; self.path = try NativeCodex.validatedPath(path) }
    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 8192 else { throw RouterError.oversizedPayload }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schema == 1 else { throw RouterError.invalidEvent }
        return try .init(path: value.path)
    }
}

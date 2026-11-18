import XCTest
import AttentionCore
import Darwin

final class NativeCodexTests: XCTestCase {
    func testPreferenceRoundTripAndRejectsUnsafeOrCorruptPaths() throws {
        let value = try NativeCodexPreference(path: "/原生 Native App's/$(literal)/codex")
        XCTAssertEqual(try NativeCodexPreference.decode(value.encoded()), value)
        for path in ["codex", "~/bin/codex", "/native/wrapper", "/native/codex\n"] {
            XCTAssertThrowsError(try NativeCodexPreference(path: path))
        }
        XCTAssertThrowsError(try NativeCodexPreference.decode(Data(#"{"schema":2,"path":"/native/codex"}"#.utf8)))
        XCTAssertThrowsError(try NativeCodexPreference.decode(Data(repeating: 32, count: 9000)))
    }
    func testInspectionRejectsWrappersAndFifoWithoutExecutingOrBlocking() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        XCTAssertThrowsError(try NativeCodex.inspect(script.path)) { XCTAssertEqual($0 as? NativeCodex.Failure, .nativeRequired) }
        let fifoDirectory = directory.appendingPathComponent("fifo")
        try FileManager.default.createDirectory(at: fifoDirectory, withIntermediateDirectories: true)
        let fifo = fifoDirectory.appendingPathComponent("codex")
        XCTAssertEqual(mkfifo(fifo.path, 0o700), 0)
        XCTAssertThrowsError(try NativeCodex.inspect(fifo.path)) { XCTAssertEqual($0 as? NativeCodex.Failure, .nativeRequired) }
    }
}

import XCTest
import AttentionCore
import Darwin

final class BoundedProcessTests: XCTestCase {
    func testArgumentsAreLiteralAndNonzeroExitIsRejected() throws {
        let data = try BoundedProcess.output(URL(fileURLWithPath: "/bin/echo"),
            arguments: ["one; two", "$(literal)"], timeout: 2)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "one; two $(literal)\n")
        XCTAssertThrowsError(try BoundedProcess.output(URL(fileURLWithPath: "/usr/bin/false"), timeout: 2)) {
            XCTAssertEqual($0 as? BoundedProcess.Failure, .exitStatus(1))
        }
    }

    func testOutputLimitStopsAnUnendingProducer() throws {
        XCTAssertThrowsError(try BoundedProcess.output(URL(fileURLWithPath: "/usr/bin/yes"),
            arguments: ["x"],
            timeout: 3, maximumBytes: 32768)) {
            XCTAssertEqual($0 as? BoundedProcess.Failure, .outputLimit)
        }
    }

    func testTimeoutReapsChildThatIgnoresTerminationAndClosesOutput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("owned-pid")
        // Keep the fixture in one native process: an interpreter's cold startup
        // must not consume the deadline before the signal handler/PID marker exist.
        let script = "trap '' TERM; printf '%s' \"$$\" > \"$1\"; exec 1>&-; while :; do :; done"
        let start = DispatchTime.now().uptimeNanoseconds
        XCTAssertThrowsError(try BoundedProcess.output(URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, "aar-timeout-fixture", marker.path], timeout: 1)) {
            XCTAssertEqual($0 as? BoundedProcess.Failure, .timeout)
        }
        XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9, 4)
        let pid = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}

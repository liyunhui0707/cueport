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
        XCTAssertThrowsError(try BoundedProcess.output(URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import os\nwhile True: os.write(1, b'x' * 16384)"],
            timeout: 3, maximumBytes: 32768)) {
            XCTAssertEqual($0 as? BoundedProcess.Failure, .outputLimit)
        }
    }

    func testTimeoutReapsChildThatIgnoresTerminationAndClosesOutput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("owned-pid")
        let script = "import os,signal,time,sys\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\nopen(sys.argv[1], 'w').write(str(os.getpid()))\nos.close(1)\nwhile True: time.sleep(.1)"
        let start = DispatchTime.now().uptimeNanoseconds
        XCTAssertThrowsError(try BoundedProcess.output(URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script, marker.path], timeout: 1)) {
            XCTAssertEqual($0 as? BoundedProcess.Failure, .timeout)
        }
        XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9, 4)
        let pid = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}

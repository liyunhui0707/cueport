import Foundation
import Dispatch
import Darwin

/// Fixed callers supply the executable/arguments. Output is transient only.
/// A timeout also covers a child closing stdout without actually exiting.
public enum BoundedProcess {
    public enum Failure: Error, Equatable, Sendable {
        case invalidLimits, timeout, outputLimit, exitStatus(Int32)
    }
    public static func output(_ executable: URL, arguments: [String] = [],
                              environment: [String: String]? = nil,
                              workingDirectory: URL? = nil,
                              timeout: TimeInterval = 5, maximumBytes: Int = 1_048_576) throws -> Data {
        guard timeout.isFinite, timeout > 0, timeout <= 120,
              maximumBytes > 0, maximumBytes <= 1_048_576 else { throw Failure.invalidLimits }
        let child = Process(), pipe = Pipe()
        child.executableURL = executable; child.arguments = arguments
        child.environment = environment
        child.currentDirectoryURL = workingDirectory
        child.standardInput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        child.standardOutput = pipe
        try child.run()
        defer {
            if child.isRunning {
                child.terminate()
                let end = DispatchTime.now().uptimeNanoseconds + 200_000_000
                while child.isRunning && DispatchTime.now().uptimeNanoseconds < end { usleep(5_000) }
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
            child.waitUntilExit()
            try? pipe.fileHandleForReading.close()
        }
        let fd = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw RouterError.commandFailed }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1e9)
        var result = Data(), bytes = [UInt8](repeating: 0, count: 16_384), eof = false
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if !eof {
                var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = poll(&item, 1, 20)
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count > 0 {
                    guard count <= maximumBytes - result.count else { throw Failure.outputLimit }
                    result.append(contentsOf: bytes.prefix(count))
                } else if count == 0 { eof = true }
                else if ![EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { throw RouterError.commandFailed }
            }
            if eof {
                if !child.isRunning {
                    child.waitUntilExit()
                    guard child.terminationStatus == 0 else { throw Failure.exitStatus(child.terminationStatus) }
                    return result
                }
                usleep(5_000)
            }
        }
        throw Failure.timeout
    }
}

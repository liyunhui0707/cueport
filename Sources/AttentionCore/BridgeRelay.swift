import Foundation
import Darwin

/// A bounded nonblocking byte pump. Observation has no authority to write bytes.
public enum BridgeRelay {
    public enum EndReason: Equatable, Sendable { case clientClosed, upstreamClosed, stopped }
    @discardableResult
    public static func run(clientRead: Int32, clientWrite: Int32, upstreamRead: Int32, upstreamWrite: Int32,
                           shouldStop: () -> Bool, observe: (ProtocolDirection, Data) -> Void) throws -> EndReason {
        let descriptors = Set([clientRead, clientWrite, upstreamRead, upstreamWrite])
        for fd in descriptors {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw RouterError.commandFailed }
        }
        var toServer = Data(), toClient = Data()
        var clientClosed = false, upstreamClosed = false
        var closingAt: Date?
        var firstClosure: EndReason?
        var buffer = [UInt8](repeating: 0, count: 65_536)
        func writePending(_ fd: Int32, _ data: inout Data) throws {
            guard !data.isEmpty else { return }
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
            if count > 0 { data = Data(data.dropFirst(count)) }
            else if count < 0 && ![EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { throw RouterError.commandFailed }
        }
        while !shouldStop() {
            if clientClosed && upstreamClosed && toServer.isEmpty && toClient.isEmpty { return firstClosure ?? .stopped }
            if closingAt.map({ Date().timeIntervalSince($0) > 1 }) == true { return firstClosure ?? .stopped }
            var fds = [
                pollfd(fd: !clientClosed && toServer.isEmpty ? clientRead : -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: !upstreamClosed && toClient.isEmpty ? upstreamRead : -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: toServer.isEmpty ? -1 : upstreamWrite, events: Int16(POLLOUT), revents: 0),
                pollfd(fd: toClient.isEmpty ? -1 : clientWrite, events: Int16(POLLOUT), revents: 0)
            ]
            let ready = poll(&fds, nfds_t(fds.count), 100)
            if ready < 0 { if errno == EINTR { continue }; throw RouterError.commandFailed }
            for index in 0..<2 where fds[index].events != 0 && fds[index].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fds[index].fd, $0.baseAddress!, $0.count) }
                if count > 0 {
                    let data = Data(buffer.prefix(count))
                    if index == 0 { toServer = data } else { toClient = data }
                    observe(index == 0 ? .client : .server, data)
                } else if count == 0 || (count < 0 && ![EINTR, EAGAIN, EWOULDBLOCK].contains(errno)) {
                    if index == 0 { clientClosed = true } else { upstreamClosed = true }
                    firstClosure = firstClosure ?? (index == 0 ? .clientClosed : .upstreamClosed)
                    closingAt = closingAt ?? Date()
                }
            }
            if fds[2].revents & Int16(POLLOUT) != 0 { try writePending(upstreamWrite, &toServer) }
            if fds[3].revents & Int16(POLLOUT) != 0 { try writePending(clientWrite, &toClient) }
            if fds.contains(where: { $0.events != 0 && $0.revents & Int16(POLLERR | POLLNVAL) != 0 }) { throw RouterError.commandFailed }
        }
        return firstClosure ?? .stopped
    }
}

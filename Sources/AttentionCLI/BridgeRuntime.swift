import Foundation
import Darwin
import AttentionCore

private nonisolated(unsafe) var bridgeTerminated: Int32 = 0
private func stopBridge(_ signal: Int32) { bridgeTerminated = 1 }

/// Development-only bridge for the source-reviewed installed version. No shell,
/// PTY emulator, daemon restart, approval writer or model prompt is involved.
enum BridgeRuntime {
    static let nativeCodex = "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
    static let iterm = "/Applications/iTerm.app/Contents/Resources/utilities/it2"
    struct Ticket: Codable {
        let schema: Int
        let connectionID: String
        let expected: ProcessOriginHint
        let terminal: TerminalIdentity
        let dataRoot: URL
        let project: String
        let nativeClientVersion: String
        /// Absent in old tickets. Only a picker launch admits one pre-thread,
        /// sequential handoff by the same original TUI process.
        let startupPicker: Bool?
        let nativeExecutable: String?
    }
    static func readPrivate(_ file: URL) throws -> Data {
        try LocalStore.ensurePrivateDirectory(file.deletingLastPathComponent())
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw RouterError.unsafeStorage }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_size <= 16_384 else { throw RouterError.unsafeStorage }
        return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
    }
    static func writePrivate(_ data: Data, to file: URL) throws {
        try LocalStore.ensurePrivateDirectory(file.deletingLastPathComponent())
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static func stopChild(_ child: Process) {
        guard child.isRunning else { return }
        child.terminate()
        let deadline = Date().addingTimeInterval(2)
        while child.isRunning && Date() < deadline { usleep(10_000) }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        child.waitUntilExit()
    }
    static func output(_ executable: String, _ args: [String], timeout: TimeInterval = 5) throws -> Data {
        let child = Process(), pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: executable); child.arguments = args
        child.standardInput = FileHandle.nullDevice; child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
        try child.run(); defer { stopChild(child); try? pipe.fileHandleForReading.close() }
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let end = Date().addingTimeInterval(timeout)
        var result = Data(), bytes = [UInt8](repeating: 0, count: 65_536)
        while Date() < end {
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&pollFD, 1, 50)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                result.append(contentsOf: bytes.prefix(count))
                guard result.count <= 1_048_576 else { throw RouterError.oversizedPayload }
            } else if count == 0 {
                while child.isRunning && Date() < end { usleep(10_000) }
                guard !child.isRunning, child.terminationStatus == 0 else { throw RouterError.commandFailed }
                return result
            } else if ![EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { throw RouterError.commandFailed }
        }
        throw RouterError.commandFailed
    }
    static func inventory() throws -> ([TerminalSession], [String: UInt32]) {
        let sessions = try JSONDecoder().decode([TerminalSession].self, from: output(iterm, ["session", "list", "--json"]))
        var devices: [String: UInt32] = [:]
        for session in sessions {
            if let tty = session.tty, let device = ProcessOriginProbe.terminalDevice(tty) { devices[tty] = device }
        }
        return (sessions, devices)
    }
    static func launch(_ args: [String]) throws -> Never {
        guard let invocation = try? BridgeInvocation(arguments: args) else {
            throw BridgeFailure.usage
        }
        let root = invocation.dataRoot, launch = invocation.launch
        let nativeCodex = invocation.nativeExecutable ?? Self.nativeCodex
        try LocalStore.requireSeparate(root)
        _ = try LocalStore(root: root)
        try LocalStore.requireSeparate(root)
        var stage = "foreground-terminal"
        var diagnostic: [String: Any] = ["stdin_is_terminal": isatty(STDIN_FILENO) == 1,
            "stdout_is_terminal": isatty(STDOUT_FILENO) == 1,
            "iterm_identity_present": ProcessInfo.processInfo.environment["ITERM_SESSION_ID"] != nil]
        let candidate = ProcessOriginProbe.snapshot(getpid())
        diagnostic["kernel_process_metadata_present"] = candidate != nil
        diagnostic["has_controlling_terminal"] = candidate?.hasControllingTerminal ?? false
        diagnostic["is_process_group_leader"] = candidate.map { $0.processGroup == UInt32($0.pid) } ?? false
        diagnostic["process_group_is_foreground"] = candidate.map { $0.terminalGroup == $0.processGroup } ?? false
        diagnostic["stdin_group_is_foreground"] = candidate.map { tcgetpgrp(STDIN_FILENO) == Int32($0.processGroup) } ?? false
        try writePrivate(JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys]),
            to: root.appendingPathComponent("bridge-launch-diagnostic.json"))
        defer {
            diagnostic["failed_stage"] = stage
            try? writePrivate(JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys]),
                to: root.appendingPathComponent("bridge-launch-diagnostic.json"))
        }
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1,
              let expected = ProcessOriginProbe.snapshot(getpid()), expected.pid > 1,
              expected.hasControllingTerminal, expected.processGroup == UInt32(expected.pid),
              expected.terminalGroup == expected.processGroup,
              let raw = ProcessInfo.processInfo.environment["ITERM_SESSION_ID"] else { throw RouterError.unverifiedOrigin }
        let terminal = TerminalIdentity(sessionID: raw)
        stage = "iterm-inventory"
        let (sessions, devices) = try inventory()
        stage = "terminal-identity"
        let selected = try SessionLocator.exact(terminal, in: sessions)
        let matches = sessions.filter { $0.tty.flatMap { devices[$0] } == expected.terminalDevice }
        guard matches.count == 1, matches[0].id == selected.id else { throw RouterError.unverifiedOrigin }
        stage = "installed-version"
        try requireReviewedNativeExecutable(nativeCodex)
        stage = "private-worker"
        var template = Array("/private/tmp/aar-bridge-XXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else { throw RouterError.unsafeStorage }
        let directory = URL(fileURLWithPath: String(cString: created), isDirectory: true)
        let ticketURL = directory.appendingPathComponent("ticket.json")
        let ticket = Ticket(schema: 1, connectionID: UUID().uuidString, expected: expected,
            terminal: terminal, dataRoot: root, project: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).lastPathComponent,
            nativeClientVersion: BridgeCompatibility.nativeClientVersion,
            startupPicker: launch.permitsStartupPickerHandoff ? true : nil,
            nativeExecutable: invocation.nativeExecutable)
        try writePrivate(JSONEncoder().encode(ticket), to: ticketURL)
        let worker = Process()
        worker.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        worker.arguments = ["bridge-worker", "--configuration", ticketURL.path]
        worker.standardInput = FileHandle.nullDevice; worker.standardOutput = FileHandle.nullDevice; worker.standardError = FileHandle.nullDevice
        try worker.run()
        let ready = directory.appendingPathComponent("ready")
        let deadline = Date().addingTimeInterval(8)
        while !FileManager.default.fileExists(atPath: ready.path) && worker.isRunning && Date() < deadline { usleep(20_000) }
        guard worker.isRunning, FileManager.default.fileExists(atPath: ready.path) else {
            stopChild(worker); cleanup(directory); throw BridgeFailure.startup
        }
        stage = "exec-native-tui"
        // exec preserves this foreground PID/group and its original terminal.
        // Use the installed native binary, avoiding npm's extra child process.
        // Remote TUI mode omits cwd unless --cd is explicit, even on this same
        // host. Preserve the owner's actual project rather than daemon defaults.
        let argv = [nativeCodex] + launch.nativeArguments(
            endpoint: "unix://" + directory.appendingPathComponent("socket").path,
            directory: FileManager.default.currentDirectoryPath)
        let strings = argv.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var pointers = strings + [nil]
        execv(nativeCodex, &pointers)
        stopChild(worker); cleanup(directory); throw BridgeFailure.startup
    }
    static func cleanup(_ directory: URL) {
        // Only fixed files in this newly-created, validated private directory.
        guard validTemporaryDirectory(directory),
              (try? LocalStore.ensurePrivateDirectory(directory)) != nil else { return }
        for name in ["socket", "ticket.json", "ready"] { _ = unlink(directory.appendingPathComponent(name).path) }
        _ = rmdir(directory.path)
    }
    static func validTemporaryDirectory(_ directory: URL) -> Bool {
        BridgeDirectoryPolicy.accepts(directory)
    }
    static func validateNativeExecutable(_ path: String) throws {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              FileManager.default.isExecutableFile(atPath: path),
              URL(fileURLWithPath: path).lastPathComponent == "codex" else { throw BridgeFailure.version }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        // Native arm64 Mach-O only. Do not exec an npm/JS/shell wrapper, which
        // would invalidate the original foreground PID relationship.
        guard let header = try handle.read(upToCount: 8),
              Array(header) == [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01] else { throw BridgeFailure.version }
    }
    static func requireReviewedNativeExecutable(_ path: String) throws {
        try validateNativeExecutable(path)
        let version: Data
        do { version = try output(path, ["--version"], timeout: 30) }
        catch { throw BridgeFailure.nativeDependency }
        guard BridgeCompatibility.acceptsNativeVersionOutput(version) else { throw BridgeFailure.version }
    }
    static func worker(_ file: URL) throws {
        let ticket = try JSONDecoder().decode(Ticket.self, from: readPrivate(file))
        let directory = file.deletingLastPathComponent()
        guard file.lastPathComponent == "ticket.json", validTemporaryDirectory(directory),
              ticket.schema == 1, UUID(uuidString: ticket.connectionID) != nil,
              ticket.expected.uid == getuid(), ticket.expected.pid == getppid(),
              ticket.terminal.guid != nil, ticket.dataRoot.standardizedFileURL.path != LocalStore.defaultRoot.standardizedFileURL.path else { throw RouterError.unverifiedOrigin }
        defer { cleanup(directory) }
        guard ticket.nativeClientVersion == BridgeCompatibility.nativeClientVersion else { throw BridgeFailure.version }
        let native = ticket.nativeExecutable ?? nativeCodex
        try validateNativeExecutable(native)
        signal(SIGPIPE, SIG_IGN); signal(SIGTERM, stopBridge); signal(SIGINT, stopBridge); signal(SIGHUP, stopBridge)
        let store = try LocalStore(root: ticket.dataRoot)
        try LocalStore.requireSeparate(ticket.dataRoot)
        var listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw RouterError.commandFailed }; defer { if listener >= 0 { close(listener) } }
        guard fcntl(listener, F_SETFD, FD_CLOEXEC) == 0 else { throw RouterError.commandFailed }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let socketPath = directory.appendingPathComponent("socket").path
        let bytes = Array(socketPath.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw RouterError.unsafeStorage }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(listener, 1) == 0 else { throw RouterError.commandFailed }
        try writePrivate(Data("ready\n".utf8), to: directory.appendingPathComponent("ready"))
        let connectionLimit = ticket.startupPicker == true ? 2 : 1
        for connectionIndex in 1...connectionLimit {
            var client: Int32 = -1
            // The native TUI can show an update prompt before opening its socket.
            // Allow time for a human to review it; peer PID/UID checks and the
            // launcher's process-lifetime check below remain mandatory throughout.
            let deadline = Date().addingTimeInterval(connectionIndex == 1 ? 10 * 60 : 30)
            while Date() < deadline && bridgeTerminated == 0 {
                guard ProcessOriginProbe.snapshot(ticket.expected.pid)?.startMicroseconds == ticket.expected.startMicroseconds else { throw RouterError.unverifiedOrigin }
                var pollFD = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                if poll(&pollFD, 1, 100) <= 0 { continue }
                let candidate = accept(listener, nil, nil)
                guard candidate >= 0 else { continue }
                var uid: uid_t = 0, gid: gid_t = 0, peer: pid_t = 0
                var size = socklen_t(MemoryLayout<pid_t>.size)
                if getpeereid(candidate, &uid, &gid) == 0 && uid == getuid(),
                   getsockopt(candidate, SOL_LOCAL, LOCAL_PEERPID, &peer, &size) == 0,
                   peer == ticket.expected.pid { client = candidate; break }
                close(candidate)
            }
            guard client >= 0 else { throw BridgeFailure.startup }; defer { close(client) }
            if connectionIndex == connectionLimit {
                close(listener); listener = -1 // No further connection is admitted.
            }
            guard fcntl(client, F_SETFD, FD_CLOEXEC) == 0 else { throw RouterError.commandFailed }
            guard let live = ProcessOriginProbe.snapshot(ticket.expected.pid), live.startMicroseconds == ticket.expected.startMicroseconds,
                  live.terminalDevice == ticket.expected.terminalDevice, live.isDirectForegroundCandidate else { throw RouterError.unverifiedOrigin }
            let (sessions, devices) = try inventory()
            let origin = VerifiedTerminalOrigin(terminal: ticket.terminal, process: live)
            _ = try ProcessOriginVerifier.revalidate(origin, live: live, sessions: sessions, devices: devices, currentUID: getuid())
            let connectionID = connectionIndex == 1 ? ticket.connectionID : UUID().uuidString
            guard try runConnection(client, origin: origin, ticket: ticket, store: store,
                                    connectionID: connectionID, connectionIndex: connectionIndex,
                                    listenerClosed: listener < 0) else { return }
        }
    }
    /// One connection owns its proxy, observer, taps and fresh binding. All are
    /// retired before the worker can authenticate the optional second peer.
    static func runConnection(_ client: Int32, origin: VerifiedTerminalOrigin, ticket: Ticket,
                              store: LocalStore, connectionID: String, connectionIndex: Int,
                              listenerClosed: Bool) throws -> Bool {
        let workerBuildUUID = MachOBuildIdentity.loadedUUID()
        var observer = CodexProtocolObserver(binding: .init(id: connectionID, origin: origin), project: ticket.project, workerBuildUUID: workerBuildUUID)
        var clientTap = WebSocketTap(masked: true), serverTap = WebSocketTap(masked: false)
        let upstream = Process(), input = Pipe(), outputPipe = Pipe()
        upstream.executableURL = URL(fileURLWithPath: ticket.nativeExecutable ?? nativeCodex); upstream.arguments = ["app-server", "proxy"]
        upstream.standardInput = input; upstream.standardOutput = outputPipe; upstream.standardError = FileHandle.nullDevice
        try upstream.run()
        defer { stopChild(upstream); try? input.fileHandleForWriting.close(); try? outputPipe.fileHandleForReading.close() }
        var observationFailed = false
        var reportedGaps = 0
        var eventCount = 0
        func emit(_ events: [AgentEvent]) {
            for event in events { do { try store.enqueue(event); eventCount += 1 } catch { observationFailed = true } }
        }
        defer { emit(observer.disconnect()) }
        let started = Date()
        var completedNormally = false
        var handoffEligible = false
        func receipt(_ status: String) {
            let result: [String: Any] = ["bridge_connection": connectionID, "status": status,
                "worker_build_uuid": workerBuildUUID as Any? ?? NSNull(),
                "native_client_version": ticket.nativeClientVersion,
                "accepted_connections": connectionIndex,
                "connection_limit": ticket.startupPicker == true ? 2 : 1,
                "listener_closed_after_first_peer": ticket.startupPicker != true,
                "listener_closed_on_accept": listenerClosed, "startup_handoff_eligible": handoffEligible,
                "observed_picker_metadata_requests": observer.pickerMetadataRequestCount,
                "interaction_coverage_notices": observer.coverageNoticeCount,
                "duration_seconds": Date().timeIntervalSince(started), "events_observed": eventCount,
                "observation_gap": observationFailed || reportedGaps > 0, "observation_stopped": observationFailed,
                "decisions_generated": false, "raw_protocol_persisted": false,
                "oversized_metadata_gaps": reportedGaps,
                "largest_skipped_payload_bytes": max(clientTap.largestSkippedPayloadBytes, serverTap.largestSkippedPayloadBytes),
                "ignored_oversized_metadata_responses": observer.ignoredOversizedMethods,
                "client_tap_failure": clientTap.failureReason ?? "none", "server_tap_failure": serverTap.failureReason ?? "none"]
            try? writePrivate(JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
                to: ticket.dataRoot.appendingPathComponent("bridge-" + connectionID + ".json"))
        }
        receipt("connected")
        defer { receipt(completedNormally ? "disconnected" : "transport-failed") }
        var lastProbe = Date.distantPast
        let end = try BridgeRelay.run(clientRead: client, clientWrite: client,
            upstreamRead: outputPipe.fileHandleForReading.fileDescriptor, upstreamWrite: input.fileHandleForWriting.fileDescriptor,
            shouldStop: {
                // Read pipe EOF even after the proxy exits, so the relay can
                // distinguish client handoff from an upstream-originated close.
                if bridgeTerminated != 0 { return true }
                if Date().timeIntervalSince(lastProbe) >= 1 {
                    lastProbe = Date()
                    return ProcessOriginProbe.snapshot(ticket.expected.pid)?.startMicroseconds != ticket.expected.startMicroseconds
                }
                return false
            }, observe: { direction, data in
                guard !observationFailed else { return }
                let observations = direction == .client ? clientTap.feedEvents(data) : serverTap.feedEvents(data)
                if clientTap.failed || serverTap.failed {
                    emit(observer.disconnect()); observationFailed = true; receipt("connected-with-observation-gap"); return
                }
                for observation in observations {
                    switch observation {
                    case .message(let message):
                        let pickerCount = observer.pickerMetadataRequestCount
                        let coverageCount = observer.coverageNoticeCount
                        emit(observer.observe(message, from: direction))
                        if observer.pickerMetadataRequestCount != pickerCount || observer.coverageNoticeCount != coverageCount {
                            receipt(observationFailed || reportedGaps > 0 ? "connected-with-observation-gap" : "connected")
                        }
                    case .oversizedPrefix(let prefix):
                        if direction == .server && observer.ignoreOversizedServerResponse(prefix) {
                            receipt("connected")
                        } else {
                            reportedGaps += 1; emit(observer.observationGap()); receipt("connected-with-metadata-gap")
                        }
                    }
                }
            })
        completedNormally = true
        handoffEligible = bridgeTerminated == 0 && BridgeStartupHandoff.permits(
            pickerLaunch: ticket.startupPicker == true, connectionIndex: connectionIndex,
            end: end, observerHealthy: !observationFailed && reportedGaps == 0,
            eventCount: eventCount, hasThreadSessionRequest: observer.hasThreadSessionRequest)
        return handoffEligible
    }
}

enum BridgeFailure: LocalizedError {
    case usage, version, startup, nativeDependency
    var errorDescription: String? {
        switch self {
        case .usage: "Isolated POC: aar codex --data-dir /private/test-directory [--native-codex /absolute/path/codex] -- [--no-alt-screen] [resume [SESSION_UUID]]. Resume opens the native picker when no UUID is given. Other Codex arguments are not enabled."
        case .version: "This development bridge requires the reviewed native Codex \(BridgeCompatibility.nativeClientVersion) installation. Other versions are not enabled."
        case .nativeDependency: "The native Codex version check failed or exceeded 30 seconds. Check the installed native executable or the explicit --native-codex path. No terminal focus was attempted."
        case .startup: "The private bridge could not establish its verified local connection. Ordinary Codex remains available."
        }
    }
}

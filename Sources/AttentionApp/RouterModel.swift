import AppKit
import SwiftUI
import UserNotifications
import AttentionCore
import Darwin

@MainActor final class RouterModel: ObservableObject {
    @Published var state = RouterState()
    @Published var message: String?
    @Published var focusInProgress: String?
    @Published var notificationStatus = "Not checked"
    @Published var buildStatus = BuildStatus(running: nil, onDisk: nil)
    @Published var installedHelperBuildUUID: String?
    @Published var deliveryHealth = NotificationDeliveryHealth()
    @Published var snapshotBytes: Int64?
    @Published var snapshotReadFailed = false
    @Published var diagnosticWriteFailed = false
    enum MonitoringHealth: String { case notStarted, ready, processingFailed, acknowledgementFailed, unavailable }
    @Published var monitoringHealth = MonitoringHealth.notStarted
    private let runningBuildUUID = RuntimeBuildProbe.loadedUUID()
    private let receiverStartedAt = Date()
    @Published var paused = false
    @Published var notificationsEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled") { didSet { if !demo { UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled") } } }
    @Published var soundEnabled = UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true { didSet { if !demo { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") } } }
    @Published var hideProjects = UserDefaults.standard.bool(forKey: "hideProjects") { didSet { if !demo { UserDefaults.standard.set(hideProjects, forKey: "hideProjects") } } }
    @Published var filterAttention = false
    let demo: Bool
    var onCountChanged: ((Int) -> Void)?
    var onNotify: ((AgentEvent, AgentSession) -> Void)?
    var storage: LocalStore?
    var consumerLock: FileHandle?
    private(set) var originPOC: OriginPOC?
    private(set) var bridgePOC = false
    private let startupSelection: StartupSelection
    @Published private(set) var savedStartup: BridgeStartupProfile?
    @Published private(set) var hasSavedStartup = false
    @Published private(set) var chosenNativeCodex: String?
    @Published private(set) var nativeChoiceUnavailable = false
    @Published private(set) var checkingNativeCodex = false
    @Published private(set) var nativeCodexStatus = "Not checked · Each launch verifies the native file and version"
    @Published private var nativeCheckFailed = false
    private var canSaveNativeChoice: Bool { !demo && !ReceiverLaunchPolicy.isExplicitRun(CommandLine.arguments) }
    var nativeCodexPath: String? { nativeChoiceUnavailable ? nil : chosenNativeCodex ?? NativeCodex.defaultPath }
    var canCopyNativeCommands: Bool { !nativeChoiceUnavailable && !checkingNativeCodex && !nativeCheckFailed }
    var nativeChoiceScopeDescription: String {
        canSaveNativeChoice ? "Saved choices apply to this app’s future normal launches." :
            "This isolated run does not change your daily app’s native-file choice."
    }
    var startupBlocked: Bool { startupSelection.mode == .blocked && !demo }
    var canRememberStartup: Bool { !demo && bridgePOC && monitoringHealth == .ready }
    var currentModeDescription: String {
        demo ? "Preview only" : startupBlocked ? "Startup paused" : bridgePOC ? "Connected bridge" : "Hook monitoring"
    }
    var nextLaunchDescription: String {
        guard hasSavedStartup else { return "Hook monitoring · No saved bridge" }
        guard let savedStartup else { return "Saved bridge could not be read · Choose again or forget" }
        return "Bridge · " + savedStartup.rootPath
    }
    var onRoutingTest: (() -> Void)?
    var onDeliveryTest: (() -> Void)?
    private let notificationDelivery = NotificationDelivery()
    var watcher: DispatchSourceFileSystemObject?
    private var watchedInbox: (dev_t, ino_t)?
    private var watcherGeneration = 0
    var maintenance: Timer?
    var terminalCheckTimer: Timer?
    private var registeredProcesses: [Int32: RegisteredProcessStatus] = [:]
    private var lastTerminalCheck = Date.distantPast
    var root: URL
    var sessions: [AgentSession] {
        guard bridgePOC else { return state.sortedSessions }
        // Keep unresolved attention after disconnect, but don't count empty old
        // startup fixtures as currently connected agents.
        return state.sortedSessions.filter { $0.verifiedProtocolBinding != nil || ($0.protocolBindings ?? [:]).values.contains(where: \.connected) || $0.needsAttention }
    }
    var recordedOverview: SessionOverview {
        .init(state: state, bridgeMode: bridgePOC || (demo && state.sessions.values.contains { $0.protocolBindings != nil }))
    }
    var threadVisibility: OpenThreadFilter {
        if demo {
            let processes = state.sessions.values.flatMap { ($0.protocolBindings ?? [:]).values.filter(\.connected).map(\.binding.origin.process) }
                .reduce(into: [Int32: RegisteredProcessStatus]()) { $0[$1.pid] = .present($1) }
            return .init(state: state, processes: processes, currentUID: 501)
        }
        return .init(state: state, processes: registeredProcesses, currentUID: getuid())
    }
    var overview: SessionOverview {
        .init(state: state, bridgeMode: bridgePOC || demo, visibleThreadIDs: threadVisibility.visibleThreadIDs)
    }
    var mainWorkerBuildNeedsCheck: Bool {
        overview.registeredThreads.contains { workerBuildStatus(for: $0).map { $0.status != .current } ?? false }
    }
    var attentionCount: Int { overview.attentionCount }
    var workingCount: Int { overview.workingCount }
    func refreshOpenThreads(force: Bool = false) {
        guard !demo, force || Date().timeIntervalSince(lastTerminalCheck) >= 2 else { return }
        lastTerminalCheck = Date()
        let pids = Set(state.sessions.values.flatMap { ($0.protocolBindings ?? [:]).values.filter(\.connected).map(\.binding.origin.process.pid) })
        let previous = threadVisibility
        let inspected = pids.reduce(into: [Int32: RegisteredProcessStatus]()) { $0[$1] = OpenThreadFilter.inspect($1) }
        let next = OpenThreadFilter(state: state, processes: inspected, currentUID: getuid())
        // Refresh kernel evidence on every poll. Only the presentation result
        // needs to invalidate SwiftUI; probe timestamps alone do not change it.
        if previous.visibleThreadIDs != next.visibleThreadIDs || previous.unavailableProcessIDs != next.unavailableProcessIDs {
            objectWillChange.send()
        }
        registeredProcesses = inspected
        onCountChanged?(attentionCount)
    }
    func setArchived(_ id: String, archived: Bool) {
        var next = state
        guard next.setArchived(id, archived: archived) else {
            message = "Active turns and observed or confirmed requests stay in the main list."
            return
        }
        do {
            if !demo {
                guard let storage else { throw RouterError.unsafeStorage }
                try storage.save(next)
            }
            state = next
            message = archived ? "Archived from the list. Requests are unchanged; new activity needing review restores the entry." : "Record restored. Closed sources remain hidden from the main list; request states are unchanged."
            onCountChanged?(attentionCount)
            refreshDiagnostics()
        } catch { message = "The list change could not be saved. Your sessions are unchanged." }
    }
    var hasBridgeBuildDiagnostics: Bool { bridgePOC || sessions.contains { !($0.protocolBindings ?? [:]).isEmpty } }
    func workerBuildStatus(for session: AgentSession) -> BridgeWorkerBuildStatus? {
        guard bridgePOC || !(session.protocolBindings ?? [:]).isEmpty else { return nil }
        return .init(session: session, installedHelper: installedHelperBuildUUID)
    }
    var workerBuildCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for session in sessions {
            if let health = workerBuildStatus(for: session) { counts[health.status.rawValue, default: 0] += 1 }
        }
        return counts
    }
    var routingNotice: String? {
        if demo { return nil }
        if bridgePOC { return "Local bridge POC · Exact return uses each registered connection." }
        return originPOC == nil ? "Exact return is paused until terminal origin is verified." :
            "Local POC · Exact return is limited to one verified comparison pane."
    }
    var hasRoutingPOC: Bool { !demo && originPOC != nil }

    init(demo: Bool? = nil) {
        self.demo = demo ?? CommandLine.arguments.contains("--demo")
        let preference = self.demo || CommandLine.arguments.contains("--render-previews") ? nil : UserDefaults.standard.object(forKey: BridgeStartupProfile.defaultsKey)
        let saved = preference.map { $0 as? Data ?? Data() }
        let arguments = CommandLine.arguments + (self.demo ? ["--demo"] : [])
        startupSelection = StartupSelection.resolve(arguments: arguments, saved: saved)
        root = startupSelection.root
        bridgePOC = !self.demo && startupSelection.mode == .bridge
        hasSavedStartup = preference != nil
        savedStartup = saved.flatMap { try? BridgeStartupProfile.decode($0) }
        if !self.demo { message = startupSelection.issue }
        if self.demo { state = DemoData.state(); notificationStatus = "Preview mode" }
        else if !startupBlocked, !bridgePOC, let index = CommandLine.arguments.firstIndex(of: "--poc-origin-case"), CommandLine.arguments.count > index + 1 {
            do { originPOC = try OriginPOC.load(URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            catch { message = "The local routing test fixture could not be verified. Exact return remains paused." }
        }
        if canSaveNativeChoice, let preference = UserDefaults.standard.object(forKey: NativeCodexPreference.defaultsKey) {
            do { chosenNativeCodex = try NativeCodexPreference.decode(preference as? Data ?? Data()).path }
            catch { nativeChoiceUnavailable = true; nativeCodexStatus = "Saved native file choice cannot be read. Choose again or use the default." }
        }
        refreshDiagnostics()
    }
    func chooseNativeCodex() {
        guard !demo, !checkingNativeCodex else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose native Codex \(BridgeCompatibility.nativeClientVersion)"
        panel.message = "Select the native arm64 executable named codex. The read-only version check does not start a conversation."
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        verifyNativeCodex(path, saveChoice: true)
    }
    func checkNativeCodex() {
        guard let path = nativeCodexPath else { return }
        verifyNativeCodex(path, saveChoice: false)
    }
    func useDefaultNativeCodex() {
        guard !demo, !checkingNativeCodex else { return }
        chosenNativeCodex = nil; nativeChoiceUnavailable = false; nativeCheckFailed = false
        nativeCodexStatus = "Default file selected · Each launch still checks the native version"
        if canSaveNativeChoice { UserDefaults.standard.removeObject(forKey: NativeCodexPreference.defaultsKey) }
    }
    private func verifyNativeCodex(_ path: String, saveChoice: Bool) {
        guard !demo, !checkingNativeCodex else { return }
        checkingNativeCodex = true; nativeCodexStatus = "Checking native file/version · Up to 30 seconds"
        Task { [weak self] in
            let failure = await Task.detached {
                do { try NativeCodex.verifyVersion(path); return nil as String? }
                catch { return error.localizedDescription }
            }.value
            guard let self else { return }
            self.checkingNativeCodex = false
            if let failure {
                // An unsuccessful new selection does not replace the existing choice.
                if !saveChoice { self.nativeCheckFailed = true }
                self.nativeCodexStatus = failure + (saveChoice ? " Current file choice was kept." : "")
                return
            }
            if saveChoice {
                do {
                    let preference = try NativeCodexPreference(path: path)
                    if self.canSaveNativeChoice { UserDefaults.standard.set(try preference.encoded(), forKey: NativeCodexPreference.defaultsKey) }
                    self.chosenNativeCodex = preference.path; self.nativeChoiceUnavailable = false
                } catch { self.nativeCodexStatus = "The selected native file choice could not be saved."; return }
            }
            self.nativeCheckFailed = false
            self.nativeCodexStatus = "Native Codex \(BridgeCompatibility.nativeClientVersion) verified · This check does not verify backend, login or iTerm API access"
        }
    }
    func start() {
        if demo { onCountChanged?(attentionCount); return }
        if startupBlocked { monitoringHealth = .unavailable; return }
        do {
            if let restored = startupSelection.restored { _ = try restored.validatedRoot() }
            storage = try LocalStore(root: root)
            if let restored = startupSelection.restored { _ = try restored.validatedRoot() }
            if bridgePOC { try LocalStore.requireSeparate(root) }
            consumerLock = try storage!.lockConsumer(); state = try storage!.load()
            try watchInbox(storage!)
            consume()
            maintenance = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.consume() }
            }
            terminalCheckTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshOpenThreads(force: true); self?.refreshDiagnostics() }
            }
        } catch { storage = nil; monitoringHealth = .unavailable; message = "Monitoring could not start: \(error.localizedDescription)" }
        refreshDiagnostics()
        refreshAuthorization()
    }
    func rememberBridgeStartup() {
        guard canRememberStartup else { return }
        saveStartup(root)
    }
    func prepareDefaultBridgeStartup() {
        guard !demo, !bridgePOC, !hasSavedStartup else { return }
        let directory = LocalStore.defaultRoot.deletingLastPathComponent()
            .appendingPathComponent("AgentAttentionRouter-Bridge", isDirectory: true)
        do {
            try LocalStore.requireSeparate(directory)
            _ = try LocalStore(root: directory)
            saveStartup(directory)
        } catch {
            message = "The default bridge folder could not be prepared safely. Choose an existing private folder instead."
        }
    }
    func chooseBridgeStartup() {
        guard !demo else { return }
        let panel = NSOpenPanel()
        panel.title = "Bridge startup folder"
        panel.message = "Choose an existing private Attention Router data folder. This changes the next app launch; current sessions stay on their existing connection."
        panel.prompt = "Use on next launch"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
        panel.directoryURL = savedStartup.map { URL(fileURLWithPath: $0.rootPath) } ?? root
        if panel.runModal() == .OK, let selected = panel.url { saveStartup(selected) }
    }
    private func saveStartup(_ selected: URL) {
        do {
            let profile = try BridgeStartupProfile(root: selected)
            UserDefaults.standard.set(try profile.encoded(), forKey: BridgeStartupProfile.defaultsKey)
            savedStartup = profile; hasSavedStartup = true
            message = "Startup saved. Quit and reopen this app normally to use this bridge folder. Current sessions are unchanged."
        } catch {
            message = "Startup was not changed. Choose an existing private data folder, separate from normal monitoring."
        }
    }
    func forgetBridgeStartup() {
        guard !demo else { return }
        UserDefaults.standard.removeObject(forKey: BridgeStartupProfile.defaultsKey)
        savedStartup = nil; hasSavedStartup = false
        message = "Saved startup forgotten. The next normal launch uses Hook monitoring. Stored sessions and current connections are preserved."
    }
    private func watchInbox(_ storage: LocalStore) throws {
        try storage.prepareInbox()
        let fd = open(storage.inbox.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RouterError.unsafeStorage }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(fd); throw RouterError.unsafeStorage
        }
        if let previous = watchedInbox, previous.0 == info.st_dev, previous.1 == info.st_ino {
            close(fd); return
        }
        watcher?.cancel(); watcherGeneration += 1
        let generation = watcherGeneration
        let next = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .revoke], queue: .main)
        next.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.watcherGeneration == generation else { return }
                self.consume()
            }
        }
        next.setCancelHandler { close(fd) }
        watchedInbox = (info.st_dev, info.st_ino); watcher = next; next.resume()
    }
    @discardableResult func consume() -> Bool {
        guard let storage else { return false }
        defer { refreshOpenThreads(); refreshDiagnostics() }
        do {
            try watchInbox(storage)
            var committed = state
            try notificationDelivery.flush(in: &committed, save: storage.save)
            if state != committed { state = committed }
            let batch = try storage.scan()
            let result = try InboxConsumer.consume(state, events: batch.events, rejected: batch.rejected,
                now: Date(), notificationsEnabled: notificationsEnabled && !paused && !CommandLine.arguments.contains("--no-notifications"),
                save: storage.save, acknowledge: storage.acknowledge)
            if state != result.state { state = result.state }
            let health: MonitoringHealth = result.acknowledgementFailures > 0 ? .acknowledgementFailed : .ready
            if monitoringHealth != health { monitoringHealth = health }
            for event in notificationDelivery.due(in: state, now: Date()) {
                if let session = state.sessions[event.sessionID] { onNotify?(event, session) }
            }
            if result.acknowledgementFailures > 0 {
                message = "Some processed event files could not be cleared. Monitoring continues; replay is deduplicated."
            } else if result.rejected > 0 {
                message = "\(result.rejected) invalid or unsupported event files were ignored. Valid sessions are still monitored."
            }
            onCountChanged?(attentionCount)
            return true
        } catch { monitoringHealth = .processingFailed; message = "An event could not be processed: \(error.localizedDescription)"; return false }
    }
    func focus(_ id: String) async {
        await performFocus(id, requiredInstance: nil, action: "menu_selection")
    }
    func focusNotification(_ id: String, instance: String?, callbackStarted: UInt64? = nil) async {
        guard let instance else {
            recordRoute(id, requested: nil, notification: true, outcome: .missingReference)
            message = "This notification has no verified original process. Your attention list is preserved."
            return
        }
        await performFocus(id, requiredInstance: instance, action: "native_notification_click", callbackStarted: callbackStarted)
    }
    private func recordRoute(_ id: String, requested: String?, notification: Bool, outcome: RoutingAttempt.Outcome, elapsedMilliseconds: Double? = nil) {
        guard !demo else { return }
        state.recordRoutingAttempt(.init(sessionID: id, requestedSource: requested,
            currentSource: state.sessions[id]?.verifiedProtocolBinding?.reference,
            notificationClick: notification, outcome: outcome, elapsedMilliseconds: elapsedMilliseconds))
        do { try storage?.save(state) }
        catch { message = "Routing history could not be saved. Your attention list is preserved." }
    }
    func notificationSourceInstance(_ event: AgentEvent) -> String? {
        if bridgePOC {
            guard let binding = event.protocolBinding,
                  let session = state.sessions[event.sessionID], session.verifiedProtocolBinding == binding,
                  let live = ProcessOriginProbe.snapshot(binding.origin.process.pid),
                  live.uid == getuid(), live.isDirectForegroundCandidate,
                  live.startMicroseconds == binding.origin.process.startMicroseconds,
                  live.terminalDevice == binding.origin.process.terminalDevice else { return nil }
            return binding.reference
        }
        guard let test = originPOC?.payload, event.sessionID == test.sessionID,
              let hint = event.processOriginHint, hint.isDirectForegroundCandidate,
              hint.instanceID == test.origin.process.instanceID,
              let session = state.sessions[event.sessionID], session.processOriginConflict != true,
              let current = session.processOriginHint, current.isDirectForegroundCandidate,
              current.instanceID == test.origin.process.instanceID,
              session.terminal?.guid == test.origin.terminal.guid else { return nil }
        return hint.instanceID
    }
    func prepareNotification(_ event: AgentEvent, session: AgentSession) -> NotificationPlan? {
        guard !demo, notificationsEnabled, !paused,
              !CommandLine.arguments.contains("--no-notifications"), let storage else { return nil }
        defer { refreshDiagnostics() }
        do {
            var next = state
            let plan = try notificationDelivery.prepare(event, sourceInstance: notificationSourceInstance(event),
                in: &next, now: Date(), save: storage.save)
            state = next
            return plan
        } catch {
            message = "A reminder could not be saved for delivery. Your attention list is preserved."
            return nil
        }
    }
    func completeNotification(_ plan: NotificationPlan, accepted: Bool) {
        guard let storage else { return }
        defer { refreshDiagnostics() }
        do {
            var next = state
            try notificationDelivery.complete(plan, accepted: accepted, in: &next, now: Date(), save: storage.save)
            state = next
            if !accepted { message = "A notification could not be submitted. A fresh, still-active reminder will retry; your attention list is preserved." }
        } catch { message = "Notification history could not be saved. Your attention list is preserved; saving will retry." }
    }
    func refreshDiagnostics() {
        let build = BuildStatus(running: runningBuildUUID, onDisk: RuntimeBuildProbe.diskUUID())
        if buildStatus != build { buildStatus = build }
        let helper = RuntimeBuildProbe.helperDiskUUID()
        if installedHelperBuildUUID != helper { installedHelperBuildUUID = helper }
        let delivery = notificationDelivery.health(in: state, now: Date())
        if deliveryHealth != delivery { deliveryHealth = delivery }
        guard !demo, let storage else { return }
        do {
            let bytes = try storage.snapshotBytes()
            if snapshotBytes != bytes { snapshotBytes = bytes }
            if snapshotReadFailed { snapshotReadFailed = false }
        } catch {
            if snapshotBytes != nil { snapshotBytes = nil }
            if !snapshotReadFailed { snapshotReadFailed = true }
        }
        struct Report: Encodable {
            let pid: Int32
            let receiverStartedAt: Date
            let recordedAt: Date
            let build: BuildStatus
            let buildComparison: BuildStatus.Status
            let monitoring: String
            let connectionMode: String
            let restoredStartup: Bool
            let installedHelperBuild: String?
            let workerBuildCounts: [String: Int]
            let listCounts: [String: Int]
            let mainListCounts: [String: Int]
            let unavailableTerminalChecks: Int
            let unreviewedCoverageNotices: Int
            let delivery: NotificationDeliveryHealth
            let snapshotBytes: Int64?
            let snapshotReadFailed: Bool
            let verifiedNotificationReturnLatency: LatencySummary
            let nativeDependencyChoice: String
        }
        do {
            let data = try JSONEncoder().encode(Report(pid: getpid(), receiverStartedAt: receiverStartedAt,
                recordedAt: Date(), build: buildStatus, buildComparison: buildStatus.status, monitoring: monitoringHealth.rawValue,
                connectionMode: bridgePOC ? "bridge" : "ordinary", restoredStartup: startupSelection.restored != nil,
                installedHelperBuild: installedHelperBuildUUID, workerBuildCounts: workerBuildCounts,
                listCounts: ["registeredSources": recordedOverview.registeredSourceCount,
                    "observedThreads": recordedOverview.registeredThreads.count, "historyThreads": recordedOverview.history.count,
                    "archivedThreads": recordedOverview.archived.count, "threadsToReview": recordedOverview.attentionCount],
                mainListCounts: ["registeredSources": overview.registeredSourceCount, "visibleThreads": overview.registeredThreads.count,
                    "threadsToReview": overview.attentionCount, "activeTurns": overview.workingCount],
                unavailableTerminalChecks: threadVisibility.unavailableProcessIDs.count,
                unreviewedCoverageNotices: sessions.filter { $0.protocolCoverageNotice?.reviewed == false }.count,
                delivery: deliveryHealth, snapshotBytes: snapshotBytes, snapshotReadFailed: snapshotReadFailed,
                verifiedNotificationReturnLatency: .init(state.routingAttempts ?? []),
                nativeDependencyChoice: nativeChoiceUnavailable ? "unreadable" : chosenNativeCodex == nil ? "default" : "custom"))
            try storage.saveRuntimeDiagnostics(data)
            if diagnosticWriteFailed { diagnosticWriteFailed = false }
        } catch { if !diagnosticWriteFailed { diagnosticWriteFailed = true } }
    }
    var buildDescription: String {
        let running = buildStatus.running.map { String($0.prefix(13)) } ?? "Unverified"
        let prefix = demo ? "Sample · " : ""
        switch buildStatus.status {
        case .current: return prefix + "\(running) · Running image matches this app on disk"
        case .restartNeeded: return prefix + "\(running) · App on disk changed; restart the receiver to load it"
        case .unverified: return prefix + "\(running) · Build comparison unavailable"
        }
    }
    var submissionDescription: String {
        guard let last = deliveryHealth.lastSubmission else { return "No agent reminder submission result in this receiver" }
        let time = last.recordedAt.formatted(date: .omitted, time: .standard)
        return last.outcome == .accepted ? "Accepted by macOS at \(time) · Banner display is unconfirmed" : "Submission failed at \(time) · Eligible reminders retry"
    }
    var queueDescription: String {
        let h = deliveryHealth
        var value = "\(h.waiting) waiting · \(h.retrying) retrying · \(h.submitting) awaiting macOS"
        if h.receiptsAwaitingSave > 0 { value += " · \(h.receiptsAwaitingSave) accepted receipts awaiting save" }
        if let date = h.nextRetryAt { value += "\nNext retry eligible at " + date.formatted(date: .omitted, time: .standard) }
        return value
    }
    var returnTimingDescription: String {
        timingDescription(.init(state.routingAttempts ?? []), scope: "Verified notification returns · Retained audit")
    }
    var submissionTimingDescription: String {
        timingDescription(deliveryHealth.acceptedEventLatency, scope: "Observed event to macOS acceptance · This receiver") +
            "\nIncludes retries; does not measure visible banner delivery. \(deliveryHealth.excludedLatencyObservations) invalid-clock samples excluded."
    }
    private func timingDescription(_ value: LatencySummary, scope: String) -> String {
        guard let p50 = value.p50Milliseconds, let p95 = value.p95Milliseconds else { return scope + "\nNo measured samples yet" }
        return scope + "\n\(value.samples) samples · p50 \(p50.formatted(.number.precision(.fractionLength(0)))) ms · p95 \(p95.formatted(.number.precision(.fractionLength(0)))) ms"
    }
    var storageDescription: String {
        var value = snapshotReadFailed ? "Snapshot size unavailable" : snapshotBytes.map {
            String(format: "%.2f MiB of 64 MiB snapshot limit", Double($0) / 1_048_576)
        } ?? "No snapshot written yet"
        if let failure = deliveryHealth.lastSaveFailure {
            value += "\nLast delivery save error: " + (failure.stage == .reservation ? "before submission" : "saving acceptance receipt")
            value += " at " + failure.recordedAt.formatted(date: .omitted, time: .standard)
        }
        if diagnosticWriteFailed { value += "\nDiagnostic report could not be saved" }
        return value
    }
    var monitoringDescription: String {
        if demo { return "Sample data · No live monitoring" }
        switch monitoringHealth {
        case .notStarted: return "Not started"
        case .ready: return "Private local inbox active"
        case .processingFailed: return "Inbox or snapshot processing failed · Attention retained"
        case .acknowledgementFailed: return "Committed events retained for deduplicated replay"
        case .unavailable: return "Monitoring could not start"
        }
    }
    private func performFocus(_ id: String, requiredInstance: String?, action: String, callbackStarted: UInt64? = nil) async {
        let routeStarted = min(callbackStarted ?? DispatchTime.now().uptimeNanoseconds, DispatchTime.now().uptimeNanoseconds)
        var outcome: RoutingAttempt.Outcome = .refused
        defer { recordRoute(id, requested: requiredInstance, notification: action == "native_notification_click", outcome: outcome,
                            elapsedMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - routeStarted) / 1e6) }
        guard !demo else { message = "Preview sessions are examples. Connect Codex to open a real terminal."; return }
        guard focusInProgress == nil else { message = "Another session is opening. Retry this reminder in a moment."; return }
        guard let session = state.sessions[id] else {
            message = "This reminder’s session is no longer in the current list. No other terminal was selected."
            return
        }
        let origin: VerifiedTerminalOrigin
        let revealIdentity: TerminalIdentity?
        let isAuthorized: () -> Bool
        if bridgePOC {
            guard let binding = try? ProtocolRoute.authorize(session, reference: requiredInstance) else {
                message = "This source is disconnected, shared by multiple clients, or belongs to an older connection. No terminal was selected."
                return
            }
            origin = binding.origin; revealIdentity = binding.origin.terminal
            isAuthorized = { [weak self] in
                guard let self, self.consume() else { return false }
                guard let current = self.state.sessions[id] else { return false }
                return (try? ProtocolRoute.authorize(current, reference: binding.reference)) == binding
            }
        } else if let test = originPOC?.payload, test.sessionID == id,
              session.execution != .ended,
              let current = session.processOriginHint, current.isDirectForegroundCandidate,
              current.instanceID == test.origin.process.instanceID,
              session.processOriginConflict != true,
              requiredInstance.map({ $0 == test.origin.process.instanceID }) ?? true {
            origin = test.origin; revealIdentity = session.terminal
            isAuthorized = { [weak self] in
                guard let self, self.consume(), let current = self.state.sessions[id] else { return false }
                return current.execution != .ended && current.processOriginConflict != true &&
                    current.processOriginHint?.instanceID == test.origin.process.instanceID
            }
        } else {
            message = "Exact return is unavailable for this source. Only the independently verified comparison pane is enabled in this local POC."
            return
        }
        focusInProgress = id; defer { focusInProgress = nil }
        let started = Date()
        do {
            // Raw environment GUIDs never authorize or replace this pinned binding.
            try await ITermAdapter.focus(origin, revealIdentity: revealIdentity, isAuthorized: isAuthorized)
            guard isAuthorized() else { throw RouterError.unverifiedOrigin }
            state.markReviewed(id); try storage?.save(state); message = nil
            outcome = .dispatched
            originPOC?.record(action: action, success: true, milliseconds: Date().timeIntervalSince(started) * 1000)
            onCountChanged?(attentionCount)
        } catch {
            outcome = (error as? RouterError) == .unverifiedOrigin ? .sourceChanged : .dispatchFailed
            message = error.localizedDescription
            originPOC?.record(action: action, success: false, milliseconds: Date().timeIntervalSince(started) * 1000,
                              failureStage: (error as? ITermAdapter.CommandFailure)?.stage.rawValue)
        }
    }
    func sendRoutingTest() {
        guard hasRoutingPOC, notificationsEnabled, !paused else {
            message = "Enable system notifications above and resume reminders before sending a test."
            return
        }
        onRoutingTest?()
    }
    func sendDeliveryTest() {
        guard !demo, notificationsEnabled, !paused,
              !CommandLine.arguments.contains("--no-notifications") else { return }
        onDeliveryTest?()
    }
    func requestNotifications() {
        guard !demo, Bundle.main.bundleIdentifier != nil else { message = "Use the built .app bundle to enable native notifications."; return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            Task { @MainActor in
                self?.notificationsEnabled = granted
                if error != nil { self?.message = "Notification permission could not be requested." }
                self?.refreshAuthorization()
            }
        }
    }
    func refreshAuthorization() {
        guard !demo, Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let deliverySettings = ["authorization": settings.authorizationStatus.rawValue,
                "alert_setting": settings.alertSetting.rawValue, "alert_style": settings.alertStyle.rawValue,
                "notification_center": settings.notificationCenterSetting.rawValue,
                "sound_setting": settings.soundSetting.rawValue,
                "scheduled_delivery": settings.scheduledDeliverySetting.rawValue]
            let value: String
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: value = "Allowed"
            case .denied: value = "Denied — attention stays in the menu bar"
            case .notDetermined: value = "Not requested"
            @unknown default: value = "Unknown"
            }
            Task { @MainActor in
                guard let self else { return }
                self.notificationStatus = value
                if let storage = self.storage {
                    do {
                        let report: [String: Any] = ["settings": deliverySettings,
                            "notifications_enabled": self.notificationsEnabled, "paused": self.paused,
                            "recorded_at": Date().timeIntervalSince1970]
                        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                        try LocalStore.ensurePrivateDirectory(storage.root)
                        let file = storage.root.appendingPathComponent("notification-health.json")
                        try data.write(to: file, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    } catch { /* Health receipt never changes permission or monitoring. */ }
                }
            }
        }
    }
}

enum DemoData {
    static func organizedState() -> RouterState {
        var state = RouterState(); let now = Date()
        for (index, name) in ["Sample workspace", "Sample workspace", "Another workspace", "Closed test", "Archived record"].enumerated() {
            var s = AgentSession(id: "sample-organized-\(index)", project: name)
            s.lastSeen = now; s.execution = .unknown
            let process: Int32 = index == 2 ? 600 : 500
            let guid = index == 2 ? "22345678-1234-1234-1234-123456789ABC" : "12345678-1234-1234-1234-123456789ABC"
            let binding = ProtocolOriginBinding(id: "sample-organized-binding-\(index)", origin: .init(terminal: .init(sessionID: guid),
                process: .init(pid: process, uid: 501, startMicroseconds: 10, processGroup: UInt32(process),
                    terminalGroup: UInt32(process), terminalDevice: 20, hasControllingTerminal: true, isCodex: true, capturedAt: now)))
            s.protocolBindings = [binding.id: .init(binding: binding, connected: index < 3, updatedAt: now)]
            if index == 0 { s.protocolGapAt = now }
            if [1, 4].contains(index) { s.requests["sample-question"] = .init(id: "sample-question", kind: .question, evidence: .unknown, updatedAt: now) }
            if index == 2 { s.execution = .running; s.requests["sample-live"] = .init(id: "sample-live", kind: .question, evidence: .observed, updatedAt: now) }
            if index == 3 { s.completionAt = now }
            if index == 4 { s.archivedAt = now }
            state.sessions[s.id] = s
        }
        return state
    }
    static func interactionCoverageState() -> RouterState {
        var state = workerBuildState(); let now = Date()
        for id in state.sessions.keys {
            guard var session = state.sessions[id] else { continue }
            if id.hasSuffix("0") {
                session.project = "Synchronous input"
                for index in 0..<2 { session.requests["sample-input-\(index)"] = .init(id: "sample-input-\(index)", kind: .question, evidence: .observed, updatedAt: now) }
            } else if id.hasSuffix("1") {
                session.project = "MCP interaction"
                session.requests["sample-form"] = .init(id: "sample-form", kind: .question, evidence: .observed, updatedAt: now)
            } else {
                session.project = "Coverage notice"
                session.protocolCoverageNotice = .init(id: "coverage-" + String(repeating: "a", count: 64), issue: .unsupportedRequest, observedAt: now)
            }
            state.sessions[id] = session
        }
        return state
    }
    static let helperBuildUUID = "00000000-0000-0000-0000-000000000001"
    static func workerBuildState() -> RouterState {
        var state = RouterState(); let now = Date()
        let entries: [(String, String?)] = [("Current bridge", helperBuildUUID), ("Reconnect when ready", "00000000-0000-0000-0000-000000000002"), ("Legacy bridge", nil)]
        for (index, entry) in entries.enumerated() {
            let process = ProcessOriginHint(pid: 500, uid: 501, startMicroseconds: 10, processGroup: 500,
                terminalGroup: 500, terminalDevice: 20, hasControllingTerminal: true, isCodex: true, capturedAt: now)
            let binding = ProtocolOriginBinding(id: "sample-bridge-\(index)", origin: .init(
                terminal: .init(sessionID: "12345678-1234-1234-1234-123456789ABC"), process: process))
            var session = AgentSession(id: "sample-session-\(index)", project: entry.0)
            session.lastSeen = now; session.execution = .running
            session.protocolBindings = [binding.id: .init(binding: binding, connected: true, updatedAt: now, workerBuildUUID: entry.1)]
            state.sessions[session.id] = session
        }
        return state
    }
    static func state() -> RouterState {
        var state = RouterState()
        let now = Date()
        let entries: [(String, String, Execution)] = [("atlas", "atlas-web", .running), ("router", "attention-router", .idle), ("design", "design-system", .running), ("docs", "developer-docs", .running), ("api", "payments-api", .running)]
        for (index, entry) in entries.enumerated() {
            var session = AgentSession(id: entry.0, project: entry.1)
            session.execution = entry.2; session.lastSeen = now.addingTimeInterval(Double(-index * 45))
            let pid = Int32(520 + index)
            let binding = ProtocolOriginBinding(id: "sample-" + entry.0, origin: .init(
                terminal: .init(sessionID: "\(index + 1)2345678-1234-1234-1234-123456789ABC"),
                process: .init(pid: pid, uid: 501, startMicroseconds: 10, processGroup: UInt32(pid), terminalGroup: UInt32(pid),
                    terminalDevice: UInt32(30 + index), hasControllingTerminal: true, isCodex: true, capturedAt: now)))
            session.protocolBindings = [binding.id: .init(binding: binding, connected: true, updatedAt: now)]
            if index == 0 {
                for q in 0..<2 { session.requests["q\(q)"] = AttentionRequest(id: "q\(q)", kind: .question, evidence: .observed, updatedAt: now.addingTimeInterval(-42), turnID: "t") }
            } else if index == 1 { session.completionAt = now.addingTimeInterval(-92) }
            else if index == 2 { session.requests["r"] = AttentionRequest(id: "r", kind: .approval, evidence: .observed, updatedAt: now.addingTimeInterval(-128), turnID: "t") }
            state.sessions[session.id] = session
        }
        return state
    }
}

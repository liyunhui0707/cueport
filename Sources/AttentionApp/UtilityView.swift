import SwiftUI
import AppKit
import AttentionCore

struct UtilityView: View {
    @ObservedObject var model: RouterModel
    let settings: Bool
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                CueportMark(size: 42)
                VStack(alignment: .leading, spacing: 5) {
                    Text(settings ? "Make room for focus." : "A clear view of your connection.").font(.system(size: 23, weight: .semibold, design: .rounded)).tracking(-0.5)
                    Text(settings ? "A few thoughtful defaults. Always on your Mac." : "Local checks. No prompts, commands or credentials.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if settings { settingsContent } else { diagnosticsContent }
            if let message = model.message {
                Label(message, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 5) { Image(systemName: "lock.shield"); Text("Local-first · No telemetry · No automatic approvals") }.font(.system(size: 10)).foregroundStyle(.tertiary)
        }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 540, height: min(700, max(360, (NSScreen.main?.visibleFrame.height ?? 900) - 90)))
        .background(Design.background)
    }
    var settingsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("NOTIFICATIONS") {
                VStack(spacing: 16) {
                    settingRow("System notifications", subtitle: model.notificationStatus) {
                        if model.notificationsEnabled { Toggle("Enabled", isOn: $model.notificationsEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel("System notifications") }
                        else { Button("Enable…") { model.requestNotifications() }.controlSize(.small) }
                    }
                    Divider()
                    settingRow("A gentle sound", subtitle: "Use the system notification sound") { Toggle("Sound", isOn: $model.soundEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small) }
                    Divider()
                    settingRow("Private notification titles", subtitle: "Hide project names from banners") { Toggle("Hide project names", isOn: $model.hideProjects).labelsHidden().toggleStyle(.switch).controlSize(.small) }
                    Divider()
                    settingRow("Test system delivery", subtitle: "A test banner in 3 seconds · No agent task") {
                        Button("Send test notification") { model.sendDeliveryTest() }
                            .controlSize(.small).disabled(model.demo || !model.notificationsEnabled || model.paused)
                    }
                    if model.hasRoutingPOC {
                        Divider()
                        settingRow("Verified comparison pane", subtitle: "Local POC · Click the test banner to return") {
                            Button("Send routing test") { model.sendRoutingTest() }
                                .controlSize(.small).disabled(!model.notificationsEnabled || model.paused)
                        }
                    }
                    Text("Early approval activity stays in the list. Only verified sessions send automatic banners.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            group("YOUR CONNECTION") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "terminal").foregroundStyle(Design.amber).font(.system(size: 20))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Codex + iTerm2").font(.system(size: 13, weight: .semibold))
                            Text(model.demo ? "Preview mode · Sample threads" : model.state.sessions.isEmpty ? "Waiting for your first session" : "\(model.overview.registeredSourceCount) recorded sources · \(model.overview.registeredThreads.count) observed threads")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(model.demo ? "PREVIEW" : model.sessions.isEmpty ? "SETUP" : "OBSERVED").font(.system(size: 9, weight: .semibold)).foregroundStyle(Design.amber).padding(6).background(Design.amber.opacity(0.08), in: Capsule())
                    }
                    Divider()
                    Text(model.startupBlocked ? "Startup is paused. Choose a verified bridge folder below, or forget the saved startup, then quit and reopen this app." : model.bridgePOC ? "Run the copied command from your project directory to start a connected Codex session. The bridge keeps the native TUI and stores metadata only. Existing Codex windows are not attached; direct codex launches remain unverified." : "Install the helper’s Hooks, then review them with /hooks in a new Codex session. Existing Hooks are preserved.").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(model.bridgePOC ? "Copy launch command" : "Copy setup command") {
                            copyCommand(resume: false)
                        }.controlSize(.small).disabled(model.startupBlocked || model.demo || (model.bridgePOC && !model.canCopyNativeCommands))
                        if model.bridgePOC {
                            Button("Copy resume command") { copyCommand(resume: true) }
                                .controlSize(.small).disabled(model.startupBlocked || model.demo || !model.canCopyNativeCommands)
                                .help("Choose an existing conversation in the native Codex picker.")
                        }
                        Spacer()
                        Text(model.bridgePOC ? "Connected bridge" : model.hasRoutingPOC ? "Standalone routing POC" : "Monitoring via Hooks").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    if model.bridgePOC {
                        Text("Continue an existing conversation with Copy resume command. Run it from your project directory to open the native picker directly. It does not clean up existing thread records.")
                            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    startupContent
                    Divider()
                    nativeCodexContent
                }
            }
        }
    }
    private func copyCommand(resume: Bool) {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cueport").path
        let command: String
        if model.bridgePOC {
            guard let launch = try? BridgeLaunchOptions(codexArguments: resume ? ["resume"] : []) else { return }
            guard model.canCopyNativeCommands else { return }
            command = launch.shellCommand(executable: executable, dataDirectory: model.root.path, nativeExecutable: model.chosenNativeCodex)
        } else {
            command = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "' install-hooks"
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
        model.message = model.bridgePOC
            ? (resume ? "Resume command copied. Run it from your project directory in an iTerm2 Shell, then choose an existing conversation."
                      : "Launch command copied. Run it from your project directory in an iTerm2 Shell.")
            : "Setup command copied. Run it in iTerm2 to review the merge plan before applying."
    }
    var startupContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("OPENING THE APP").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text("Application · " + (Bundle.main.object(forInfoDictionaryKey: "AARReleaseVersion") as? String ?? "Unversioned development build")
                 + " · Build " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unversioned"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Toggle("Show application in Dock", isOn: $model.showInDock)
                .toggleStyle(.switch).font(.system(size: 12))
                .help("Keep an independent application icon in the Dock. Click it to open Cueport; the menu bar entry stays available.")
            Text("Application · " + (model.demo ? "/Applications/Cueport.app" : Bundle.main.bundleURL.path))
                .font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("Current mode · " + model.currentModeDescription).font(.system(size: 12, weight: .medium))
            if !model.startupBlocked {
                Text("Current folder · " + (model.demo ? "/synthetic/attention-router" : model.root.path)).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Text("Next normal launch · " + model.nextLaunchDescription).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Text("Save once, then reopen this app from Finder or the Dock. A saved choice takes effect on the next launch; it does not move current sessions.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.bridgePOC {
                Button("Remember this bridge") { model.rememberBridgeStartup() }
                    .controlSize(.small).disabled(!model.canRememberStartup)
            }
            if !model.bridgePOC && !model.hasSavedStartup {
                Button("Set up connected bridge…") { model.prepareDefaultBridgeStartup() }
                    .controlSize(.small).disabled(model.demo)
                    .help("Create a private local bridge folder and remember it for the next launch. Quit and reopen this app to use it. Existing Codex windows and Hooks are unchanged.")
            }
            HStack {
                Button("Choose bridge folder…") { model.chooseBridgeStartup() }.controlSize(.small).disabled(model.demo)
                if model.hasSavedStartup {
                    Button("Forget saved startup") { model.forgetBridgeStartup() }.controlSize(.small).disabled(model.demo)
                }
            }
        }
    }
    var nativeCodexContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("NATIVE CODEX FILE").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(model.demo ? "Sample native Codex · No checks performed" : model.nativeCodexStatus)
                .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Text(model.demo ? "/synthetic/native/codex" : model.nativeCodexPath ?? "Saved choice unavailable")
                .font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let native = model.nativeCodexPath, !model.demo {
                Text(CodexInstallation(nativeExecutable: native).updateSummary)
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Choose native file…") { model.chooseNativeCodex() }.controlSize(.small)
                Button("Use default") { model.useDefaultNativeCodex() }.controlSize(.small)
                    .disabled(model.chosenNativeCodex == nil && !model.nativeChoiceUnavailable)
                Button("Check file/version") { model.checkNativeCodex() }.controlSize(.small)
                    .disabled(model.nativeChoiceUnavailable)
                if model.checkingNativeCodex { ProgressView().controlSize(.small) }
            }.disabled(model.demo || model.checkingNativeCodex)
            Text("Supported native arm64 Codex: \(BridgeCompatibility.supportedDescription). This changes future copied launch/resume commands; open sessions keep running. It does not install dependencies, edit Codex settings or start its backend.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(model.demo ? "Sample preference scope" : model.nativeChoiceScopeDescription)
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    var diagnosticsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            retainedRecordsContent
            group("THIS RECEIVER") {
                VStack(spacing: 14) {
                    diagnostic("Running build", value: model.buildDescription, icon: "app.badge.checkmark")
                    Divider()
                    diagnostic("Last agent reminder · This receiver", value: model.submissionDescription, icon: "paperplane")
                    Divider()
                    diagnostic("Pending reminders", value: model.queueDescription, icon: "clock.arrow.circlepath")
                    Divider()
                    diagnostic("Verified return timing", value: model.returnTimingDescription, icon: "stopwatch")
                    Divider()
                    diagnostic("Reminder submission timing", value: model.submissionTimingDescription, icon: "timer")
                    Divider()
                    diagnostic("Snapshot and saving", value: model.storageDescription, icon: "externaldrive")
                }
            }
            group("LOCAL HEALTH") {
                VStack(spacing: 14) {
                    diagnostic("Native notifications", value: model.notificationStatus, icon: "bell")
                    Divider()
                    diagnostic("iTerm2 command interface", value: FileManager.default.isExecutableFile(atPath: ITermAdapter.binary) ? "Installed · API permission checked on use" : "Not found", icon: "terminal")
                    Divider()
                    diagnostic("Event monitoring", value: model.monitoringDescription, icon: "waveform.path.ecg")
                    Divider()
                    diagnostic("Question lifecycle", value: model.bridgePOC ? "Async editor IDs tracked · RPC prompt clearing tracked · Ordinary chat may remain unconfirmed" : "Creation observed · Resolution may be unconfirmed", icon: "questionmark.bubble")
                    Divider()
                    diagnostic("Exact terminal return", value: model.demo ? "Preview only · No terminal actions" : model.bridgePOC ? "Registered connections · Shared or closed sources refused" : model.hasRoutingPOC ? "Local POC · One independently verified pane" : "Paused · Origin is not yet verified", icon: "arrow.up.forward.app")
                }
            }
            if model.hasBridgeBuildDiagnostics {
                workerBuildContent
            }
            DisclosureGroup("What the status labels mean") {
                VStack(alignment: .leading, spacing: 10) {
                    statusMeaning("Turn active", "A Codex turn is active and may also be waiting for input. It does not prove continuous execution.")
                    statusMeaning("Question queued", "A question was observed. Handle it in the original Codex terminal; the agent may keep working.")
                    statusMeaning("Answer submitted · Unconfirmed", "An editor submission was observed. This alone does not prove the answer was accepted or the request finished.")
                    statusMeaning("Status unconfirmed / Coverage notice", "Monitoring cannot prove this state. Check the original session; a notice is not another question.")
                    statusMeaning("Turn stopped", "A stopped turn was observed. It does not mean Codex exited or the entire project is finished.")
                    statusMeaning("Reviewed", "You returned to the verified terminal. Review does not answer, approve or resolve a request.")
                    statusMeaning("To review", "Visible thread records needing attention, not a count of confirmed human blockers.")
                }.padding(.top, 10)
            }.font(.system(size: 12)).padding(16).background(Design.card, in: RoundedRectangle(cornerRadius: 13))
            group("IF A TERMINAL DOESN’T OPEN") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Keep the original iTerm2 pane open. Enable the Python API in iTerm2 Settings → General → Magic and review its connection request.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                    Text("If connected Codex reports a backend or handshake error after its file/version check passes, review the normal Codex setup and login. The file check does not start or repair its backend.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("If a reminder reaches Notification Center without a banner, check macOS Focus and screen-sharing notification settings. System acceptance alone does not prove visible delivery.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("A missing or ambiguous session is never replaced by another terminal.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Refresh diagnostics") { model.refreshDiagnostics(); model.refreshAuthorization() }.controlSize(.small).padding(.top, 2)
                }
            }
        }
    }
    private func statusMeaning(_ title: String, _ explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .medium))
            Text(explanation).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
    var retainedRecordsContent: some View {
        group("RETAINED THREAD RECORDS") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Closed sources and archived records are retained here. Restoring a record does not reopen its terminal. Archiving never answers or resolves a request.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !model.threadVisibility.unavailableProcessIDs.isEmpty {
                    Text("Some registered terminal processes could not be checked. Their records stay visible until the check succeeds.")
                        .font(.system(size: 10)).foregroundStyle(Design.amber).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.state.sortedSessions) { session in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            SessionCard(session: session, busy: model.focusInProgress == session.id) { Task { await model.focus(session.id) } }
                            Button(session.archivedAt == nil ? "Archive from main list · Keep requests" : "Restore record") {
                                model.setArchived(session.id, archived: session.archivedAt == nil)
                            }.controlSize(.small).disabled(session.archivedAt == nil && !session.canArchive)
                        }.padding(.top, 8)
                    } label: {
                        Text(session.project + " · " + session.displayReference + (session.archivedAt == nil ? "" : " · Archived"))
                            .font(.system(size: 11)).lineLimit(2)
                    }
                }
            }
        }
    }
    var workerBuildContent: some View {
        group("BRIDGE BUILDS BY SESSION") {
            VStack(alignment: .leading, spacing: 14) {
                Text("The receiver and each Codex bridge are separate processes. A build match does not prove live focus or complete event coverage. Reconnecting is always your choice.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.sessions.isEmpty {
                    Text("No registered sessions yet.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(model.sessions) { session in
                    if let health = model.workerBuildStatus(for: session) {
                        Divider()
                        diagnostic(session.project + " · " + session.displayReference, value: health.detail,
                                   icon: health.status == .current ? "checkmark.seal" : "info.circle")
                        if let notice = session.protocolCoverageNotice {
                            diagnostic("Interaction coverage · " + notice.observedAt.formatted(date: .omitted, time: .shortened),
                                       value: notice.detail, icon: "exclamationmark.triangle")
                        }
                    }
                }
            }
        }
    }
    func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary).padding(.leading, 2)
            content().padding(16).background(Design.card, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Design.line, lineWidth: 1))
        }
    }
    func settingRow<Control: View>(_ title: String, subtitle: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 12, weight: .medium)); Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(); control().accessibilityLabel(title)
        }
    }
    func diagnostic(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Design.amber).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 12, weight: .medium)); Text(value).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
        }
    }
}

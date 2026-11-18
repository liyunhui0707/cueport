import SwiftUI
import AppKit
import AttentionCore

struct DashboardView: View {
    @ObservedObject var model: RouterModel
    var openSettings: () -> Void = {}
    var openDiagnostics: () -> Void = {}
    var expandRecords = false
    @State private var expandedSources: Set<String> = []
    var overview: SessionOverview { model.overview }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    RouterMark()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Attention Router").font(.system(size: 14, weight: .semibold))
                        Text("Never miss an agent that needs you.").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    IconButton(icon: model.paused ? "bell.slash" : "bell", label: model.paused ? "Resume notifications" : "Pause notifications") { model.paused.toggle() }
                }
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.attentionCount > 0 ? "A little attention.\nA lot of progress." : "Room to focus.")
                            .font(.system(size: 25, weight: .semibold, design: .rounded)).tracking(-0.6).lineSpacing(0)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(model.attentionCount > 0 ? "Your next move, all in one place." : "We’ll keep an eye on your agents.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ZStack {
                        Circle().stroke(Design.amber.opacity(0.12), lineWidth: 5)
                        Circle().trim(from: 0, to: overview.unarchivedCount == 0 ? 0 : CGFloat(model.attentionCount) / CGFloat(overview.unarchivedCount)).stroke(Design.amber, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                        Text(String(format: "%02d", model.attentionCount)).font(.system(size: 24, weight: .medium, design: .rounded)).foregroundStyle(Design.amber)
                    }.frame(width: 58, height: 58).accessibilityLabel("\(model.attentionCount) sessions need attention")
                }
                HStack(spacing: 0) {
                    metric(value: model.attentionCount, title: "To review", color: Design.amber)
                    Rectangle().fill(Design.line).frame(width: 1, height: 27)
                    metric(value: model.workingCount, title: "Turn active", color: Design.green)
                    Rectangle().fill(Design.line).frame(width: 1, height: 27)
                    metric(value: overview.registeredSourceCount, title: "Sources", color: .primary)
                }.padding(.vertical, 12).background(Design.card.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                Text("\(overview.registeredThreads.count) registered threads · Sources are recorded, not a live window count")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(20)
            Rectangle().fill(Design.line).frame(height: 1)
            if model.demo {
                HStack(spacing: 6) { Image(systemName: "sparkle"); Text("DESIGN PREVIEW").tracking(1); Spacer(); Text("Sample sessions") }
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 8)
            }
            if let notice = model.routingNotice { banner(notice, icon: "link", color: Design.amber) }
            if let notice = model.connectionRecoveryNotice { banner(notice, icon: "arrow.clockwise", color: Design.amber) }
            if model.paused { banner("Notifications paused. Your attention list stays up to date.", icon: "bell.slash", color: Design.blue) }
            if let message = model.message {
                VStack(alignment: .leading, spacing: 7) {
                    banner(message, icon: "exclamationmark.circle", color: Design.amber)
                    Button("Dismiss") { model.message = nil }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary).padding(.leading, 22).padding(.bottom, 8)
                }
            }
            if overview.groups.isEmpty { emptyState }
            else {
                ScrollView {
                    VStack(spacing: 18) {
                        if model.mainWorkerBuildNeedsCheck {
                            Button(action: openDiagnostics) {
                                Label("Bridge builds need a check · Diagnostics", systemImage: "info.circle")
                                    .font(.system(size: 10)).foregroundStyle(Design.amber)
                            }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !overview.groups.isEmpty {
                            VStack(spacing: 8) {
                                SectionCaption(title: "REGISTERED SOURCES", count: overview.registeredSourceCount)
                                ForEach(overview.groups) { source in sourceGroup(source) }
                            }
                        }
                    }.padding(.horizontal, 16).padding(.vertical, 14)
                }.frame(maxHeight: 390)
            }
            Rectangle().fill(Design.line).frame(height: 1)
            HStack(spacing: 6) {
                Circle().fill(model.demo ? Design.blue : model.storage == nil || model.connectionRecoveryNotice != nil || !model.threadVisibility.unavailableProcessIDs.isEmpty ? Design.amber : Design.green).frame(width: 5, height: 5)
                Text(model.demo ? "Local-first. Always." : model.storage == nil ? "Connection needs setup" : model.connectionRecoveryNotice != nil ? "Connection interrupted" : !model.threadVisibility.unavailableProcessIDs.isEmpty ? "Terminal checks incomplete" : "Listening locally").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                IconButton(icon: "waveform.path.ecg", label: "Diagnostics", action: openDiagnostics)
                IconButton(icon: "gearshape", label: "Settings", action: openSettings)
                Menu { Button("Quit Attention Router") { NSApp.terminate(nil) } } label: { Image(systemName: "ellipsis").frame(width: 20) }.menuStyle(.borderlessButton).frame(width: 24).help("More")
            }.padding(.horizontal, 18).padding(.vertical, 9)
        }.frame(width: 400).background(Design.background)
    }
    func metric(value: Int, title: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String(format: "%02d", value)).font(.system(size: 19, weight: .semibold, design: .rounded)).foregroundStyle(color)
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 14)
    }
    @ViewBuilder func sourceGroup(_ source: SessionSourceGroup) -> some View {
        if source.sessions.count == 1 {
            threadRow(source.sessions[0])
        } else {
            DisclosureGroup(isExpanded: Binding(get: { expandRecords || expandedSources.contains(source.id) }, set: { value in
                if value { expandedSources.insert(source.id) } else { expandedSources.remove(source.id) }
            })) {
                VStack(spacing: 8) { ForEach(source.sessions) { session in threadRow(session) } }.padding(.top, 10)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
                    Text("\(source.sessions.count) threads · \(source.attentionCount) to review")
                        .font(.system(size: 11)).foregroundStyle(source.attentionCount > 0 ? Design.amber : Color.secondary)
                }
            }.padding(12).background(Design.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Design.line, lineWidth: 1))
        }
    }
    func threadRow(_ session: AgentSession) -> some View {
        SessionCard(session: session, busy: model.focusInProgress == session.id) { Task { await model.focus(session.id) } }
    }
    func banner(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) { Image(systemName: icon).foregroundStyle(color); Text(text).fixedSize(horizontal: false, vertical: true); Spacer(minLength: 0) }
            .font(.system(size: 11)).padding(.horizontal, 20).padding(.vertical, 10).background(color.opacity(0.07))
    }
    var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal").font(.system(size: 29, weight: .light)).foregroundStyle(Design.amber).frame(width: 64, height: 64).background(Design.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
            Text("Your agents belong here.").font(.system(size: 16, weight: .semibold, design: .rounded))
            Text("Connect Codex once. Then work across\nyour terminals with a little less checking.").font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(3)
            Button("Connect Codex", action: openSettings).buttonStyle(.borderedProminent).tint(Design.amber).controlSize(.regular).padding(.top, 4)
            Text("Private by default · No terminal recording").font(.system(size: 10)).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity).padding(.vertical, 36)
    }
}

struct SessionCard: View {
    let session: AgentSession
    let busy: Bool
    var workerBuild: BridgeWorkerBuildStatus? = nil
    var action: () -> Void
    @State private var hovering = false
    @FocusState private var keyboardFocused: Bool
    var questions: [AttentionRequest] { session.outstanding.filter { $0.kind == .question } }
    var approvals: [AttentionRequest] { session.outstanding.filter { $0.kind == .approval } }
    var uncertain: Bool { session.outstanding.contains { $0.evidence == .unknown } }
    var unconfirmed: Bool { session.outstanding.contains { $0.evidence != .confirmed } }
    var color: Color { !session.queuedQuestions.isEmpty || session.protocolGapAt != nil || session.protocolCoverageNotice?.reviewed == false ? Design.amber : !approvals.isEmpty ? Design.purple : session.completionAt != nil && !session.completionReviewed ? Design.green : Design.blue }
    var icon: String { !questions.isEmpty ? "questionmark.bubble" : !approvals.isEmpty ? "hand.raised" : session.protocolGapAt != nil || session.protocolCoverageNotice?.reviewed == false ? "exclamationmark.triangle" : session.completionAt != nil && !session.completionReviewed ? "checkmark" : session.execution == .interrupted ? "exclamationmark" : "terminal" }
    var title: String {
        if !session.queuedQuestions.isEmpty { return "\(session.queuedQuestions.count) question\(session.queuedQuestions.count == 1 ? "" : "s") queued" }
        if !session.submittedQuestions.isEmpty { return "\(session.submittedQuestions.count) answer\(session.submittedQuestions.count == 1 ? "" : "s") submitted · Unconfirmed" }
        if !session.uncertainQuestions.isEmpty { return "\(session.uncertainQuestions.count) question\(session.uncertainQuestions.count == 1 ? "" : "s") · Status unconfirmed" }
        if !approvals.isEmpty { return approvals.contains { $0.evidence == .confirmed } ? "Waiting for your approval" : uncertain ? "Approval state unconfirmed" : "Approval request observed" }
        if session.protocolGapAt != nil { return "Check the original session" }
        if session.protocolCoverageNotice?.reviewed == false { return "Interaction coverage needs a check" }
        if session.completionAt != nil && !session.completionReviewed { return "Turn stopped · Unreviewed" }
        switch session.execution {
        case .running: return "Working independently"
        case .idle: return "Ready for the next step"
        case .interrupted: return "Turn interrupted"
        case .ended: return "Session ended"
        case .unknown: return "Status needs a refresh"
        }
    }
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(color).frame(width: 31, height: 31).background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(session.project).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        if session.execution == .running && session.needsAttention {
                            HStack(spacing: 3) { Circle().fill(Design.green).frame(width: 4, height: 4); Text("Turn active") }.font(.system(size: 9, weight: .medium)).foregroundStyle(Design.green)
                        }
                    }
                    Text(title).font(.system(size: 11)).foregroundStyle(color).lineLimit(2).multilineTextAlignment(.leading)
                    if session.protocolGapAt != nil {
                        Text("Monitoring missed an event. Pending requests may need a check.")
                            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let notice = session.protocolCoverageNotice {
                        Text(notice.issue.explanation).font(.system(size: 10)).foregroundStyle(Design.amber)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(notice.reviewed ? "Coverage notice reviewed · Coverage unconfirmed" : "Coverage notice · Check Codex")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if !session.queuedQuestions.isEmpty && !session.submittedQuestions.isEmpty {
                        Text("\(session.submittedQuestions.count) answer\(session.submittedQuestions.count == 1 ? "" : "s") submitted · Not yet confirmed").font(.system(size: 10)).foregroundStyle(Design.blue)
                    }
                    if (!session.queuedQuestions.isEmpty || !session.submittedQuestions.isEmpty) && !session.uncertainQuestions.isEmpty {
                        Text("\(session.uncertainQuestions.count) other question\(session.uncertainQuestions.count == 1 ? "" : "s") · Status unconfirmed").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if !questions.isEmpty && !approvals.isEmpty { Text("\(approvals.count) approval request\(approvals.count == 1 ? "" : "s") also recorded").font(.system(size: 10)).foregroundStyle(Design.purple) }
                    HStack(spacing: 5) {
                        Text("Codex"); Text("·"); Text(session.displayReference)
                        if unconfirmed { Text("·"); Text("Resolution unconfirmed") }
                    }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    if let workerBuild {
                        Label(workerBuild.summary, systemImage: workerBuild.status == .current ? "checkmark.seal" : "info.circle")
                            .font(.system(size: 10)).foregroundStyle(workerBuild.status == .current ? Design.green : workerBuild.status == .disconnected || workerBuild.status == .notRegistered ? Color.secondary : Design.amber)
                            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    }
                }
                if busy { ProgressView().controlSize(.small).frame(width: 12, height: 20) }
                else { Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(hovering ? color : Color.secondary.opacity(0.45)).padding(.top, 3) }
            }.padding(12).contentShape(RoundedRectangle(cornerRadius: 12))
                .background(hovering || keyboardFocused ? color.opacity(0.055) : Design.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(keyboardFocused ? Design.blue : hovering ? color.opacity(0.32) : Design.line, lineWidth: keyboardFocused ? 2 : 1))
        }.buttonStyle(.plain).disabled(busy).onHover { hovering = $0 }
            .focused($keyboardFocused)
            .help(session.project + "\n" + (workerBuild?.detail ?? "Open the exact original terminal session"))
            .accessibilityLabel("\(session.project), Codex, \(title), \(session.execution.rawValue), \(approvals.count) approval requests, \(session.submittedQuestions.count) answers submitted but unconfirmed, \(session.uncertainQuestions.count) other question states unconfirmed. \(session.completionAt != nil && !session.completionReviewed ? "Unreviewed stopped turn." : "") \(workerBuild?.summary ?? "")")
            .accessibilityValue(busy ? "Opening original terminal" : "")
            .accessibilityHint("Opens the original iTerm2 pane. Does not answer or approve requests. \(session.protocolCoverageNotice?.detail ?? "")")
    }
}

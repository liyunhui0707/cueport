import AppKit
import SwiftUI
import UserNotifications
import AttentionCore

@main
struct AppMain {
    @MainActor static func main() {
        let app = autoreleasepool { NSApplication.shared }
        app.setActivationPolicy(.accessory)
        autoreleasepool {
            let menu = NSMenu(), applicationItem = NSMenuItem(), applicationMenu = NSMenu()
            let quit = NSMenuItem(title: "Quit Attention Router", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            quit.target = app; quit.keyEquivalentModifierMask = .command
            applicationMenu.addItem(quit); applicationItem.submenu = applicationMenu
            menu.addItem(applicationItem); app.mainMenu = menu
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-previews"), CommandLine.arguments.count > index + 1 {
            PreviewRenderer.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])); return
        }
        let review = Bundle.main.object(forInfoDictionaryKey: "AARBuildChannel") as? String == "review"
        if review && !ReceiverLaunchPolicy.reviewRunIsIsolated(CommandLine.arguments) {
            let alert = NSAlert()
            alert.messageText = "This is an Attention Router test build"
            alert.informativeText = "Use the daily application for your projects. A test build requires an explicit, separate --data-dir and does not inherit your daily bridge. No receiver was started."
            alert.addButton(withTitle: "Quit test build")
            alert.runModal()
            return
        }
        if !review, !ReceiverLaunchPolicy.isExplicitRun(CommandLine.arguments),
           let identifier = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { !$0.isTerminated && ReceiverLaunchPolicy.isEarlierInstance(
                pid: $0.processIdentifier, started: $0.launchDate,
                currentPID: NSRunningApplication.current.processIdentifier,
                currentStarted: NSRunningApplication.current.launchDate) }) {
            existing.activate(options: [.activateAllWindows])
            return
        }
        // Release temporary Foundation objects made before NSApplication's
        // event-loop autorelease pools begin; the delegate itself stays owned.
        let delegate = autoreleasepool { AppDelegate() }
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    // Background monitoring does not need a view hierarchy. Create the panel
    // on the first UI interaction rather than during every receiver startup.
    lazy var popover: NSPopover = {
        let value = NSPopover()
        value.behavior = .transient
        return value
    }()
    var windows: [NSWindow] = []
    let model = RouterModel()
    private let review = Bundle.main.object(forInfoDictionaryKey: "AARBuildChannel") as? String == "review"
    private let validationLabel = Bundle.main.object(forInfoDictionaryKey: "AARValidationBuild") as? Bool == true
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // The packaged template preserves the system glyph without resolving
        // its symbol/font machinery on every background receiver launch.
        let indicator = NSImage(named: "AARStatusIndicator") ?? NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil)
        indicator?.isTemplate = true
        indicator?.accessibilityDescription = "Agent Attention Router"
        statusItem.button?.image = indicator
        statusItem.button?.target = self; statusItem.button?.action = #selector(toggle)
        statusItem.button?.toolTip = review || validationLabel ? "Attention Router — Test build (isolated data)" : "Attention Router — Daily application"
        model.onCountChanged = { [weak self] count in
            guard let self else { return }
            let title = (self.review || self.validationLabel ? " TEST" : "") + (count == 0 ? "" : " \(count)")
            if self.statusItem.button?.title != title { self.statusItem.button?.title = title }
        }
        model.onNotify = { [weak self] event, session in
            if event.kind == .approvalRequested && event.protocolBinding != nil {
                // Coalesce quick automatic resolution; elapsed time never upgrades
                // this request to confirmed human waiting. Recheck actual state.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                    guard let self, let current = self.model.state.sessions[event.sessionID] else { return }
                    self.notify(event, current)
                }
            } else { self?.notify(event, session) }
        }
        model.onRoutingTest = { [weak self] in self?.routingTest() }
        model.onDeliveryTest = { [weak self] in self?.deliveryTest() }
        model.onDockVisibilityChanged = { visible in
            NSApp.setActivationPolicy(visible ? .regular : .accessory)
        }
        if model.showInDock { NSApp.setActivationPolicy(.regular) }
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
        if !model.demo, CommandLine.arguments.contains("--clear-notifications") {
            // Only this app's old banners/requests; durable attention is untouched.
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        }
        model.start()
        if CommandLine.arguments.contains("--settings") { openWindow(settings: true) }
        else if CommandLine.arguments.contains("--show") {
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.toggle() }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && !popover.isShown { toggle() }
        return true
    }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let show = NSMenuItem(title: "Open Attention Router", action: #selector(showFromDock), keyEquivalent: "")
        show.target = self; menu.addItem(show)
        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsFromDock), keyEquivalent: "")
        settings.target = self; menu.addItem(settings)
        return menu
    }
    @objc private func showFromDock() {
        if !popover.isShown { toggle() }
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func settingsFromDock() { openWindow(settings: true) }
    @objc func toggle() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            model.refreshOpenThreads(force: true)
            model.refreshDiagnostics()
            NSApp.activate(ignoringOtherApps: true)
            let available = (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
            let height = min(760, max(420, available - 48))
            popover.contentViewController = NSHostingController(rootView:
                DashboardView(model: model, openSettings: { self.openWindow(settings: true) }, openDiagnostics: { self.openWindow(settings: false) })
                    .frame(height: height))
            popover.contentSize = NSSize(width: 400, height: height)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if model.demo, CommandLine.arguments.contains("--record-popover-layout") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.model.message = "This notification has no verified original process. Your attention list is preserved."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.recordPopoverLayout() }
                }
            }
        }
    }
    func recordPopoverLayout() {
        guard model.demo, let view = popover.contentViewController?.view else { return }
        var viewports: [Double] = []
        func visit(_ current: NSView) {
            if let scroll = current as? NSScrollView { viewports.append(scroll.contentView.bounds.height) }
            current.subviews.forEach(visit)
        }
        visit(view)
        do {
            try LocalStore.ensurePrivateDirectory(model.root)
            let result: [String: Any] = ["receiver_pid": getpid(), "native_popover_shown": popover.isShown,
                "application_active": NSApp.isActive,
                "sample_sessions": model.sessions.count, "feedback_inserted_after_open": model.message != nil,
                "content_height": popover.contentSize.height, "hosting_height": view.bounds.height,
                "registered_sources": model.overview.registeredSourceCount, "scroll_viewport_heights": viewports]
            let file = model.root.appendingPathComponent("popover-layout.json")
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    let image = model.root.appendingPathComponent("popover-sample.png")
                    try png.write(to: image, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: image.path)
                }
            }
        } catch { /* Isolated visual-test evidence does not affect the product. */ }
    }
    func openWindow(settings: Bool) {
        popover.performClose(nil)
        let title = (settings ? "Settings — Attention Router" : "Diagnostics — Attention Router") + (review ? " — TEST" : "")
        if let existing = windows.first(where: { $0.title == title }) {
            existing.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = UtilityView(model: model, settings: settings)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false; window.center(); window.makeKeyAndOrderFront(nil)
        windows.append(window); NSApp.activate(ignoringOtherApps: true)
    }
    func notify(_ event: AgentEvent, _ session: AgentSession) {
        guard Bundle.main.bundleIdentifier != nil,
              let plan = model.prepareNotification(event, session: session) else { return }
        let content = UNMutableNotificationContent()
        content.title = model.hideProjects ? "Codex needs your attention" : "Codex · \(session.project)"
        content.subtitle = "Session · \(session.displayReference)"
        switch plan.kind {
        case .approvalRequested: content.body = "Approval request delivered to Codex. Human waiting is not yet confirmed."
        case .questionQueued: content.body = "\(plan.questionCount) new question\(plan.questionCount == 1 ? "" : "s"). The agent may still be working."
        case .humanApprovalPending: content.body = "Waiting for your approval."
        case .turnStopped: content.body = "Turn stopped. Open the original terminal to review."
        case .interrupted: content.body = "Turn interrupted. Check the original terminal."
        default: model.completeNotification(plan, accepted: false); return
        }
        content.userInfo = ["sessionID": session.id, "sourceInstance": plan.sourceInstance]
        content.threadIdentifier = session.id
        if model.soundEnabled { content.sound = .default }
        // Native notifications carry only an opaque session reference, never executable text.
        let request = UNNotificationRequest(identifier: plan.identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            Task { @MainActor in self?.model.completeNotification(plan, accepted: error == nil) }
        }
    }
    func recordDeliveryTest(_ stage: String) {
        guard !model.demo, let storage = model.storage else { return }
        do {
            try LocalStore.ensurePrivateDirectory(storage.root)
            let data = try JSONSerialization.data(withJSONObject: ["stage": stage,
                "recorded_at": Date().timeIntervalSince1970], options: [.sortedKeys])
            let file = storage.root.appendingPathComponent("notification-delivery-test.json")
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* Optional diagnostic receipt; attention is independent. */ }
    }
    func deliveryTest() {
        guard !model.demo, model.notificationsEnabled, !model.paused,
              !CommandLine.arguments.contains("--no-notifications") else { return }
        let content = UNMutableNotificationContent()
        content.title = "Attention Router · Notification test"
        content.body = "System delivery test. Click to confirm receipt."
        content.userInfo = ["deliveryTest": true]
        if model.soundEnabled { content.sound = .default }
        let request = UNNotificationRequest(identifier: "aar-delivery-test", content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false))
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            let accepted = error == nil
            Task { @MainActor in
                guard let self else { return }
                self.recordDeliveryTest(accepted ? "submission-accepted" : "submission-failed")
                self.model.message = accepted ? "Test scheduled in 3 seconds. Switch to another app to check its banner." : "macOS did not accept the test notification."
            }
        }
    }
    func routingTest() {
        guard model.hasRoutingPOC, let test = model.originPOC?.payload,
              !CommandLine.arguments.contains("--no-notifications") else { return }
        let content = UNMutableNotificationContent()
        content.title = "Attention Router · Local routing test"
        content.body = "Click to return to the verified Codex comparison pane."
        content.userInfo = ["sessionID": test.sessionID, "sourceInstance": test.origin.process.instanceID]
        if model.soundEnabled { content.sound = .default }
        let request = UNNotificationRequest(identifier: "aar-local-poc-" + UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            Task { @MainActor in
                self?.model.message = error == nil ? "Test submitted to macOS. Click its notification to check the original pane." : "macOS did not accept the test notification. Check notification permissions."
            }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let callbackStarted = DispatchTime.now().uptimeNanoseconds
        let id = response.notification.request.content.userInfo["sessionID"] as? String
        let instance = response.notification.request.content.userInfo["sourceInstance"] as? String
        let deliveryTest = response.notification.request.content.userInfo["deliveryTest"] as? Bool ?? false
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier, deliveryTest {
            Task { @MainActor in
                recordDeliveryTest("opened")
                model.message = "Test notification received. Your agent attention list is preserved."
                if !popover.isShown { toggle() }
            }
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier, let id {
            Task { @MainActor in
                await model.focusNotification(id, instance: instance, callbackStarted: callbackStarted)
                // A closed/ambiguous target needs visible feedback even when
                // no Settings window or menu panel was already open.
                if model.message != nil && !popover.isShown { toggle() }
            }
        }
        completionHandler()
    }
}

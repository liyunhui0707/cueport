import SwiftUI
import AppKit

@MainActor enum PreviewRenderer {
    static func render(to directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for dark in [false, true] {
                let style = dark ? "dark" : "light"
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let model = RouterModel(demo: true)
                let organized = RouterModel(demo: true)
                organized.state = DemoData.organizedState()
                let longNames = RouterModel(demo: true)
                longNames.state = DemoData.organizedState()
                for id in Array(longNames.state.sessions.keys) {
                    longNames.state.sessions[id]?.project = "很长的项目名称 — Native accessibility and scroll validation — " + String(repeating: "sample-workspace-", count: 7)
                }
                try save(DashboardView(model: longNames, expandRecords: true).environment(\.colorScheme, dark ? .dark : .light), to: directory.appendingPathComponent("long-names-\(style).png"))
                try save(DashboardView(model: organized).environment(\.colorScheme, dark ? .dark : .light), to: directory.appendingPathComponent("organized-\(style).png"))
                try save(DashboardView(model: organized, expandRecords: true)
                    .environment(\.colorScheme, dark ? .dark : .light), to: directory.appendingPathComponent("organized-expanded-\(style).png"))
                try save(DashboardView(model: model).environment(\.colorScheme, dark ? .dark : .light), to: directory.appendingPathComponent("overview-\(style).png"))
                try save(UtilityView(model: model, settings: true).environment(\.colorScheme, dark ? .dark : .light), to: directory.appendingPathComponent("settings-\(style).png"))
                try save(UtilityView(model: model, settings: true).startupContent.padding(28).frame(width: 540).background(Design.background)
                    .environment(\.colorScheme, dark ? .dark : .light), to: directory.appendingPathComponent("startup-\(style).png"))
                try save(UtilityView(model: model, settings: true).nativeCodexContent.padding(28).frame(width: 540).background(Design.background)
                    .environment(\.colorScheme, dark ? .dark : .light), to: directory.appendingPathComponent("native-dependency-\(style).png"))
                try save(UtilityView(model: model, settings: false).environment(\.colorScheme, dark ? .dark : .light), to: directory.appendingPathComponent("diagnostics-\(style).png"))
                let workers = RouterModel(demo: true)
                workers.state = DemoData.workerBuildState()
                workers.installedHelperBuildUUID = DemoData.helperBuildUUID
                try save(DashboardView(model: workers).environment(\.colorScheme, dark ? .dark : .light), to: directory.appendingPathComponent("worker-builds-\(style).png"))
                try save(UtilityView(model: workers, settings: false).workerBuildContent.padding(28).frame(width: 540).background(Design.background)
                    .environment(\.colorScheme, dark ? .dark : .light), to: directory.appendingPathComponent("worker-build-details-\(style).png"))
                let coverage = RouterModel(demo: true)
                coverage.state = DemoData.interactionCoverageState()
                coverage.installedHelperBuildUUID = DemoData.helperBuildUUID
                try save(DashboardView(model: coverage).environment(\.colorScheme, dark ? .dark : .light), to: directory.appendingPathComponent("interaction-coverage-\(style).png"))
                try save(UtilityView(model: coverage, settings: false).workerBuildContent.padding(28).frame(width: 540).background(Design.background)
                    .environment(\.colorScheme, dark ? .dark : .light), to: directory.appendingPathComponent("interaction-details-\(style).png"))
                let delivery = RouterModel(demo: true)
                delivery.buildStatus = .init(running: "00000000-0000-0000-0000-000000000001", onDisk: "00000000-0000-0000-0000-000000000002")
                delivery.snapshotBytes = 57 * 1_048_576
                delivery.deliveryHealth.waiting = 1; delivery.deliveryHealth.retrying = 2
                delivery.deliveryHealth.submitting = 1; delivery.deliveryHealth.receiptsAwaitingSave = 1
                delivery.deliveryHealth.nextRetryAt = Date().addingTimeInterval(30)
                delivery.deliveryHealth.lastSubmission = .init(outcome: .accepted, recordedAt: Date())
                delivery.deliveryHealth.lastSaveFailure = .init(stage: .receipt, recordedAt: Date())
                delivery.message = "Design preview · Saving will retry. No native submission or terminal action was performed."
                try save(UtilityView(model: delivery, settings: false).environment(\.colorScheme, dark ? .dark : .light), to: directory.appendingPathComponent("diagnostics-delivery-problems-\(style).png"))
                let submission = RouterModel(demo: true)
                submission.state.sessions["atlas"]?.requests["q0"]?.evidence = .unknown
                submission.state.sessions["atlas"]?.requests["q0"]?.answerSubmittedAt = Date()
                submission.state.sessions["atlas"]?.requests["older"] = .init(id: "older", kind: .question, evidence: .unknown, updatedAt: Date())
                try save(DashboardView(model: submission).environment(\.colorScheme, dark ? .dark : .light), to: directory.appendingPathComponent("answer-submission-\(style).png"))
                let gap = RouterModel(demo: true)
                gap.state.sessions["atlas"]?.execution = .unknown
                gap.state.sessions["atlas"]?.protocolGapAt = Date()
                for id in ["q0", "q1"] { gap.state.sessions["atlas"]?.requests[id]?.evidence = .unknown }
                gap.message = "This source is disconnected, shared by multiple clients, or belongs to an older connection. No terminal was selected."
                try save(DashboardView(model: gap).environment(\.colorScheme, dark ? .dark : .light), to: directory.appendingPathComponent("monitoring-gap-\(style).png"))
                if CommandLine.arguments.contains("--bridge-poc") {
                    let bridge = RouterModel(demo: false)
                    bridge.state = DemoData.state()
                    bridge.notificationStatus = "Design preview · Permission not requested"
                    bridge.message = "Design preview · Sample sessions. No live collector or terminal action."
                    try save(UtilityView(model: bridge, settings: true).environment(\.colorScheme, dark ? .dark : .light), to: directory.appendingPathComponent("bridge-settings-\(style).png"))
                    try save(UtilityView(model: bridge, settings: true).startupContent.padding(28).frame(width: 540).background(Design.background)
                        .environment(\.colorScheme, dark ? .dark : .light), to: directory.appendingPathComponent("bridge-startup-\(style).png"))
                    try save(UtilityView(model: bridge, settings: false).environment(\.colorScheme, dark ? .dark : .light), to: directory.appendingPathComponent("bridge-diagnostics-\(style).png"))
                }
                if CommandLine.arguments.contains("--poc-origin-case") {
                    let poc = RouterModel(demo: false)
                    // Only sample data is rendered; the collector is never started.
                    poc.state = DemoData.state()
                    poc.notificationStatus = "Render preview · Permission not requested"
                    try save(UtilityView(model: poc, settings: true).environment(\.colorScheme, dark ? .dark : .light), to: directory.appendingPathComponent("poc-settings-\(style).png"))
                    poc.message = "Test submitted to macOS. Click its notification to check the original pane."
                    try save(UtilityView(model: poc, settings: true).environment(\.colorScheme, dark ? .dark : .light), to: directory.appendingPathComponent("poc-settings-feedback-\(style).png"))
                }
                model.state = .init()
                try save(DashboardView(model: model).environment(\.colorScheme, dark ? .dark : .light), to: directory.appendingPathComponent("empty-\(style).png"))
                model.state = DemoData.state(); model.state.age(now: Date().addingTimeInterval(1200))
                model.message = "The original terminal session could not be found. No other session was selected."
                try save(DashboardView(model: model).environment(\.colorScheme, dark ? .dark : .light), to: directory.appendingPathComponent("uncertain-\(style).png"))
            }
            print("Native SwiftUI previews rendered to \(directory.path)")
        } catch { FileHandle.standardError.write(Data("Preview failed: \(error.localizedDescription)\n".utf8)); exit(1) }
    }
    static func save<V: View>(_ view: V, to url: URL) throws {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -3000, y: 0)); window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
        window.orderOut(nil)
    }
}

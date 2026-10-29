import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
struct MoxieTimerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(delegate: appDelegate)
                .environment(model.timer)
                .environment(model.ui)
                .environment(model.updater)
                .environment(model.focus)
                .environment(model.history)
                .environment(model.calls)
                .environment(model.notion)
                .environment(model.settings)
        } label: {
            MenuBarLabel()
                .environment(model.timer)
                .environment(model.clock)
                .environment(model.focus)
                .environment(model.notion)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var panelController: PanelController?
    private var breakOverlay: BreakOverlayController?
    private var nudgePrompt: NudgePromptController?
    private var captureHotKey: HotKey?
    private var toggleHotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            let model = AppModel.shared
            let panel = PanelController(model: model)
            panelController = panel
            if !model.settings.isConfigured { model.ui.expand(route: .settings) }

            let overlay = BreakOverlayController(model: model)
            breakOverlay = overlay
            model.focus.onPhaseChange = { [weak overlay] in overlay?.sync() }
            overlay.sync()

            model.idle.onReturn = { [weak panel] in
                panel?.setVisible(true)
                model.ui.expand()
            }

            // Not-tracking reminder: amber pill → notification → centred prompt.
            let prompt = NudgePromptController(model: model)
            nudgePrompt = prompt
            let notifier = Notifier.shared
            notifier.setUp()
            if model.settings.trackingReminders { notifier.requestAuthorization() }
            notifier.onStart = { model.activity.startTracking(useSuggestion: model.activity.suggestion != nil) }
            notifier.onNotWorking = { model.activity.notWorking() }
            notifier.onOpen = { [weak panel] in
                panel?.setVisible(true)
                model.ui.tab = .timer
                model.ui.expand()
            }
            model.activity.onNotify = {
                notifier.postNotTracking(since: model.activity.untrackedSince, suggestion: model.activity.suggestion?.choice.label)
            }
            model.activity.onDriftNotify = {
                notifier.postDrift(label: model.activity.driftLabel ?? "something else", task: model.activity.currentTaskName)
            }
            notifier.onBack = { model.activity.backToWork(dropDrift: false) }
            notifier.onAllow = { model.activity.allowForWork() }
            model.calls.onChange = { [weak overlay, weak prompt] in
                // Hide the break screen and prompts when a call starts; show a waiting break once it ends.
                overlay?.sync()
                if model.calls.inCall { prompt?.hide() }
            }
            model.activity.onPrompt = { [weak prompt] in
                prompt?.hide()
                prompt?.show()
            }
            model.activity.onDismissPrompt = { [weak prompt] in prompt?.hide() }
            model.activity.onReviewDue = { [weak panel] in
                panel?.setVisible(true)
                model.ui.expand(route: .review)
                NSSound(named: "Purr")?.play()
            }

            captureHotKey = HotKey(id: 1) { [weak panel] in
                MainActor.assumeIsolated {
                    panel?.setVisible(true)
                    model.ui.expand(route: .capture)
                }
            }
            registerToggleHotKey()
            model.settings.onHotKeyChange = { [weak self] in MainActor.assumeIsolated { self?.registerToggleHotKey() } }
        }
    }

    /// (Re)registers the show/hide shortcut from Settings. macOS refuses a combination another app already
    /// owns; that's reported in the menu and Settings instead of failing silently.
    @MainActor
    private func registerToggleHotKey() {
        let model = AppModel.shared
        let choice = model.settings.toggleHotKey
        toggleHotKey = nil
        toggleHotKey = HotKey(id: 2, keyCode: choice.keyCode, modifiers: choice.modifiers) { [weak self] in
            MainActor.assumeIsolated { self?.panelController?.toggleVisible() }
        }
        var problems: [String] = []
        if toggleHotKey == nil {
            problems.append("\(choice.label) is already used by another app. Pick another show/hide shortcut in Settings.")
            NSLog("MoxieTimer: couldn't register %@ for show/hide", choice.label)
        }
        if captureHotKey == nil {
            problems.append("\(HotKey.captureDescription) (capture) is already used by another app.")
        }
        model.ui.hotKeyProblem = problems.isEmpty ? nil : problems.joined(separator: " ")
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.activity.learner.save()
            AppModel.shared.pet.saveNow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { panelController?.setVisible(true) }
        return true
    }
}

/// The menu bar readout: the running time and the task it's for, so the widget can stay hidden.
/// A "⟳" marks Notion updates waiting to be retried.
private struct MenuBarLabel: View {
    @Environment(TimerStore.self) private var timer
    @Environment(Clock.self) private var clock
    @Environment(FocusStore.self) private var focus
    @Environment(NotionSync.self) private var notion

    var body: some View {
        if let block = focus.block, block.isWorking {
            let remaining = Int(block.remaining(at: clock.now).rounded(.up))
            Text("◎ " + String(format: "%d:%02d", remaining / 60, remaining % 60) + (block.pausedAt == nil ? "" : " ⏸")
                 + taskSuffix + retrySuffix)
                .monospacedDigit()
        } else if let session = timer.session {
            Text(DurationFormat.clock(session.elapsed(at: clock.now)) + (session.isRunning ? "" : " ⏸") + taskSuffix + retrySuffix)
                .monospacedDigit()
        } else if notion.waitingCount > 0 {
            Text("⏱" + retrySuffix)
        } else {
            Image(systemName: "stopwatch")
        }
    }

    private var taskSuffix: String {
        guard let name = timer.draft.task?.name ?? timer.draft.client?.name else { return " · No task" }
        return " · " + (name.count > 24 ? String(name.prefix(23)) + "…" : name)
    }

    private var retrySuffix: String {
        notion.waitingCount > 0 ? "  ⟳\(notion.waitingCount)" : ""
    }
}

private struct MenuBarMenu: View {
    let delegate: AppDelegate
    @Environment(TimerStore.self) private var timer
    @Environment(FocusStore.self) private var focus
    @Environment(WidgetUI.self) private var ui
    @Environment(Updater.self) private var updater
    @Environment(HistoryStore.self) private var history
    @Environment(CallDetector.self) private var calls
    @Environment(NotionSync.self) private var notion
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Button(history.pending.isEmpty ? "Open Review…" : "Review & Send (\(history.pending.count))…") {
            delegate.panelController?.setVisible(true)
            ui.expand(route: .review)
        }
        if notion.waitingCount > 0 {
            Text("Notion: \(notion.waitingCount) update\(notion.waitingCount == 1 ? "" : "s") waiting to retry")
            if let error = notion.waitingError {
                Text(error.count > 80 ? String(error.prefix(79)) + "…" : error)
            }
            Button("Retry Notion Now") { Task { await notion.drainQueue() } }
        }
        Divider()
        if let release = updater.latest {
            Button("Install Update \(release.version)…") {
                delegate.panelController?.setVisible(true)
                ui.expand()
            }
            Divider()
        }
        if let session = timer.session {
            if let task = timer.draft.task {
                Text("On: \(task.name)")
            }
            Button(session.isRunning ? "Pause" : "Resume") { timer.toggle() }
            Button("Switch Task…") {
                delegate.panelController?.setVisible(true)
                ui.tab = .timer
                ui.expand(route: .pickTask)
            }
            Button("Stop & Save") {
                if ui.beginStop(timer: timer, focus: focus, settings: settings) {
                    // The widget opens on "Do you want to mark this as done?".
                } else if !timer.canSaveCurrent {
                    delegate.panelController?.setVisible(true)
                    ui.tab = .timer
                    ui.expand()
                    timer.lastError = LogError.missingClientOrProject.localizedDescription
                } else {
                    Task { await timer.stopAndSave() }
                }
            }
            .disabled(timer.isSaving)
            Button("Discard Timer") { timer.discard() }
        } else {
            Button("Start Timer…") {
                timer.start()
                delegate.panelController?.setVisible(true)
                ui.tab = .timer
                ui.expand(route: .pickTask)
            }
        }
        Divider()
        Button("Capture Task…  (\(HotKey.captureDescription))") {
            delegate.panelController?.setVisible(true)
            ui.expand(route: .capture)
        }
        Button("Focus…") {
            delegate.panelController?.setVisible(true)
            ui.tab = .focus
            ui.expand()
        }
        Button("Add Time Entry…") {
            delegate.panelController?.setVisible(true)
            ui.expand(route: .addEntry)
        }
        if settings.notionIsConfigured {
            Button(notion.isSyncing ? "Syncing to Notion…" : "Sync to Notion Now") {
                Task { await notion.sync(userInitiated: true) }
            }
            .disabled(notion.isSyncing)
        }
        Toggle("I'm in a Call", isOn: Binding(get: { calls.inCall }, set: { if $0 != calls.inCall { calls.toggle() } }))
            .help("Pauses breaks and nudges while the timer keeps tracking. Calls using the microphone are detected automatically.")
        Button("Show / Hide Widget  (\(settings.toggleHotKey.label))") {
            delegate.panelController?.toggleVisible()
        }
        if let problem = ui.hotKeyProblem {
            Text("⚠︎ " + problem)
        }
        Button("Reset Widget Position") {
            delegate.panelController?.setVisible(true)
            delegate.panelController?.resetPosition()
        }
        Button("Check for Updates…") {
            delegate.panelController?.setVisible(true)
            ui.expand(route: .settings)
            Task { await updater.check(userInitiated: true) }
        }
        .disabled(updater.isBusy)
        Button("Settings…") {
            delegate.panelController?.setVisible(true)
            ui.expand(route: .settings)
        }
        Divider()
        Button("Quit Moxie Timer") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

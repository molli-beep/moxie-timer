import SwiftUI

struct WidgetRoot: View {
    /// Reports the content size so the panel can hug it.
    let onSize: (CGSize) -> Void
    @Environment(WidgetUI.self) private var ui
    @Environment(ActivityWatcher.self) private var activity
    @Environment(AppSettings.self) private var rootSettings

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            PillBar()
            if rootSettings.petEnabled {
                PetBubble()
            }
            if activity.checkInDue {
                CheckInBubble()
            }
            if ui.expanded {
                ExpandedCard()
            }
        }
        // Room for the drop shadows inside the transparent window.
        .padding(EdgeInsets(top: 6, leading: 18, bottom: 22, trailing: 10))
        .fixedSize()
        .onGeometryChange(for: CGSize.self, of: \.size) { onSize($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

/// The always-visible strip: `[+]  ( ● 0:00:08  ⏸  ■ )`
struct PillBar: View {
    @Environment(TimerStore.self) private var timer
    @Environment(Clock.self) private var clock
    @Environment(WidgetUI.self) private var ui
    @Environment(Updater.self) private var updater
    @Environment(FocusStore.self) private var focus
    @Environment(ActivityWatcher.self) private var activity
    @Environment(CallDetector.self) private var calls

    private var notTracking: Bool {
        activity.nudge != .none && timer.session?.isRunning != true
    }

    private var drifting: Bool { activity.drift != .none }
    private var alerting: Bool { notTracking || drifting }

    @Environment(AppSettings.self) private var pillSettings

    var body: some View {
        HStack(spacing: 8) {
            if pillSettings.petEnabled {
                PetPerch()
            }
            if let release = updater.latest {
                Button { ui.expand() } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white, Theme.running)
                        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                }
                .buttonStyle(.plain)
                .help("Moxie Timer \(release.version) is available")
            }

            Button { ui.expand(route: .addEntry) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.navy))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add a time entry manually")

            Button { calls.toggle() } label: {
                Image(systemName: calls.inCall ? "phone.fill" : "phone")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(calls.inCall ? .white : Theme.navy)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(calls.inCall ? Theme.running : Theme.pill))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(calls.inCall ? .clear : Theme.navy.opacity(0.35)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(calls.inCall
                  ? "In a call\(calls.micApps.isEmpty ? "" : " (\(calls.micApps.joined(separator: ", ")))") — breaks, nudges and the pet wait; the timer keeps tracking. Click when the call is over."
                  : "Click when you're in a call: breaks, nudges and the pet wait, the timer keeps tracking.")

            HStack(spacing: 6) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                    if drifting {
                        Text("Back to: \(activity.currentTaskName)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.onBreak)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 200, alignment: .leading)
                    } else if let block = focus.block, let name = focus.target?.name {
                        // Focus mode: keep the task in view at all times.
                        Text(name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 170, alignment: .leading)
                        Text(blockText(block))
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.muted)
                    } else if notTracking {
                        Text("Not tracking")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.onBreak)
                    } else {
                        Text(timeText)
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.ink)
                    }
                }
                .padding(.leading, 12)
                .padding(.vertical, 6)
                .overlay(WindowDragArea { ui.toggle() })
                .help("Click to open, drag to move")

                if let session = timer.session {
                    pillButton(session.isRunning ? "pause.fill" : "play.fill", filled: false, help: session.isRunning ? "Pause" : "Resume") {
                        if focus.block?.isWorking == true {
                            focus.isPaused ? focus.resumeBlock() : focus.pauseBlock()
                        } else {
                            timer.toggle()
                        }
                    }
                    pillButton("stop.fill", filled: true, help: "Stop & save") {
                        if !timer.canSaveCurrent {
                            ui.tab = .timer
                            ui.expand()
                            timer.lastError = LogError.missingClientOrProject.localizedDescription
                        } else {
                            Task { await timer.stopAndSave() }
                        }
                    }
                    .disabled(timer.isSaving)
                } else {
                    pillButton("play.fill", filled: true, help: "Start timer") {
                        // Time starts straight away; the card opens on the task picker so the entry is tied
                        // to a Moxie task from the start ("No task" is one of the choices).
                        timer.start()
                        ui.tab = .timer
                        ui.expand(route: .pickTask)
                    }
                }
            }
            .padding(.trailing, 4)
            .frame(height: 36)
            // Opaque, so the pill stays readable over dark windows; the orange tint sits on top.
            .background(Capsule().fill(Theme.pill).overlay(Capsule().fill(Theme.onBreak.opacity(alerting ? 0.15 : 0))))
            .overlay(Capsule().strokeBorder(alerting ? Theme.onBreak : Theme.navy.opacity(0.35), lineWidth: alerting ? 1.5 : 1))
            .compositingGroup()
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
    }

    private var timeText: String {
        guard let session = timer.session else { return "0:00:00" }
        return DurationFormat.clock(session.elapsed(at: clock.now))
    }

    private var dotColor: Color {
        if alerting { return Theme.onBreak }
        if let block = focus.block {
            if block.pausedAt != nil { return Theme.muted }
            switch block.phase {
            case .warmup: return Theme.warmup
            case .focus: return Theme.running
            case .breakDue, .onBreak, .breakOver: return Theme.onBreak
            }
        }
        guard let session = timer.session else { return Theme.faint }
        return session.isRunning ? Theme.running : Theme.muted
    }

    private func blockText(_ block: FocusBlock) -> String {
        let remaining = Int(block.remaining(at: clock.now).rounded(.up))
        let clockText = String(format: "%d:%02d", remaining / 60, remaining % 60)
        switch block.phase {
        case .warmup: return "warm-up \(clockText)"
        case .focus: return block.pausedAt == nil ? clockText : "paused"
        case .onBreak: return "break \(clockText)"
        case .breakDue, .breakOver: return calls.inCall ? "break after call" : "break"
        }
    }

    private func pillButton(_ systemName: String, filled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(filled ? .white : Theme.ink)
                .frame(width: 28, height: 28)
                .background(Circle().fill(filled ? Theme.navy : .white))
                .overlay(Circle().strokeBorder(filled ? .clear : Theme.border))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Non-fatal message from the last save, e.g. Moxie ignoring the billable toggle.
struct SaveNoticeBanner: View {
    @Environment(TimerStore.self) private var timer

    var body: some View {
        if let notice = timer.notice {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill").foregroundStyle(Theme.navy)
                Text(notice).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { timer.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.ink)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.navy.opacity(0.07)))
            .padding(.horizontal, 16)
            .padding(.top, 14)
        }
    }
}

/// The dropdown card under the pill.
struct ExpandedCard: View {
    @Environment(WidgetUI.self) private var ui
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Group {
            if ui.route == .settings || !settings.isConfigured {
                SettingsView()
            } else if ui.route == .addEntry {
                ManualEntryView()
            } else if ui.route == .tasks {
                TaskListView()
            } else if ui.route == .capture {
                CaptureView()
            } else if ui.route == .review {
                ReviewView()
            } else if ui.route == .pickTask {
                TaskPickerView()
            } else {
                VStack(spacing: 0) {
                    UpdateBanner()
                    IdleBanner()
                    ReviewBanner()
                    SaveNoticeBanner()
                    header
                    switch ui.tab {
                    case .focus: FocusTab()
                    case .timer: TimerTab()
                    case .recent: RecentTab()
                    case .insights: InsightsTab()
                    case .pet: PetTab()
                    }
                }
            }
        }
        // Review gets more room for its timeline.
        .frame(width: ui.route == .review ? 600 : 540)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.border))
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .onExitCommand { ui.collapse() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                tabButton("Focus", systemName: "scope", tab: .focus)
                tabButton("Timer", systemName: "stopwatch", tab: .timer)
                tabButton("Recent", systemName: "clock.arrow.circlepath", tab: .recent)
                tabButton("Insights", systemName: "chart.bar.fill", tab: .insights)
                tabButton("Pet & Voice", systemName: "pawprint", tab: .pet)
            }
            .padding(3)
            .fixedSize()
            .background(RoundedRectangle(cornerRadius: 11).fill(Theme.cream))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.border))

            WindowDragArea()
                .frame(maxWidth: .infinity, minHeight: 30)

            headerIcon("gearshape", help: "Settings") { ui.route = .settings }
            headerIcon("chevron.up", help: "Collapse (Esc)") { ui.collapse() }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private func tabButton(_ title: String, systemName: String, tab: WidgetUI.Tab, help: String? = nil) -> some View {
        let selected = ui.tab == tab
        return Button { ui.tab = tab } label: {
            Label(title, systemImage: systemName)
                .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.ink : Theme.muted)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(selected ? .white : .clear)
                    .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 2, y: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? title)
    }

    private func headerIcon(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// "Still on it?" — a light check-in under the pill while the timer runs.
struct CheckInBubble: View {
    @Environment(ActivityWatcher.self) private var activity
    @Environment(WidgetUI.self) private var ui

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Still on “\(activity.currentTaskName)”?")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
            HStack(spacing: 6) {
                Button("Yes 👍") { activity.answerCheckIn(.yes) }
                    .buttonStyle(ChipButtonStyle())
                Button("Switch task") {
                    activity.answerCheckIn(.switchTask)
                    ui.tab = .timer
                    ui.expand(route: .pickTask)
                }
                .buttonStyle(ChipButtonStyle())
                Button("Break") { activity.answerCheckIn(.takeBreak) }
                    .buttonStyle(ChipButtonStyle())
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.warmup.opacity(0.5)))
        .compositingGroup()
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }
}

import SwiftUI

struct TimerTab: View {
    @Environment(TimerStore.self) private var timer
    @Environment(FocusStore.self) private var focus
    @Environment(WidgetUI.self) private var ui
    @Environment(Clock.self) private var clock

    @State private var durationText = ""
    @FocusState private var durationFocused: Bool

    var body: some View {
        @Bindable var timer = timer
        let now = clock.now

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(DurationFormat.clock(timer.session?.elapsed(at: now) ?? 0))
                        .font(.system(size: 36, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                    Text(subtitle(now: now))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                CircleIconButton(
                    systemName: timer.session?.isRunning == true ? "pause.fill" : "play.fill",
                    size: 44,
                    filled: timer.session == nil,
                    help: timer.session == nil ? "Start" : (timer.session!.isRunning ? "Pause" : "Resume")
                ) {
                    if timer.session == nil {
                        timer.start()
                        ui.route = .pickTask
                    } else {
                        timer.toggle()
                    }
                }
            }

            if let session = timer.session {
                adjustBox(session: session, now: now)

                Button { ui.route = .pickTask } label: {
                    HStack(spacing: 6) {
                        Image(systemName: timer.draft.task == nil ? "exclamationmark.circle" : "checklist")
                        Text(timer.draft.task.map { "Task: \($0.name)" } ?? "No task yet · pick one")
                            .lineLimit(1)
                        if timer.draft.currentTaskMeta?.clickUpURL != nil { ClickUpBadge() }
                        Spacer(minLength: 4)
                        Text(timer.draft.task == nil ? "Pick" : "Switch").fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(ChipButtonStyle())
                .foregroundStyle(timer.draft.task == nil ? Theme.onBreak : Theme.ink)
                .help("Switching saves the time so far as its own entry and starts a new one on the new task")

                if focus.block == nil {
                    Button {
                        focus.startFromTimer()
                        ui.tab = .focus
                    } label: {
                        Label("Focus on this · \(focus.suggestedMinutes) min block", systemImage: "scope")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ChipButtonStyle())
                    .help("Turn this timer into a focus block with a countdown and a break at the end")
                } else if let block = focus.block, block.isWorking {
                    Label("In a focus block — see the Focus tab", systemImage: "scope")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.running)
                }
            }

            if timer.session != nil, ui.askWhatNow || timer.draft.client == nil {
                QuickPickStrip()
            }
            if timer.draft.client == nil {
                SuggestionChip()
            }

            EntryFields(draft: $timer.draft)

            if let error = timer.lastError {
                ErrorBanner(message: error) { timer.lastError = nil }
            }

            footer
        }
        .padding(16)
        .onAppear { syncDurationText(now) }
        .onChange(of: now) { _, newValue in syncDurationText(newValue) }
    }

    private func subtitle(now: Date) -> String {
        guard let session = timer.session else { return "Pick what you're working on, then start." }
        let start = session.start(at: now)
        var text = "Started at \(start.formatted(date: .omitted, time: .shortened)) · \(start.relativeDayName)"
        if !session.isRunning { text += " · paused" }
        return text
    }

    private func adjustBox(session: TimerSession, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    CapsLabel("Started")
                    FieldBox {
                        HStack(spacing: 6) {
                            Image(systemName: "clock").foregroundStyle(Theme.muted)
                            DatePicker(
                                "Started",
                                selection: Binding(get: { session.start(at: now) }, set: { timer.setStart($0) }),
                                in: ...now,
                                displayedComponents: .hourAndMinute
                            )
                            .labelsHidden()
                            .datePickerStyle(.field)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    CapsLabel("Duration")
                    FieldBox {
                        TextField("0:00:00", text: $durationText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14).monospacedDigit())
                            .focused($durationFocused)
                            .onSubmit { applyDuration() }
                            .onChange(of: durationFocused) { _, focused in if !focused { applyDuration() } }
                    }
                }
            }

            HStack(spacing: 6) {
                ForEach([-15, -5, 5, 15], id: \.self) { minutes in
                    Button(minutes < 0 ? "−\(-minutes)m" : "+\(minutes)m") {
                        timer.adjust(by: TimeInterval(minutes * 60))
                        syncDurationText(.now, force: true)
                    }
                    .buttonStyle(ChipButtonStyle())
                }
            }

            (Text("Type ") + code("45m") + Text(", ") + code("1.5h") + Text(" or ") + code("1:30")
                + Text(" — the start time follows along."))
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.cream))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }

    private func code(_ text: String) -> Text {
        Text(text).font(.system(size: 11, weight: .semibold).monospaced()).foregroundStyle(Theme.ink)
    }

    @ViewBuilder
    private var footer: some View {
        if timer.session != nil {
            HStack {
                Button(role: .destructive) { timer.discard() } label: {
                    Label("Discard", systemImage: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                }
                .buttonStyle(.plain)
                Spacer()
                Button { Task { await timer.stopAndSave() } } label: {
                    HStack(spacing: 8) {
                        if timer.isSaving {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "stop.fill").font(.system(size: 10))
                        }
                        Text(timer.isSaving ? "Saving…" : "Stop & save entry")
                    }
                    .frame(width: 190)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(timer.isSaving)
            }
        } else {
            Button {
                timer.start()
                ui.route = .pickTask
            } label: {
                Label("Start timer", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func syncDurationText(_ now: Date, force: Bool = false) {
        guard force || !durationFocused else { return }
        durationText = DurationFormat.clock(timer.session?.elapsed(at: now) ?? 0)
    }

    private func applyDuration() {
        if let value = DurationFormat.parse(durationText) {
            timer.setDuration(value)
        }
        syncDurationText(.now, force: true)
    }
}

import SwiftUI

/// The Timer tab: the clock, then one of three states under it —
/// the question ("What are you working on?"), a one-line summary of what the time is logged to,
/// or the full pickers when details are open. Tapping the clock opens the time adjuster.
struct TimerTab: View {
    @Environment(TimerStore.self) private var timer
    @Environment(FocusStore.self) private var focus
    @Environment(WidgetUI.self) private var ui
    @Environment(Clock.self) private var clock

    @State private var durationText = ""
    @FocusState private var durationFocused: Bool
    /// The start/length row under the clock.
    @State private var timeOpen = false
    /// The full client/project/task/ticket pickers instead of the summary line.
    @State private var detailsOpen = false

    var body: some View {
        @Bindable var timer = timer
        let now = clock.now
        let asking = timer.session != nil && (ui.askWhatNow || (timer.draft.client == nil && !detailsOpen))

        VStack(alignment: .leading, spacing: 14) {
            clockRow(now: now)

            if let session = timer.session, timeOpen {
                adjustRow(session: session, now: now)
            }

            if timer.session == nil {
                // Nothing running: the pickers, so a client can be chosen before starting.
                EntryFields(draft: $timer.draft)
            } else if asking {
                QuickPickStrip(onSearch: {
                    ui.askWhatNow = false
                    detailsOpen = true
                })
                if timer.draft.client == nil {
                    SuggestionChip()
                }
                notesLine
            } else if detailsOpen {
                detailsPanel
            } else {
                summaryCard
                focusRow
            }

            if let error = timer.lastError {
                ErrorBanner(message: error) { timer.lastError = nil }
            }

            footer
        }
        .padding(16)
        .onAppear { syncDurationText(now) }
        .onChange(of: now) { _, newValue in syncDurationText(newValue) }
        .onChange(of: timer.session == nil) { _, ended in
            if ended {
                timeOpen = false
                detailsOpen = false
            }
        }
    }

    // MARK: Clock

    private func clockRow(now: Date) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    guard timer.session != nil else { return }
                    withAnimation(.easeOut(duration: 0.15)) { timeOpen.toggle() }
                } label: {
                    Text(DurationFormat.clock(timer.session?.elapsed(at: now) ?? 0))
                        .font(.system(size: 40, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                .help(timer.session == nil ? "" : (timeOpen ? "Hide the time adjuster" : "Adjust the start time or length"))
                HStack(spacing: 6) {
                    if let session = timer.session {
                        Circle()
                            .fill(session.isRunning ? Theme.running : Theme.muted)
                            .frame(width: 7, height: 7)
                    }
                    Text(subtitle(now: now))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            CircleIconButton(
                systemName: timer.session?.isRunning == true ? "pause.fill" : "play.fill",
                size: 44,
                filled: timer.session == nil,
                help: timer.session == nil ? "Start" : (timer.session!.isRunning ? "Pause" : "Resume")
            ) { timer.toggle() }
        }
    }

    private func subtitle(now: Date) -> String {
        guard let session = timer.session else { return "Pick what you're working on, then start." }
        let start = session.start(at: now)
        var text = "Started \(start.formatted(date: .omitted, time: .shortened)) · \(start.relativeDayName)"
        if !session.isRunning { text += " · paused" }
        return text
    }

    // MARK: Time adjuster (behind the clock)

    private func adjustRow(session: TimerSession, now: Date) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                CapsLabel("Start")
                DatePicker(
                    "Started",
                    selection: Binding(get: { session.start(at: now) }, set: { timer.setStart($0) }),
                    in: ...now,
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()
                .datePickerStyle(.field)
                .frame(width: 78)
            }
            HStack(spacing: 6) {
                CapsLabel("Length")
                TextField("0:00:00", text: $durationText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13).monospacedDigit())
                    .focused($durationFocused)
                    .onSubmit { applyDuration() }
                    .onChange(of: durationFocused) { _, focused in if !focused { applyDuration() } }
                    .padding(.horizontal, 8)
                    .frame(width: 76, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                    .help("Type 45m, 1.5h or 1:30 — the start time follows along")
            }
            Spacer(minLength: 4)
            ForEach([-15, -5, 5, 15], id: \.self) { minutes in
                Button(minutes < 0 ? "−\(-minutes)" : "+\(minutes)") {
                    timer.adjust(by: TimeInterval(minutes * 60))
                    syncDurationText(.now, force: true)
                }
                .buttonStyle(ChipButtonStyle())
                .help(minutes < 0 ? "Take \(-minutes) minutes off" : "Add \(minutes) minutes")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cream))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    // MARK: Logging to

    /// One line for what the time is logged to, with Change to open the pickers.
    private var summaryCard: some View {
        @Bindable var timer = timer
        let draft = timer.draft
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let client = draft.client {
                    ClientAvatar(name: client.name, size: 32)
                } else {
                    Image(systemName: "person.2")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.pill))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(summaryTitle(draft))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(draft.client == nil ? Theme.muted : Theme.ink)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(draft.task?.name ?? draft.ticket.map { "Ticket \($0.name)" } ?? "No task")
                            .lineLimit(1)
                        Text("·")
                        Label(draft.isBillable ? "Billable" : "Non-billable", systemImage: "dollarsign.circle")
                            .foregroundStyle(draft.isBillable ? Theme.running : Theme.muted)
                            .fontWeight(.semibold)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                Button(draft.client == nil ? "Set" : "Change") {
                    withAnimation(.easeOut(duration: 0.15)) { detailsOpen = true }
                }
                .buttonStyle(ChipButtonStyle())
                .help("Change the client, project, task, ticket or billable setting")
            }
            Divider().overlay(Theme.border)
            notesField
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.cream))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }

    private func summaryTitle(_ draft: EntryDraft) -> String {
        guard let client = draft.client else { return "Not set yet" }
        return draft.project.map { "\(client.name) · \($0.name)" } ?? client.name
    }

    /// The full pickers, with Done to fold them back into the summary line.
    private var detailsPanel: some View {
        @Bindable var timer = timer
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let client = timer.draft.client {
                    ClientAvatar(name: client.name, size: 32)
                }
                Text("Logging to")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button("Done") {
                    withAnimation(.easeOut(duration: 0.15)) { detailsOpen = false }
                }
                .buttonStyle(ChipButtonStyle())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            EntryFields(draft: $timer.draft)
                .padding(.horizontal, 6)
                .background(Rectangle().fill(.white))
                .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.border), alignment: .top)
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.cream))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var notesLine: some View {
        notesField
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }

    private var notesField: some View {
        @Bindable var timer = timer
        return HStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            TextField("Add a note about this time (optional)", text: $timer.draft.notes)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
    }

    @ViewBuilder
    private var focusRow: some View {
        if focus.block == nil {
            Button {
                focus.startFromTimer()
                ui.tab = .focus
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "scope").foregroundStyle(Theme.navy)
                    Text("Turn this into a focus block")
                    Spacer()
                    Text("\(focus.suggestedMinutes) min · break after")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ChipButtonStyle())
            .help("A countdown on this timer, with a break at the end; the time already tracked is kept")
        } else if let block = focus.block, block.isWorking {
            Label("In a focus block — see the Focus tab", systemImage: "scope")
                .font(.system(size: 11))
                .foregroundStyle(Theme.running)
        }
    }

    // MARK: Footer

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
                        Text(timer.isSaving ? "Saving…" : "Stop & save")
                    }
                    .frame(width: 150)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(timer.isSaving)
            }
        } else {
            Button {
                timer.start()
                ui.askWhatNow = timer.draft.client == nil
            } label: {
                Label("Start timer", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: Duration text

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

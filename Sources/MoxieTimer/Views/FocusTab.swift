import SwiftUI

/// One-thing mode: choose a single task, give it a tiny first step, and focus in adaptive blocks.
struct FocusTab: View {
    @Environment(FocusStore.self) private var focus
    @Environment(AppSettings.self) private var settings
    @Environment(TaskInbox.self) private var inbox
    @Environment(AIService.self) private var ai
    @Environment(TimerStore.self) private var timer
    @Environment(Clock.self) private var clock
    @Environment(WidgetUI.self) private var ui

    @State private var isPicking = false
    @State private var isSuggesting = false
    @State private var chosenMinutes: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let banner = focus.banner {
                CelebrationBanner(message: banner, finished: focus.lastFinished) { focus.clearBanner() }
            }
            if let error = focus.lastError {
                ErrorBanner(message: error) { focus.lastError = nil }
            }

            if let block = focus.block, block.isWorking, let target = focus.target {
                activeView(block: block, target: target)
            } else if let target = focus.target {
                readyView(target: target)
            } else {
                chooseView
            }
        }
        .padding(16)
        .task { await inbox.refreshIfStale() }
    }

    // MARK: Choose

    private var chooseView: some View {
        VStack(alignment: .leading, spacing: 14) {
            TodayStrip()

            VStack(alignment: .leading, spacing: 3) {
                Text(greeting)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                Text("What's the one thing?")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.ink)
            }

            QuickStartComposer()

            upNext
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: clock.now)
        let part = hour < 12 ? "Good morning" : (hour < 18 ? "Good afternoon" : "Good evening")
        return "\(part) · \(clock.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))"
    }

    private var upNext: some View {
        let all = inbox.visibleTasks
        let rows = Array(all.prefix(5))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                CapsLabel("Up next")
                if !all.isEmpty {
                    Text("\(all.count)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(Capsule().fill(Theme.cream))
                }
                Spacer()
                Button { Task { await pickForMe() } } label: {
                    HStack(spacing: 4) {
                        if isPicking { ProgressView().controlSize(.mini) } else { Image(systemName: "sparkles") }
                        Text(isPicking ? "Choosing…" : "Pick for me")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.navy)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Capsule().fill(Theme.navy.opacity(0.07)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isPicking || (all.isEmpty && !inbox.tasks.isEmpty))
                .help(ai.hasEnabledEngine ? "Let AI choose the best next task from this list" : "Choose the most urgent task from this list")
            }

            InboxFilterBar()

            if rows.isEmpty {
                if inbox.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading your tasks…").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    .padding(.vertical, 10)
                } else if let error = inbox.lastError {
                    ErrorBanner(message: error) { inbox.lastError = nil }
                } else {
                    Text(inbox.isFiltered ? "Nothing open for this filter — add one above." : "No open tasks. Add one above.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .padding(.vertical, 6)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { task in
                        TaskRow(task: task, isNew: inbox.justAdded.contains(task.id)) { Task { await focus.select(task) } }
                    }
                }
                Button { ui.route = .tasks } label: {
                    HStack(spacing: 4) {
                        Text(all.count > rows.count ? "See all \(all.count) tasks" : "Open task list")
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.navy)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            }
        }
    }

    private func pickForMe() async {
        isPicking = true
        defer { isPicking = false }
        if inbox.tasks.isEmpty { await inbox.refresh() }
        let candidates = Array(inbox.visibleTasks.prefix(12))
        guard let fallback = candidates.first else {
            // A load error is already shown under the list; only explain the empty case here.
            if inbox.lastError == nil { focus.lastError = "No open tasks found in Moxie. Add one above." }
            return
        }
        var chosen = fallback
        var reason = "Most urgent by due date and priority."
        if ai.hasEnabledEngine, candidates.count > 1 {
            do {
                let pick = try await ai.pick(from: candidates.map(describe))
                chosen = candidates[pick.index]
                reason = pick.reason.isEmpty ? "Suggested by \(ai.lastEngine?.title ?? "AI")." : pick.reason
            } catch {
                reason += " (AI unavailable, used rules.)"
            }
        }
        await focus.select(chosen)
        focus.pickReason = reason
    }

    private func describe(_ task: MoxieTask) -> String {
        var parts = [task.name]
        let context = [task.client?.name, task.project?.name].compactMap { $0 }.joined(separator: " / ")
        if !context.isEmpty { parts.append(context) }
        if let due = task.due { parts.append("due \(due.formatted(date: .abbreviated, time: .omitted))") }
        if let priority = task.taskPriority { parts.append("priority \(priority)") }
        if task.isTicket { parts.append("client support ticket") }
        return parts.joined(separator: " — ")
    }

    // MARK: Ready

    private func readyView(target: FocusTarget) -> some View {
        @Bindable var focus = focus
        let minutes = chosenMinutes ?? focus.suggestedMinutes
        let options = Array(Set(FocusStore.presetMinutes + [focus.suggestedMinutes])).sorted()

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    CapsLabel("Up next")
                    Spacer()
                    Button("Change") { focus.clearTarget() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.navy)
                }
                Text(target.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if !target.context.isEmpty {
                        Text(target.context).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    if let due = target.due.flatMap({ MoxieTask.dayFormatter.date(from: String($0.prefix(10))) }) {
                        DueBadge(date: due)
                    }
                    KindBadge(isTicket: target.ticketId != nil, isOwn: target.taskId == nil && target.ticketId == nil)
                }
                if let reason = focus.pickReason {
                    Label(reason, systemImage: "sparkles")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.navy.opacity(0.8))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                CapsLabel("Tiny first step")
                HStack(spacing: 6) {
                    FieldBox {
                        TextField("The 2-minute first action…", text: Binding(
                            get: { focus.target?.firstStep ?? "" },
                            set: { focus.target?.firstStep = $0 }
                        ))
                        .textFieldStyle(.plain)
                    }
                    Button { Task { await suggestStep(target) } } label: {
                        Group {
                            if isSuggesting { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
                        }
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cream))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSuggesting || !ai.hasEnabledEngine)
                    .help("Suggest a first step with AI")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                CapsLabel("Focus block")
                HStack(spacing: 6) {
                    ForEach(options, id: \.self) { option in
                        Button { chosenMinutes = option } label: {
                            Text("\(option)m\(option == focus.suggestedMinutes ? " ★" : "")")
                                .font(.system(size: 12, weight: option == minutes ? .bold : .medium))
                                .foregroundStyle(option == minutes ? .white : Theme.ink.opacity(0.8))
                                .padding(.horizontal, 10)
                                .frame(height: 26)
                                .background(Capsule().fill(option == minutes ? Theme.navy : .white))
                                .overlay(Capsule().strokeBorder(option == minutes ? .clear : Theme.border))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Toggle("Start with a 5-minute warm-up", isOn: $focus.warmupEnabled)
                    .toggleStyle(.switch)
                    .tint(Theme.navy)
                    .controlSize(.mini)
                    .font(.system(size: 12))
                Text("★ adapts: longer after blocks you finish, shorter after ones you stop early.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
            }

            if timer.draft.client == nil {
                Label(timer.canSaveCurrent
                      ? "No client yet — you can set it in the end-of-day review."
                      : "No client yet — set it in the Timer tab before the time is saved.",
                      systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.onBreak)
            }

            Button {
                focus.startBlock(minutes: minutes)
                chosenMinutes = nil
            } label: {
                Label("Start focusing · \(minutes) min", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)

            FinishControl(target: target, primary: false)
        }
    }

    private func suggestStep(_ target: FocusTarget) async {
        isSuggesting = true
        defer { isSuggesting = false }
        do {
            let description = target.taskId.flatMap { id in inbox.tasks.first { $0.id == id }?.description } ?? ""
            let step = try await ai.firstStep(task: target.name, context: "\(target.context)\n\(description.prefix(600))")
            focus.target?.firstStep = step
        } catch {
            focus.lastError = error.localizedDescription
        }
    }

    // MARK: Active

    private func activeView(block: FocusBlock, target: FocusTarget) -> some View {
        let now = clock.now
        let remaining = Int(block.remaining(at: now).rounded(.up))
        let color = block.pausedAt != nil ? Theme.muted : (block.phase == .warmup ? Theme.warmup : Theme.running)

        return VStack(spacing: 14) {
            ZStack {
                Circle().stroke(Color.black.opacity(0.07), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: block.progress(at: now))
                    .stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text(String(format: "%d:%02d", remaining / 60, remaining % 60))
                        .font(.system(size: 34, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                    Text(block.pausedAt != nil ? "Paused" : (block.phase == .warmup ? "Warm-up" : (block.snoozed ? "Snoozed" : "Focus")))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color)
                }
            }
            .frame(width: 160, height: 160)
            .padding(.top, 4)

            VStack(spacing: 4) {
                Text(target.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if !target.context.isEmpty {
                    Text(target.context).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }

            if !target.firstStep.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.right.circle.fill").foregroundStyle(Theme.navy)
                    Text(target.firstStep)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cream))
            }

            HStack(spacing: 8) {
                Button(block.pausedAt == nil ? "Pause" : "Resume") {
                    block.pausedAt == nil ? focus.pauseBlock() : focus.resumeBlock()
                }
                .buttonStyle(ChipButtonStyle())
                Button("Stop block") { focus.stopBlock() }
                    .buttonStyle(ChipButtonStyle())
                    .help("Stop focusing; the time stays in the Timer tab")
                Spacer()
            }

            FinishControl(target: target, primary: true) {
                Button { Task { await focus.saveForLater() } } label: {
                    Text("Save, continue later").lineLimit(1).frame(maxWidth: .infinity)
                }
                .buttonStyle(ChipButtonStyle())
                .help("Save the time and keep this as Up next")
            }
            .disabled(focus.isFinishing)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Shared pieces

struct TaskRow: View {
    let task: MoxieTask
    var isNew = false
    let action: () -> Void
    @Environment(FocusStore.self) private var focus
    @Environment(AppSettings.self) private var settings
    @State private var hovering = false
    @State private var confirming = false
    @State private var working = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: action) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(task.isTicket ? Theme.warmup : priorityColor)
                        .frame(width: 8, height: 8)
                        .frame(width: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(task.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            if isNew {
                                Text("NEW")
                                    .font(.system(size: 8.5, weight: .heavy))
                                    .tracking(0.5)
                                    .foregroundStyle(Theme.running)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule().fill(Theme.running.opacity(0.14)))
                            }
                        }
                        HStack(spacing: 5) {
                            KindBadge(isTicket: task.isTicket)
                            let context = [task.client?.name, task.project?.name].compactMap { $0 }.joined(separator: " · ")
                            if !context.isEmpty {
                                Text(context).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 4)
                    if hovering, !confirming {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Theme.navy))
                            .help("Focus on this")
                    } else if let due = task.due, !confirming {
                        DueBadge(date: due)
                    }
                }
                .padding(.leading, 8)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if settings.completeInMoxie, hovering || confirming || working {
                Button {
                    if confirming {
                        working = true
                        Task {
                            await focus.complete(task)
                            working = false
                            confirming = false
                        }
                    } else {
                        confirming = true
                    }
                } label: {
                    Group {
                        if working {
                            ProgressView().controlSize(.mini)
                        } else if confirming {
                            Text(task.isTicket ? "Close?" : "Done?").font(.system(size: 10, weight: .bold))
                        } else {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        }
                    }
                    .foregroundStyle(confirming ? .white : Theme.running)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(Capsule().fill(confirming ? Theme.running : Theme.running.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help(task.isTicket ? "Close this ticket in Moxie (click twice)" : "Mark this task complete in Moxie (click twice)")
            }
        }
        .padding(.trailing, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.cream.opacity(hovering ? 1 : 0)))
        .onHover { inside in
            hovering = inside
            if !inside, !working { confirming = false }
        }
    }

    private var priorityColor: Color {
        switch task.priorityRank {
        case 4: return Theme.danger
        case 3: return Theme.onBreak
        case 2: return Theme.warmup
        default: return Theme.faint
        }
    }
}

struct DueBadge: View {
    let date: Date

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private var days: Int {
        Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: date).day ?? 0
    }

    private var label: String {
        switch days {
        case ..<0: return "\(-days)d overdue"
        case 0: return "Today"
        case 1: return "Tomorrow"
        case 2...6: return date.formatted(.dateTime.weekday(.abbreviated))
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    private var color: Color {
        switch days {
        case ..<0: return Theme.danger
        case 0: return Theme.onBreak
        default: return Theme.muted
        }
    }
}

struct CelebrationBanner: View {
    let message: String
    var finished: FocusStore.FinishedTask? = nil
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text("🎉")
                Text(message).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: onDismiss) { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            if let finished {
                QuickActionsRow(finished: finished, onDone: onDismiss)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.ink)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.running.opacity(0.12)))
    }
}

/// "You were away" prompt from the idle monitor.
struct IdleBanner: View {
    @Environment(IdleMonitor.self) private var idle

    var body: some View {
        if let away = idle.pending {
            VStack(alignment: .leading, spacing: 8) {
                Label("You were away \(DurationFormat.short(away.duration)) (\(away.start.formatted(date: .omitted, time: .shortened))–\(away.end.formatted(date: .omitted, time: .shortened)))",
                      systemImage: "moon.zzz.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("The timer kept running. What should happen to that time?")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                HStack(spacing: 6) {
                    Button("Keep") { idle.keep() }.buttonStyle(ChipButtonStyle())
                    Button("Discard") { idle.discard(andPause: false) }.buttonStyle(ChipButtonStyle())
                    Button("Discard & pause") { idle.discard(andPause: true) }.buttonStyle(ChipButtonStyle())
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.warmup.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.warmup.opacity(0.3)))
            .padding(.horizontal, 16)
            .padding(.top, 14)
        }
    }
}

/// Shown on top of the card while entries are held for review.
struct ReviewBanner: View {
    @Environment(HistoryStore.self) private var history
    @Environment(WidgetUI.self) private var ui

    var body: some View {
        let pending = history.pending
        if !pending.isEmpty {
            let olderThanToday = pending.contains { !Calendar.current.isDateInToday($0.start) }
            Button { ui.route = .review } label: {
                HStack(spacing: 8) {
                    Image(systemName: "tray.full.fill").foregroundStyle(olderThanToday ? Theme.onBreak : Theme.navy)
                    Text(olderThanToday
                         ? "\(pending.count) held entries include earlier days — review & send"
                         : "\(pending.count) entries (\(DurationFormat.short(pending.reduce(0) { $0 + $1.duration }))) waiting for review")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill((olderThanToday ? Theme.onBreak : Theme.navy).opacity(0.07)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 14)
        }
    }
}

/// "Looks like Client · Project" — one click applies the learned suggestion.
struct SuggestionChip: View {
    @Environment(ActivityWatcher.self) private var activity

    var body: some View {
        if let suggestion = activity.suggestion {
            Button { activity.applySuggestion() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Use \(suggestion.choice.label)").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(suggestion.reason).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.navy)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.navy.opacity(0.06)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// TASK / TICKET / OWN label so it's always clear what you're working on.
struct KindBadge: View {
    let isTicket: Bool
    var isOwn = false

    var body: some View {
        let (text, color): (String, Color) = isOwn ? ("OWN", Theme.muted) : (isTicket ? ("TICKET", Theme.warmup) : ("TASK", Theme.navy))
        Text(text)
            .font(.system(size: 8.5, weight: .heavy))
            .tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.12)))
            .help(isOwn ? "Something you typed — not a Moxie task" : (isTicket ? "Moxie ticket" : "Moxie task"))
    }
}

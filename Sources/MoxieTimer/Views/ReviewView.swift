import SwiftUI

/// End-of-day review: check held entries, fill gaps, attach tasks, tick the ones that are done, then send.
/// Time goes to Moxie first, then ticked tasks are completed in Moxie, then Notion is mirrored.
struct ReviewView: View {
    /// Gaps are untracked stretches inside your work hours; they can be hidden or dismissed one by one.
    @AppStorage("reviewShowGaps") private var showGaps = true
    @AppStorage("reviewDismissedGaps") private var dismissedGaps = ""
    @State private var sendingIds: Set<String> = []
    @Environment(HistoryStore.self) private var history
    @Environment(TimerStore.self) private var timer
    @Environment(AppSettings.self) private var settings
    @Environment(WidgetUI.self) private var ui
    @Environment(ReviewPusher.self) private var pusher

    @State private var result: String?

    private static let minimumGap: TimeInterval = 15 * 60

    private enum Item: Identifiable {
        case entry(LoggedEntry)
        case gap(Date, Date)

        var id: String {
            switch self {
            case let .entry(entry): return entry.id
            case let .gap(start, _): return "gap-\(start.timeIntervalSince1970)"
            }
        }
    }

    private struct Day: Identifiable {
        let date: Date
        let items: [Item]
        let total: TimeInterval
        var id: Date { date }
    }

    var body: some View {
        let pending = history.pending
        let ready = pending.filter(\.hasCategory)
        let missing = pending.count - ready.count
        let noTask = pending.filter { !$0.hasTask }.count

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { ui.route = nil } label: {
                    Label("Review & send", systemImage: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                WindowDragArea().frame(maxWidth: .infinity, minHeight: 24)
                Button {
                    ui.editorSeed = .init(returnTo: .review)
                    ui.route = .addEntry
                } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.navy)
                    .help("Add an entry")
            }

            DayRecap()

            HStack {
                Toggle("Show untracked gaps", isOn: $showGaps)
                    .toggleStyle(.switch).tint(Theme.navy).controlSize(.mini)
                    .font(.system(size: 11))
                    .help("Gaps are parts of your work hours (Settings → Review & reminders) that no entry covers.")
                Spacer()
            }

            if pending.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.system(size: 28)).foregroundStyle(Theme.running)
                    Text("Nothing waiting — everything is in Moxie.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                HStack(spacing: 8) {
                    summary("Held", "\(pending.count)")
                    summary("Time", DurationFormat.short(pending.reduce(0) { $0 + $1.duration }))
                    summary("No task", "\(noTask)", warn: noTask > 0)
                    summary("Need client", "\(missing)", warn: missing > 0)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(days(pending)) { day in
                            Section {
                                ForEach(day.items) { item in
                                    switch item {
                                    case let .entry(entry): entryRow(entry)
                                    case let .gap(start, end):
                                        if showGaps, !dismissedGaps.contains(gapKey(start)) { gapRow(start, end) }
                                    }
                                }
                            } header: {
                                HStack {
                                    Text(day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased())
                                    Spacer()
                                    Text(DurationFormat.short(day.total).uppercased())
                                }
                                .font(.system(size: 11, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(Theme.ink.opacity(0.75))
                                .padding(.vertical, 8)
                                .background(.white)
                            }
                        }
                    }
                }
                .frame(height: 440)
            }

            if let result {
                CelebrationBanner(message: result) { self.result = nil }
            }

            if !pending.isEmpty {
                Button { Task { await send() } } label: {
                    HStack(spacing: 8) {
                        if pusher.isPushing { ProgressView().controlSize(.small).tint(.white) } else { Image(systemName: "paperplane.fill") }
                        Text(pusher.isPushing ? "Sending…" : "Send \(ready.count) to Moxie")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(ready.isEmpty || pusher.isPushing)
                if noTask > 0 {
                    Text("Highlighted entries have no task. Click one to attach a task, or send it as it is.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.onBreak)
                }
                if missing > 0 {
                    Text("Entries without a client stay here until you pick one.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(16)
    }

    private func summary(_ title: String, _ value: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CapsLabel(title)
            Text(value).font(.system(size: 17, weight: .bold)).foregroundStyle(warn ? Theme.onBreak : Theme.ink)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cream))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    private func entryRow(_ entry: LoggedEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                ui.editorSeed = .init(editId: entry.id, returnTo: .review)
                ui.route = .addEntry
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.start.formatted(date: .omitted, time: .shortened))
                        Text(entry.end.formatted(date: .omitted, time: .shortened)).foregroundStyle(Theme.faint)
                    }
                    .font(.system(size: 11).monospacedDigit())
                    .frame(width: 58, alignment: .leading)

                    VStack(alignment: .leading, spacing: 2) {
                        if entry.hasCategory {
                            Text([entry.draft.client?.name, entry.draft.project?.name ?? "No project"].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                        } else {
                            Label("Pick a client", systemImage: "exclamationmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.onBreak)
                        }
                        if let task = entry.draft.task {
                            HStack(spacing: 5) {
                                Image(systemName: "checklist").font(.system(size: 10))
                                Text(task.name).lineLimit(1)
                                if entry.draft.currentTaskMeta?.clickUpURL != nil { ClickUpBadge() }
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink.opacity(0.8))
                        } else {
                            Label("No task · click to attach one", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.onBreak)
                        }
                        if !entry.draft.notes.isEmpty {
                            Text(entry.draft.notes).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(2)
                        }
                        if let error = entry.sendError {
                            Text(error).font(.system(size: 10)).foregroundStyle(Theme.danger).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(DurationFormat.clock(entry.duration))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        if entry.hasCategory {
                            Button { Task { await sendOne(entry) } } label: {
                                Group {
                                    if sendingIds.contains(entry.id) {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Label("Send", systemImage: "paperplane.fill").font(.system(size: 10, weight: .semibold))
                                    }
                                }
                                .foregroundStyle(Theme.navy)
                                .padding(.horizontal, 7)
                                .frame(height: 20)
                                .background(Capsule().fill(Theme.navy.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                            .disabled(!sendingIds.isEmpty || pusher.isPushing)
                            .help("Send just this entry to Moxie now")
                        }
                    }
                    .foregroundStyle(Theme.ink)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if entry.hasTask {
                doneControls(entry)
                    .padding(.leading, 68)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(entry.hasTask ? .clear : Theme.onBreak.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(entry.hasTask ? .clear : Theme.onBreak.opacity(0.35)))
        .padding(.vertical, 1)
        .contextMenu {
            Button("Delete", role: .destructive) { history.remove(entry) }
        }
    }

    /// "Mark task done", plus the second tick when a client portal user is assigned to the task.
    @ViewBuilder
    private func doneControls(_ entry: LoggedEntry) -> some View {
        let markDone = entry.draft.markTaskDone == true
        VStack(alignment: .leading, spacing: 3) {
            Toggle("Mark task done", isOn: Binding(
                get: { markDone },
                set: { value in
                    var updated = entry
                    updated.draft.markTaskDone = value ? true : nil
                    if !value { updated.draft.confirmClientNotice = nil }
                    history.update(updated)
                }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            .help("After the time is sent, move the task to its project's complete status in Moxie")

            if markDone, pusher.mayNotifyClient(entry) {
                Label("Client may be notified: a client portal user is assigned to this task.", systemImage: "envelope.badge")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.onBreak)
                Toggle("Complete it anyway", isOn: Binding(
                    get: { entry.draft.confirmClientNotice == true },
                    set: { value in
                        var updated = entry
                        updated.draft.confirmClientNotice = value ? true : nil
                        history.update(updated)
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            }
        }
    }

    private func gapRow(_ start: Date, _ end: Date) -> some View {
        HStack(spacing: 6) {
            Button {
                ui.editorSeed = .init(start: start, end: end, returnTo: .review)
                ui.route = .addEntry
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                    Text("Gap \(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened)) · \(DurationFormat.short(end.timeIntervalSince(start)))")
                    Spacer()
                    Text("Fill").fontWeight(.semibold)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("No entry covers this part of your work hours. Fill it if you worked, or hide it.")
            Button {
                dismissedGaps += "|" + gapKey(start)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide this gap (lunch, a break…)")
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.muted)
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .padding(.vertical, 2)
    }

    private func gapKey(_ start: Date) -> String { "\(Int(start.timeIntervalSince1970))" }

    private func sendOne(_ entry: LoggedEntry) async {
        sendingIds.insert(entry.id)
        defer { sendingIds.remove(entry.id) }
        let outcome = await pusher.push(entry)
        result = outcome.summary.map { $0 + (timer.notice.map { " " + $0 } ?? "") }
    }

    /// Held entries per day, with gaps against everything logged that day (held or already sent).
    private func days(_ pending: [LoggedEntry]) -> [Day] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: pending) { calendar.startOfDay(for: $0.start) }
        return byDay.keys.sorted().map { day in
            let held = byDay[day]!.sorted { $0.start < $1.start }
            let allThatDay = history.entries.filter { calendar.isDate($0.start, inSameDayAs: day) }.sorted { $0.start < $1.start }
            var items: [Item] = []
            var cursor = settings.workWindow(on: day).map { $0.start } ?? held.first!.start
            for entry in allThatDay {
                if entry.start.timeIntervalSince(cursor) >= Self.minimumGap {
                    items.append(.gap(cursor, entry.start))
                }
                if entry.isPending { items.append(.entry(entry)) }
                cursor = max(cursor, entry.end)
            }
            let dayEnd = min(settings.workWindow(on: day)?.end ?? cursor, calendar.isDateInToday(day) ? Date.now : .distantFuture)
            if dayEnd.timeIntervalSince(cursor) >= Self.minimumGap { items.append(.gap(cursor, dayEnd)) }
            return Day(date: day, items: items, total: held.reduce(0) { $0 + $1.duration })
        }
    }

    private func send() async {
        let outcome = await pusher.pushAll()
        result = outcome.summary
        if let notice = timer.notice { result = (result ?? "") + " " + notice }
    }
}

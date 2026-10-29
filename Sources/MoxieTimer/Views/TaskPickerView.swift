import SwiftUI

/// "Which task is this for?" — opens when the timer starts (and for "Switch task"). Due today and overdue
/// come first, then tasks used recently, then everything else; typing searches task, client and project.
/// "No task" is allowed, and review flags that time later.
struct TaskPickerView: View {
    @Environment(TaskInbox.self) private var inbox
    @Environment(TimerStore.self) private var timer
    @Environment(HistoryStore.self) private var history
    @Environment(WidgetUI.self) private var ui
    @Environment(FocusStore.self) private var focus

    @State private var query = ""
    @State private var working = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var inbox = inbox

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { close() } label: {
                    Label(timer.draft.task == nil ? "Which task is this for?" : "Switch task", systemImage: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                WindowDragArea().frame(maxWidth: .infinity, minHeight: 24)
                if inbox.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await inbox.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.muted)
                        .help("Reload tasks from Moxie")
                }
            }

            if let current = timer.draft.task, timer.session != nil {
                Text("Now on “\(current.name)”. Picking another task saves this time and starts a new entry.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            FieldBox {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                    TextField("Search task, client or project", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit { if let first = results.first { pick(first) } }
                }
            }

            HStack {
                Toggle("Only mine", isOn: $inbox.onlyMine)
                    .toggleStyle(.switch).tint(Theme.navy).controlSize(.mini)
                    .font(.system(size: 12))
                Spacer()
                Button { pickNoTask() } label: {
                    Label("No task", systemImage: "circle.dashed")
                }
                .buttonStyle(ChipButtonStyle())
                .help("Track without a task. Review will flag this entry so you can attach one later.")
            }

            if let error = inbox.lastError {
                ErrorBanner(message: error) { inbox.lastError = nil }
            }
            if let error = timer.lastError {
                ErrorBanner(message: error) { timer.lastError = nil }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections, id: \.title) { section in
                        Section {
                            ForEach(section.tasks) { task in row(task) }
                        } header: {
                            HStack {
                                CapsLabel(section.title)
                                Spacer()
                                Text("\(section.tasks.count)").font(.system(size: 11)).foregroundStyle(Theme.faint)
                            }
                            .padding(.vertical, 6)
                            .background(.white)
                        }
                    }
                    if sections.isEmpty && !inbox.isLoading {
                        Text(query.isEmpty ? "No open tasks in Moxie." : "No tasks match “\(query)”.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .padding(.vertical, 30)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(height: 380)
        }
        .padding(16)
        .disabled(working)
        .task { await inbox.refreshIfStale() }
        .onAppear { searchFocused = true }
    }

    private func row(_ task: MoxieTask) -> some View {
        Button { pick(task) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(task.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        if task.clickUpURL != nil { ClickUpBadge() }
                        if timer.draft.task?.id == task.id {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.running)
                        }
                    }
                    let context = [task.client?.name, task.project?.name].compactMap { $0 }.joined(separator: " · ")
                    if !context.isEmpty {
                        Text(context).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let due = task.due {
                    Text(dueText(due))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isOverdue(due) ? Theme.danger : Theme.muted)
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
    }

    // MARK: Ordering

    private struct PickSection {
        let title: String
        let tasks: [MoxieTask]
    }

    /// Search results, flat, when typing; otherwise due/overdue, recently used, then the rest.
    private var results: [MoxieTask] { sections.flatMap(\.tasks) }

    private var sections: [PickSection] {
        let all = inbox.pickableTasks
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let matches = all.filter { task in
                task.name.localizedCaseInsensitiveContains(q)
                    || (task.client?.name ?? "").localizedCaseInsensitiveContains(q)
                    || (task.project?.name ?? "").localizedCaseInsensitiveContains(q)
            }
            return matches.isEmpty ? [] : [PickSection(title: "Matches", tasks: TaskInbox.ranked(matches, now: .now))]
        }

        let today = Calendar.current.startOfDay(for: .now)
        let due = all.filter { ($0.due.map { $0 <= today } ?? false) }
            .sorted { ($0.due ?? .distantFuture, $0.name) < ($1.due ?? .distantFuture, $1.name) }
        let dueIds = Set(due.map(\.id))

        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = dueIds
        var recent: [MoxieTask] = []
        for entry in history.entries {
            guard let id = entry.draft.task?.id, !seen.contains(id), let task = byId[id] else { continue }
            seen.insert(id)
            recent.append(task)
            if recent.count == 8 { break }
        }

        let rest = TaskInbox.ranked(all.filter { !seen.contains($0.id) }, now: .now)
        return [
            PickSection(title: "Due today & overdue", tasks: due),
            PickSection(title: "Recently used", tasks: recent),
            PickSection(title: "All open tasks", tasks: rest),
        ].filter { !$0.tasks.isEmpty }
    }

    private func isOverdue(_ due: Date) -> Bool { due < Calendar.current.startOfDay(for: .now) }

    private func dueText(_ due: Date) -> String {
        if Calendar.current.isDateInToday(due) { return "Today" }
        if isOverdue(due) { return "Overdue · " + due.formatted(.dateTime.month(.abbreviated).day()) }
        return due.formatted(.dateTime.month(.abbreviated).day())
    }

    // MARK: Actions

    private func pick(_ task: MoxieTask) {
        working = true
        Task {
            defer { working = false }
            if focus.block != nil {
                // A focus block is running: let Focus end it and save its time, then keep timing the new task.
                await focus.select(task)
                guard focus.lastError == nil else { return }
                if timer.session == nil { timer.start() }
                close()
                return
            }
            var draft = EntryDraft(task: task, billable: timer.draft.billable)
            // Keep notes typed for the work in progress when it's the same work, not when switching.
            if timer.draft.task?.id == task.id { draft.notes = timer.draft.notes }
            if await timer.switchTo(draft) { close() }
        }
    }

    /// Explicit "No task": keep the client/project already chosen, drop the task.
    private func pickNoTask() {
        working = true
        Task {
            defer { working = false }
            var draft = timer.draft
            draft.task = nil
            draft.taskMeta = nil
            if await timer.switchTo(draft) {
                // Client and project are still picked in the Timer tab.
                ui.askWhatNow = draft.client == nil
                ui.tab = .timer
                ui.route = nil
            }
        }
    }

    private func close() {
        ui.askWhatNow = false
        ui.tab = .timer
        ui.route = nil
    }
}

/// Marks Moxie tasks that came from Rachel's ClickUp through Make.
struct ClickUpBadge: View {
    var body: some View {
        Text("ClickUp")
            .font(.system(size: 8.5, weight: .heavy))
            .tracking(0.3)
            .foregroundStyle(Color(red: 0.48, green: 0.29, blue: 0.95))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color(red: 0.48, green: 0.29, blue: 0.95).opacity(0.12)))
            .help("Rachel's task, synced from ClickUp by Make. Closing it in ClickUp is handled by Make.")
    }
}

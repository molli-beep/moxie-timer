import SwiftUI

/// All open Moxie tasks, grouped by when they're due.
struct TaskListView: View {
    @Environment(TaskInbox.self) private var inbox
    @Environment(FocusStore.self) private var focus
    @Environment(WidgetUI.self) private var ui

    @State private var query = ""

    var body: some View {
        @Bindable var inbox = inbox

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { ui.route = nil } label: {
                    Label("Tasks", systemImage: "chevron.left")
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
                        .help("Reload from Moxie")
                }
                Button { ui.route = .capture } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.navy)
                    .help("New task")
            }

            FieldBox {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                    TextField("Search tasks", text: $query).textFieldStyle(.plain)
                }
            }

            HStack(spacing: 14) {
                Toggle("Only mine", isOn: $inbox.onlyMine)
                Toggle("Include tickets", isOn: $inbox.includeTickets)
            }
            .toggleStyle(.switch)
            .tint(Theme.navy)
            .controlSize(.mini)
            .font(.system(size: 12))

            InboxFilterBar()

            if let error = inbox.lastError {
                ErrorBanner(message: error) { inbox.lastError = nil }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups, id: \.title) { group in
                        Section {
                            ForEach(group.tasks) { task in
                                TaskRow(task: task) {
                                    Task {
                                        await focus.select(task)
                                        ui.tab = .focus
                                        ui.route = nil
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                CapsLabel(group.title)
                                Spacer()
                                Text("\(group.tasks.count)").font(.system(size: 11)).foregroundStyle(Theme.faint)
                            }
                            .padding(.vertical, 6)
                            .background(.white)
                        }
                    }
                    if groups.isEmpty && !inbox.isLoading {
                        Text(query.isEmpty ? "No open tasks in Moxie." : "No tasks match “\(query)”.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .padding(.vertical, 30)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(height: 400)
        }
        .padding(16)
        .task { await inbox.refreshIfStale() }
    }

    private struct Group {
        let title: String
        let tasks: [MoxieTask]
    }

    private var groups: [Group] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let tasks = inbox.visibleTasks.filter { task in
            q.isEmpty || task.name.localizedCaseInsensitiveContains(q)
                || (task.client?.name ?? "").localizedCaseInsensitiveContains(q)
                || (task.project?.name ?? "").localizedCaseInsensitiveContains(q)
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        func bucket(_ task: MoxieTask) -> Int {
            guard let due = task.due else { return 4 }
            let days = calendar.dateComponents([.day], from: today, to: due).day ?? 0
            switch days {
            case ..<0: return 0
            case 0: return 1
            case 1...7: return 2
            default: return 3
            }
        }
        let titles = ["Overdue", "Today", "This week", "Later", "No due date"]
        let grouped = Dictionary(grouping: tasks, by: bucket)
        return (0..<titles.count).compactMap { index in
            guard let items = grouped[index], !items.isEmpty else { return nil }
            return Group(title: titles[index], tasks: items)
        }
    }
}

/// Quick capture (also opened with the global hotkey): get the thought out of your head and into Moxie.
struct CaptureView: View {
    @Environment(TaskInbox.self) private var inbox
    @Environment(FocusStore.self) private var focus
    @Environment(TimerStore.self) private var timer
    @Environment(Catalog.self) private var catalog
    @Environment(WidgetUI.self) private var ui

    @State private var name = ""
    @State private var draft = EntryDraft()
    @State private var dueChoice: DueChoice = .none
    @State private var isSaving = false
    @State private var error: String?
    @State private var didPrefill = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { ui.route = nil } label: {
                    Label("Capture a task", systemImage: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                WindowDragArea().frame(maxWidth: .infinity, minHeight: 24)
                Text(HotKey.captureDescription)
                    .font(.system(size: 10, weight: .semibold).monospaced())
                    .foregroundStyle(Theme.faint)
            }

            FieldBox {
                TextField("What needs doing?", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($nameFocused)
                    .onSubmit { save(focusNow: true) }
            }

            VStack(alignment: .leading, spacing: 10) {
                if draft.client == nil, let current = currentLink {
                    Button {
                        draft.setClient(current.client)
                        if let project = current.project { draft.setProject(project) }
                    } label: {
                        Label("Use current: \([current.client.name, current.project?.name].compactMap { $0 }.joined(separator: " · "))",
                              systemImage: "link")
                            .lineLimit(1)
                    }
                    .buttonStyle(ChipButtonStyle())
                }

                linkField("Client") {
                    SearchPicker(
                        icon: "person.2", placeholder: "No client",
                        selection: draft.client?.name, items: catalog.clients, title: \.name,
                        isLoading: catalog.isLoading("clients"),
                        onOpen: { await catalog.loadClients() },
                        onRefresh: { await catalog.loadClients(force: true) },
                        onSelect: { client in
                            draft.setClient(client.map { Ref(id: $0.id, name: $0.name) })
                            if let ref = draft.client { Task { await catalog.loadProjects(for: ref) } }
                        }
                    )
                }
                linkField("Project") {
                    SearchPicker(
                        icon: "folder", placeholder: draft.client == nil ? "Pick a client first" : "No project",
                        selection: draft.project?.name,
                        items: draft.client.flatMap { catalog.projectsByClient[$0.id] } ?? [], title: \.name,
                        badge: { $0.isActive ? nil : "Completed" },
                        isLoading: draft.client.map { catalog.isLoading("projects:\($0.id)") } ?? false,
                        disabled: draft.client == nil,
                        onOpen: { if let c = draft.client { await catalog.loadProjects(for: c) } },
                        onRefresh: { if let c = draft.client { await catalog.loadProjects(for: c, force: true) } },
                        onSelect: { project in draft.setProject(project.map { Ref(id: $0.id, name: $0.name) }) }
                    )
                }
                Text("Leave both empty to add the task without a client or project.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
            }

            HStack(spacing: 6) {
                ForEach(DueChoice.allCases) { choice in
                    Button { dueChoice = choice } label: {
                        Text(choice.title)
                            .font(.system(size: 12, weight: dueChoice == choice ? .bold : .medium))
                            .foregroundStyle(dueChoice == choice ? .white : Theme.ink.opacity(0.8))
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(Capsule().fill(dueChoice == choice ? Theme.navy : .white))
                            .overlay(Capsule().strokeBorder(dueChoice == choice ? .clear : Theme.border))
                    }
                    .buttonStyle(.plain)
                }
            }

            if let error {
                ErrorBanner(message: error) { self.error = nil }
            }

            HStack(spacing: 8) {
                Button { save(focusNow: false) } label: {
                    Text("Add for later").frame(maxWidth: .infinity)
                }
                .buttonStyle(ChipButtonStyle())
                .frame(maxWidth: 150)
                .help("Add to Moxie and keep it in Up next")
                Button { save(focusNow: true) } label: {
                    HStack(spacing: 6) {
                        if isSaving { ProgressView().controlSize(.small).tint(.white) } else { Image(systemName: "play.fill") }
                        Text("Add & focus now")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .help("Add to Moxie and start focusing on it (Enter)")
            }
            .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(16)
        .onAppear {
            nameFocused = true
            guard !didPrefill else { return }
            didPrefill = true
            // Start from the Up next filter (so the new task shows there); otherwise unlinked, with the
            // timer's client/project offered as a one-click chip.
            draft = EntryDraft()
            if let seed = ui.captureSeed {
                // A follow-up to the task just finished: same client and project.
                ui.captureSeed = nil
                if let client = seed.client {
                    draft.setClient(client)
                    if let project = seed.project { draft.setProject(project) }
                    Task { await catalog.loadProjects(for: client) }
                }
            } else if let client = inbox.filterClient {
                draft.setClient(client)
                if let project = inbox.filterProject { draft.setProject(project) }
                Task { await catalog.loadProjects(for: client) }
            }
        }
    }

    /// The client/project the timer is currently on, offered as a shortcut.
    private var currentLink: (client: Ref, project: Ref?)? {
        guard let client = timer.draft.client else { return nil }
        return (client, timer.draft.project)
    }

    private func linkField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                CapsLabel(label)
                Text("· optional").font(.system(size: 10)).foregroundStyle(Theme.faint)
            }
            content()
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cream))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        }
    }

    private var dueDate: Date? { dueChoice.date }

    private func save(focusNow: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isSaving else { return }
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                let task = try await inbox.create(name: trimmed, client: draft.client, project: draft.project, due: dueDate)
                name = ""
                if focusNow {
                    await focus.select(task)
                    ui.tab = .focus
                    ui.route = nil
                } else {
                    focus.banner = inbox.matchesFilter(task)
                        ? "Added “\(trimmed)” to Moxie — it's at the top of Up next."
                        : "Added “\(trimmed)” to Moxie. It's outside your current filter — clear the filter to see it."
                    ui.tab = .focus
                    ui.route = nil
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// "Client ▾  Project ▾" filter chips for the inbox. Lists only clients/projects with open items.
struct InboxFilterBar: View {
    @Environment(TaskInbox.self) private var inbox
    @Environment(Catalog.self) private var catalog

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(inbox.isFiltered ? Theme.navy : Theme.faint)
            Menu {
                Button("All clients") { inbox.filterClient = nil }
                Divider()
                ForEach(inbox.filterClients, id: \.ref.id) { item in
                    Button("\(item.ref.name)  (\(item.count))") { inbox.filterClient = item.ref }
                }
            } label: {
                chip(inbox.filterClient?.name ?? "All clients", active: inbox.filterClient != nil)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()

            Menu {
                Button("All projects") { inbox.filterProject = nil }
                Divider()
                ForEach(inbox.filterProjects, id: \.ref.id) { item in
                    Button("\(item.ref.name)  (\(item.count))") {
                        inbox.filterProject = item.ref
                    }
                }
            } label: {
                chip(inbox.filterProject?.name ?? "All projects", active: inbox.filterProject != nil)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(inbox.filterProjects.isEmpty)

            if inbox.isFiltered {
                Button {
                    inbox.filterClient = nil
                    inbox.filterProject = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
            Spacer(minLength: 0)
            if inbox.isLoading || catalog.isLoading("clients") {
                ProgressView().controlSize(.mini)
            } else {
                Button {
                    Task {
                        // Clients/projects/tickets caches are dropped so pickers reload them too.
                        catalog.reset()
                        await catalog.loadClients(force: true)
                        await inbox.refresh()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .help("Reload clients, projects, tasks and tickets from Moxie")
            }
        }
    }

    private func chip(_ title: String, active: Bool) -> some View {
        HStack(spacing: 3) {
            Text(title).lineLimit(1).truncationMode(.tail).frame(maxWidth: 110, alignment: .leading)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
        }
        .font(.system(size: 11, weight: active ? .semibold : .regular))
        .foregroundStyle(active ? Theme.navy : Theme.ink.opacity(0.75))
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(active ? Theme.navy.opacity(0.1) : .white))
        .overlay(Capsule().strokeBorder(active ? Theme.navy.opacity(0.4) : Theme.border))
    }
}

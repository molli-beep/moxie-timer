import SwiftUI

/// Client / project / task / ticket / notes rows, shared by the timer and manual entry screens.
struct EntryFields: View {
    @Binding var draft: EntryDraft
    var labelled = false
    @Environment(Catalog.self) private var catalog
    @State private var addingTicket = false
    @State private var addingTask = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Client") {
                SearchPicker(
                    icon: "person.2", placeholder: "No client",
                    selection: draft.client?.name,
                    items: catalog.clients, title: \.name,
                    isLoading: catalog.isLoading("clients"),
                    onOpen: { await catalog.loadClients() },
                    onRefresh: { await catalog.loadClients(force: true) },
                    onSelect: { client in
                        draft.setClient(client.map { Ref(id: $0.id, name: $0.name) })
                        if let ref = draft.client { Task { await catalog.loadProjects(for: ref) } }
                    }
                )
            }
            row("Project") {
                SearchPicker(
                    icon: "folder", placeholder: "No project",
                    selection: draft.project?.name,
                    items: draft.client.flatMap { catalog.projectsByClient[$0.id] } ?? [],
                    title: \.name,
                    badge: { $0.isActive ? nil : "Completed" },
                    isLoading: draft.client.map { catalog.isLoading("projects:\($0.id)") } ?? false,
                    disabled: draft.client == nil,
                    onOpen: { if let c = draft.client { await catalog.loadProjects(for: c) } },
                    onRefresh: { if let c = draft.client { await catalog.loadProjects(for: c, force: true) } },
                    onSelect: { project in
                        draft.setProject(project.map { Ref(id: $0.id, name: $0.name) })
                        if let ref = draft.project { Task { await catalog.loadTasks(for: ref) } }
                    }
                )
            }
            row("Task", onAdd: { addingTask = true }, adding: $addingTask, form: { NewTaskForm(draft: $draft) { addingTask = false } }) {
                SearchPicker(
                    icon: "checklist", placeholder: "No task",
                    selection: draft.task?.name,
                    items: draft.project.flatMap { catalog.tasksByProject[$0.id] } ?? [],
                    title: \.name,
                    badge: { $0.status },
                    isLoading: draft.project.map { catalog.isLoading("tasks:\($0.id)") } ?? false,
                    disabled: draft.project == nil,
                    onOpen: { if let p = draft.project { await catalog.loadTasks(for: p) } },
                    onRefresh: { if let p = draft.project { await catalog.loadTasks(for: p, force: true) } },
                    onSelect: { task in
                        draft.task = task.map { Ref(id: $0.id, name: $0.name) }
                        draft.taskMeta = task.map {
                            TaskMeta(taskId: $0.id, projectTypeId: $0.projectTypeId, assignees: $0.assignedToList,
                                     clickUpURL: $0.clickUpURL?.absoluteString)
                        }
                    }
                )
            }
            row("Ticket", onAdd: { addingTicket = true }, adding: $addingTicket, form: { NewTicketForm(draft: $draft) { addingTicket = false } }) {
                SearchPicker(
                    icon: "ticket", placeholder: "No ticket",
                    selection: draft.ticket?.name,
                    items: draft.client.flatMap { catalog.ticketsByClient[$0.id] } ?? [],
                    title: \.title,
                    badge: { $0.status },
                    isLoading: draft.client.map { catalog.isLoading("tickets:\($0.id)") } ?? false,
                    disabled: draft.client == nil,
                    onOpen: { if let c = draft.client { await catalog.loadTickets(for: c) } },
                    onRefresh: { if let c = draft.client { await catalog.loadTickets(for: c, force: true) } },
                    onSelect: { ticket in draft.ticket = ticket.map { Ref(id: $0.id, name: $0.title) } }
                )
            }
            row("Notes", divider: false) {
                HStack(alignment: .top, spacing: 10) {
                    if !labelled {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                            .frame(width: 20)
                            .padding(.top, 2)
                    }
                    TextField(labelled ? "What was this time for?" : "What are you working on?", text: $draft.notes, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .lineLimit(1...4)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, labelled ? 12 : 0)
                .background {
                    if labelled {
                        RoundedRectangle(cornerRadius: 10).fill(Theme.cream)
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                    }
                }
            }

            if !labelled { Divider() }
            billableRow

            if let error = catalog.lastError {
                ErrorBanner(message: error) { catalog.lastError = nil }
                    .padding(.top, 6)
            }
        }
    }

    private var billableRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "dollarsign.circle")
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .frame(width: 20)
            Text("Billable")
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink)
            Spacer()
            Toggle("Billable", isOn: $draft.isBillable)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.navy)
                .controlSize(.small)
        }
        .padding(.vertical, labelled ? 4 : 10)
    }

    @ViewBuilder
    private func row<Content: View>(_ label: String, divider: Bool = true, @ViewBuilder content: () -> Content) -> some View {
        row(label, divider: divider, onAdd: nil, adding: .constant(false), form: { EmptyView() }, content: content)
    }

    /// A field; in labelled mode an optional "+" creates a new item in Moxie from a popover form.
    @ViewBuilder
    private func row<Content: View, Form: View>(
        _ label: String, divider: Bool = true, onAdd: (() -> Void)?, adding: Binding<Bool>,
        @ViewBuilder form: @escaping () -> Form, @ViewBuilder content: () -> Content
    ) -> some View {
        if labelled {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    CapsLabel(label)
                    Spacer()
                    if let onAdd {
                        Button(action: onAdd) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.navy)
                                .frame(width: 22, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("New \(label.lowercased()) in Moxie")
                        .popover(isPresented: adding, arrowEdge: .trailing, content: form)
                    }
                }
                if label == "Notes" {
                    content()
                } else {
                    content()
                        .padding(.horizontal, 12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cream))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                }
            }
            .padding(.bottom, 12)
        } else {
            content()
            if divider { Divider() }
        }
    }
}

/// A row that opens a searchable popover list — Moxie workspaces can have hundreds of clients.
struct SearchPicker<Item: Identifiable & Hashable>: View {
    let icon: String
    let placeholder: String
    let selection: String?
    let items: [Item]
    let title: (Item) -> String
    var badge: (Item) -> String? = { _ in nil }
    var isLoading = false
    var disabled = false
    var onOpen: () async -> Void = {}
    var onRefresh: () async -> Void = {}
    let onSelect: (Item?) -> Void

    @State private var isOpen = false

    init(
        icon: String, placeholder: String, selection: String?, items: [Item],
        title: KeyPath<Item, String>, badge: @escaping (Item) -> String? = { _ in nil },
        isLoading: Bool = false, disabled: Bool = false,
        onOpen: @escaping () async -> Void = {}, onRefresh: @escaping () async -> Void = {},
        onSelect: @escaping (Item?) -> Void
    ) {
        self.icon = icon
        self.placeholder = placeholder
        self.selection = selection
        self.items = items
        self.title = { $0[keyPath: title] }
        self.badge = badge
        self.isLoading = isLoading
        self.disabled = disabled
        self.onOpen = onOpen
        self.onRefresh = onRefresh
        self.onSelect = onSelect
    }

    var body: some View {
        Button {
            isOpen = true
            Task { await onOpen() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 20)
                Text(selection ?? placeholder)
                    .font(.system(size: 13, weight: selection == nil ? .regular : .medium))
                    .foregroundStyle(selection == nil ? Theme.faint : Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            PickerList(
                placeholder: placeholder, items: items, title: title, badge: badge,
                selection: selection, isLoading: isLoading, onRefresh: onRefresh
            ) { item in
                onSelect(item)
                isOpen = false
            }
        }
    }
}

/// Compact capsule version of `SearchPicker`, for picking a client/project inline (same searchable popover).
struct SearchChip<Item: Identifiable & Hashable>: View {
    let icon: String
    let placeholder: String
    let selection: String?
    let items: [Item]
    let title: (Item) -> String
    var badge: (Item) -> String? = { _ in nil }
    var isLoading = false
    var disabled = false
    var maxWidth: CGFloat = 130
    var onOpen: () async -> Void = {}
    var onRefresh: () async -> Void = {}
    let onSelect: (Item?) -> Void

    @State private var isOpen = false

    init(
        icon: String, placeholder: String, selection: String?, items: [Item],
        title: KeyPath<Item, String>, badge: @escaping (Item) -> String? = { _ in nil },
        isLoading: Bool = false, disabled: Bool = false, maxWidth: CGFloat = 130,
        onOpen: @escaping () async -> Void = {}, onRefresh: @escaping () async -> Void = {},
        onSelect: @escaping (Item?) -> Void
    ) {
        self.icon = icon
        self.placeholder = placeholder
        self.selection = selection
        self.items = items
        self.title = { $0[keyPath: title] }
        self.badge = badge
        self.isLoading = isLoading
        self.disabled = disabled
        self.maxWidth = maxWidth
        self.onOpen = onOpen
        self.onRefresh = onRefresh
        self.onSelect = onSelect
    }

    var body: some View {
        let active = selection != nil
        Button {
            isOpen = true
            Task { await onOpen() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(selection ?? placeholder)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: maxWidth, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .heavy)).opacity(0.6)
            }
            .font(.system(size: 11.5, weight: active ? .semibold : .medium))
            .foregroundStyle(active ? Theme.navy : Theme.ink.opacity(0.6))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(active ? Theme.navy.opacity(0.09) : Theme.cream))
            .overlay(Capsule().strokeBorder(active ? Theme.navy.opacity(0.3) : Theme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            PickerList(
                placeholder: placeholder, items: items, title: title, badge: badge,
                selection: selection, isLoading: isLoading, onRefresh: onRefresh
            ) { item in
                onSelect(item)
                isOpen = false
            }
        }
    }
}

private struct PickerList<Item: Identifiable & Hashable>: View {
    let placeholder: String
    let items: [Item]
    let title: (Item) -> String
    let badge: (Item) -> String?
    let selection: String?
    let isLoading: Bool
    let onRefresh: () async -> Void
    let onSelect: (Item?) -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { title($0).localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Search…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let first = filtered.first { onSelect(first) } }
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await onRefresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.muted)
                        .help("Reload from Moxie")
                }
            }
            .padding(10)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if selection != nil {
                        option(label: "Clear (\(placeholder.lowercased()))", badge: nil, isSelected: false, muted: true) { onSelect(nil) }
                    }
                    ForEach(filtered) { item in
                        option(label: title(item), badge: badge(item), isSelected: title(item) == selection) { onSelect(item) }
                    }
                    if filtered.isEmpty && !isLoading {
                        Text(items.isEmpty ? "Nothing found in Moxie" : "No matches")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .padding(12)
                    }
                }
                .padding(4)
            }
            .frame(height: min(320, CGFloat(max(filtered.count, 1)) * 32 + 16))
        }
        .frame(width: 300)
        .onAppear { searchFocused = true }
    }

    private func option(label: String, badge: String?, isSelected: Bool, muted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(muted ? Theme.muted : Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge, !badge.isEmpty {
                    Text(badge.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.cream))
                }
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.navy)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
    }
}

struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }

    private struct HoverRow: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.cream.opacity(hovering || configuration.isPressed ? 1 : 0)))
                .onHover { hovering = $0 }
        }
    }
}

/// Creates a ticket in Moxie, linked to the entry's client, and attaches it to the entry.
struct NewTicketForm: View {
    @Binding var draft: EntryDraft
    let close: () -> Void
    @Environment(Catalog.self) private var catalog
    @Environment(AppSettings.self) private var settings

    @State private var subject = ""
    @State private var comment = ""
    @State private var type = ""
    @State private var linkClient = true
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New ticket").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
            FieldBox { TextField("Subject", text: $subject).textFieldStyle(.plain) }
            TextField("Details (optional)", text: $comment, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...4)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cream))
            FieldBox { TextField("Ticket type (optional)", text: $type).textFieldStyle(.plain) }
            if let client = draft.client {
                Toggle("Link to \(client.name)", isOn: $linkClient)
                    .toggleStyle(.switch).tint(Theme.navy).controlSize(.mini).font(.system(size: 12))
            } else {
                Text("Pick a client on the entry to link the ticket to it.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            Text("Tickets belong to a client in Moxie; the project stays on this time entry. You're set as the requester, so the client isn't emailed.")
                .font(.system(size: 10)).foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
            if let error { ErrorBanner(message: error) { self.error = nil } }
            HStack {
                Button("Cancel", action: close).buttonStyle(.plain).foregroundStyle(Theme.muted)
                Spacer()
                Button { Task { await create() } } label: {
                    HStack(spacing: 6) {
                        if isSaving { ProgressView().controlSize(.small).tint(.white) }
                        Text("Create & attach")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isSaving || subject.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(width: 290)
        .onAppear { type = settings.ticketDefaultType }
    }

    private func create() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let trimmedType = type.trimmingCharacters(in: .whitespaces)
            let ticket = try await catalog.createTicket(
                subject: subject.trimmingCharacters(in: .whitespaces),
                comment: comment.trimmingCharacters(in: .whitespacesAndNewlines),
                type: trimmedType,
                client: linkClient ? draft.client : nil
            )
            settings.ticketDefaultType = trimmedType
            draft.ticket = Ref(id: ticket.id, name: ticket.title)
            close()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Creates a task in Moxie under the entry's client/project and attaches it to the entry.
struct NewTaskForm: View {
    @Binding var draft: EntryDraft
    let close: () -> Void
    @Environment(TaskInbox.self) private var inbox

    @State private var name = ""
    @State private var linkClient = true
    @State private var linkProject = true
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New task").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
            FieldBox { TextField("Task name", text: $name).textFieldStyle(.plain).onSubmit { Task { await create() } } }
            if let client = draft.client {
                Toggle("Link to \(client.name)", isOn: $linkClient)
                    .toggleStyle(.switch).tint(Theme.navy).controlSize(.mini).font(.system(size: 12))
            }
            if let project = draft.project {
                Toggle("Put it in \(project.name)", isOn: $linkProject)
                    .toggleStyle(.switch).tint(Theme.navy).controlSize(.mini).font(.system(size: 12))
                    .disabled(!linkClient)
            }
            if draft.client == nil {
                Text("Pick a client (and project) on the entry to link the task to them.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            if let error { ErrorBanner(message: error) { self.error = nil } }
            HStack {
                Button("Cancel", action: close).buttonStyle(.plain).foregroundStyle(Theme.muted)
                Spacer()
                Button { Task { await create() } } label: {
                    HStack(spacing: 6) {
                        if isSaving { ProgressView().controlSize(.small).tint(.white) }
                        Text("Create & attach")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(width: 290)
    }

    private func create() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let client = linkClient ? draft.client : nil
            let project = linkClient && linkProject ? draft.project : nil
            let task = try await inbox.create(name: trimmed, client: client, project: project, due: nil)
            draft.task = Ref(id: task.id, name: task.name)
            close()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

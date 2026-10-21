import Foundation
import Observation

/// Open Moxie tasks across all projects — the source for one-thing mode and "pick for me".
@MainActor @Observable
final class TaskInbox {
    private(set) var tasks: [MoxieTask] = []
    private(set) var tickets: [MoxieTicket] = []
    private(set) var isLoading = false
    private(set) var lastLoaded: Date?
    var lastError: String?

    /// Show only tasks assigned to me (plus unassigned ones).
    var onlyMine: Bool {
        didSet { UserDefaults.standard.set(onlyMine, forKey: "inboxOnlyMine") }
    }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var myUserId: Int?
    @ObservationIgnored private var myUserEmail: String?

    /// Show open Moxie tickets alongside tasks.
    var includeTickets: Bool {
        didSet { UserDefaults.standard.set(includeTickets, forKey: "inboxIncludeTickets") }
    }

    /// Optional client / project filter for the inbox, "Up next" and "Pick for me".
    var filterClient: Ref? {
        didSet {
            if filterClient?.id != oldValue?.id { filterProject = nil }
            UserDefaults.standard.set(filterClient.flatMap { try? JSONEncoder().encode($0) }, forKey: "inboxFilterClient")
        }
    }

    var filterProject: Ref? {
        didSet { UserDefaults.standard.set(filterProject.flatMap { try? JSONEncoder().encode($0) }, forKey: "inboxFilterProject") }
    }

    var isFiltered: Bool { filterClient != nil || filterProject != nil }

    /// Tasks captured from this widget this session, newest first. They stay pinned to the top of
    /// "Up next" (ranking alone would bury a task with no due date) until they're focused or done.
    private(set) var justAdded: [String] = []

    func clearJustAdded(_ id: String) {
        justAdded.removeAll { $0 == id }
    }

    /// Clients that have open items (after "only mine" / tickets), with counts, for the filter menu.
    var filterClients: [(ref: Ref, count: Int)] {
        let grouped = Dictionary(grouping: baseItems.compactMap(\.clientRef), by: \.id)
        return grouped.values.map { ($0[0], $0.count) }
            .sorted { $0.ref.name.localizedCaseInsensitiveCompare($1.ref.name) == .orderedAscending }
    }

    /// Projects with open tasks, limited to the chosen client.
    var filterProjects: [(ref: Ref, count: Int)] {
        let items = baseItems.filter { filterClient == nil || $0.clientRef?.id == filterClient?.id }
        let grouped = Dictionary(grouping: items.compactMap(\.projectRef), by: \.id)
        return grouped.values.map { ($0[0], $0.count) }
            .sorted { $0.ref.name.localizedCaseInsensitiveCompare($1.ref.name) == .orderedAscending }
    }

    @ObservationIgnored private let catalog: Catalog

    init(settings: AppSettings, catalog: Catalog) {
        self.settings = settings
        self.catalog = catalog
        onlyMine = UserDefaults.standard.object(forKey: "inboxOnlyMine") as? Bool ?? true
        filterClient = UserDefaults.standard.data(forKey: "inboxFilterClient").flatMap { try? JSONDecoder().decode(Ref.self, from: $0) }
        filterProject = UserDefaults.standard.data(forKey: "inboxFilterProject").flatMap { try? JSONDecoder().decode(Ref.self, from: $0) }
        includeTickets = UserDefaults.standard.object(forKey: "inboxIncludeTickets") as? Bool ?? true
    }

    /// Tickets shaped as inbox items so they rank and display like tasks.
    private var ticketItems: [MoxieTask] {
        tickets.filter { $0.open != false }.map { ticket in
            let clientId = ticket.clientId ?? ticket.client?.id
            let clientName = ticket.client?.name ?? catalog.clients.first { $0.id == clientId }?.name
            return MoxieTask(
                id: "ticket:\(ticket.id)", name: ticket.title, projectId: nil, status: ticket.status, parentTaskId: nil,
                clientId: clientId,
                client: clientId.map { MoxieTask.Micro(id: $0, name: clientName) },
                assignedToList: ticket.assignedTo,
                dueDate: ticket.dueDate,
                created: ticket.created,
                sourceTicketId: ticket.id
            )
        }
    }

    /// Tasks after the "only mine" filter, best candidates first.
    var visibleTasks: [MoxieTask] {
        let filtered = baseItems.filter { task in
            if let client = filterClient, task.clientRef?.id != client.id { return false }
            if let project = filterProject, task.projectRef?.id != project.id { return false }
            return true
        }
        let ranked = TaskInbox.ranked(filtered, now: .now)
        guard !justAdded.isEmpty else { return ranked }
        let pinned = justAdded.compactMap { id in ranked.first { $0.id == id } }
        return pinned + ranked.filter { !justAdded.contains($0.id) }
    }

    /// Whether a task would show under the current client/project filter.
    func matchesFilter(_ task: MoxieTask) -> Bool {
        if let client = filterClient, task.clientRef?.id != client.id { return false }
        if let project = filterProject, task.projectRef?.id != project.id { return false }
        return true
    }

    /// Open tasks (+ tickets) after "only mine", before the client/project filter.
    private var baseItems: [MoxieTask] {
        let items = tasks + (includeTickets ? ticketItems : [])
        return items.filter { task in
            guard onlyMine, let me = myUserId else { return true }
            let assignees = task.assignedToList ?? []
            return assignees.isEmpty || assignees.contains(me)
        }
    }

    func refreshIfStale() async {
        if let lastLoaded, Date.now.timeIntervalSince(lastLoaded) < 300, !tasks.isEmpty { return }
        await refresh()
    }

    func refresh() async {
        guard let api = settings.makeAPI() else {
            lastError = LogError.notConfigured.localizedDescription
            return
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            await resolveMe(api)
            let all = try await api.allTasks()
            var open = all.filter { $0.isOpen && $0.isSubTask != true }
            // Keep tasks added from here that Moxie's list doesn't include yet, and fill in names it leaves out.
            for id in justAdded {
                guard let local = tasks.first(where: { $0.id == id }) else { continue }
                if let index = open.firstIndex(where: { $0.id == id }) {
                    if open[index].clientRef == nil, local.clientRef != nil { open[index].client = local.client; open[index].clientId = local.clientId }
                    if open[index].projectRef == nil, local.projectRef != nil { open[index].project = local.project }
                } else {
                    open.insert(local, at: 0)
                }
            }
            tasks = open
            // Tickets are a bonus: if they fail to load, tasks still show.
            if let open = try? await api.openTickets() {
                tickets = open
                if open.contains(where: { $0.client?.name == nil }) { await catalog.loadClients() }
            }
            lastLoaded = .now
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Quick capture: creates the task in Moxie, assigned to me.
    @discardableResult
    func create(name: String, client: Ref?, project: Ref?, due: Date?) async throws -> MoxieTask {
        guard let api = settings.makeAPI() else { throw LogError.notConfigured }
        let email = settings.userEmail.trimmingCharacters(in: .whitespaces)
        let request = TaskCreateRequest(
            name: name,
            clientName: client?.name,
            projectName: project?.name,
            dueDate: due.map { MoxieTask.dayFormatter.string(from: $0) },
            assignedTo: email.isEmpty ? nil : [email]
        )
        let created = try await api.createTask(request)
        // Fall back to a local stand-in if Moxie's response didn't decode, so the user can focus on it straight away.
        var task = created ?? MoxieTask(
            id: "local-\(UUID().uuidString)", name: name, projectId: project?.id, status: nil, parentTaskId: nil,
            clientId: client?.id,
            client: client.map { .init(id: $0.id, name: $0.name) },
            project: project.map { .init(id: $0.id, name: $0.name) },
            dueDate: request.dueDate
        )
        // Moxie's create response often leaves out the client/project names (sometimes the ids too).
        // Without them the task has no client/project here and the inbox filter hides it, so fill them
        // in from what was asked for.
        if let client, task.clientRef == nil {
            task.client = .init(id: client.id, name: client.name)
            task.clientId = client.id
        }
        if let project, task.projectRef == nil {
            task.project = .init(id: project.id, name: project.name)
        }
        if task.dueDate == nil { task.dueDate = request.dueDate }
        tasks.removeAll { $0.id == task.id }
        tasks.insert(task, at: 0)
        justAdded.removeAll { $0 == task.id }
        justAdded.insert(task.id, at: 0)
        return task
    }

    /// Sets the ticket's status to the configured "done" label. Returns false if Moxie didn't confirm it.
    func closeTicket(id: String) async throws -> Bool {
        guard let api = settings.makeAPI() else { throw LogError.notConfigured }
        let status = settings.ticketDoneStatus.trimmingCharacters(in: .whitespaces)
        let updated = try await api.updateTicketStatus(id: id, status: status.isEmpty ? "Closed" : status)
        tickets.removeAll { $0.id == id }
        guard let updated else { return true }
        return updated.open == false || updated.status?.caseInsensitiveCompare(status) == .orderedSame
    }

    /// Moves the task to its project type's "complete" stage. Returns false if Moxie didn't confirm it.
    func markComplete(_ task: MoxieTask) async throws -> Bool {
        guard let api = settings.makeAPI() else { throw LogError.notConfigured }
        guard !task.id.hasPrefix("local-") else { throw UpdateError("This task hasn't synced with Moxie yet.") }
        let stages = try await api.taskStages(projectTypeId: task.projectTypeId)
        guard let done = stages.first(where: { $0.complete == true }) else {
            throw UpdateError("Couldn't find a “complete” stage for this project in Moxie.")
        }
        let updated = try await api.updateTask(id: task.id, fields: ["statusId": done.id])
        tasks.removeAll { $0.id == task.id }
        guard let updated else { return true }
        return updated.statusId == done.id || !(updated.completed ?? "").isEmpty
    }

    private func resolveMe(_ api: MoxieAPI) async {
        let email = settings.userEmail.trimmingCharacters(in: .whitespaces).lowercased()
        guard myUserId == nil || myUserEmail != email else { return }
        guard let users = try? await api.users() else { return }
        myUserId = users.first { $0.user.email?.lowercased() == email }?.user.userId
        myUserEmail = email
    }

    /// Moves the task to the stage of its project type whose label matches `label` (case-insensitive).
    /// Returns false when the project type has no such stage, in which case Moxie is left alone.
    func setStage(_ task: MoxieTask, label: String) async throws -> Bool {
        guard let api = settings.makeAPI() else { throw LogError.notConfigured }
        guard !task.id.hasPrefix("local-") else { throw UpdateError("This task hasn't synced with Moxie yet.") }
        let stages = try await api.taskStages(projectTypeId: task.projectTypeId)
        let wanted = label.trimmingCharacters(in: .whitespaces).lowercased()
        guard let stage = stages.first(where: { ($0.label ?? "").trimmingCharacters(in: .whitespaces).lowercased() == wanted })
            ?? stages.first(where: { ($0.label ?? "").lowercased().contains(wanted) }) else { return false }
        _ = try await api.updateTask(id: task.id, fields: ["statusId": stage.id])
        return true
    }

    // MARK: Ranking

    /// Rule-based priority: overdue and due-soon first, then priority, then how long it's been waiting.
    static func score(_ task: MoxieTask, now: Date) -> Double {
        var score = Double(task.priorityRank) * 15
        if let due = task.due {
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now), to: due).day ?? 0
            switch days {
            case ..<0: score += 100 + min(Double(-days) * 2, 40)
            case 0: score += 90
            case 1: score += 60
            case 2...7: score += 40 - Double(days) * 3
            default: break
            }
        }
        if let created = task.created.flatMap(parseTimestamp) {
            score += min(now.timeIntervalSince(created) / 86_400 * 0.5, 15)
        }
        return score
    }

    static func ranked(_ tasks: [MoxieTask], now: Date) -> [MoxieTask] {
        tasks.map { ($0, score($0, now: now)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }
            .map(\.0)
    }

    private static func parseTimestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

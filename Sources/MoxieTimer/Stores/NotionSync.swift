import Foundation
import Observation

/// Keeps Notion's Projects, Task Tracker and Time Tracker databases in step with Moxie.
///
/// Moxie is the source of truth: projects and tasks flow one way, Moxie → Notion. Only the properties
/// listed in `TaskFields`/`ProjectFields` are ever written, so everything added in Notion for planning
/// (Area, Owner, Effort, Launch phase…) survives every sync. Time logged from this widget is mirrored into
/// the Time Tracker as one row per entry, linked to its task.
@MainActor @Observable
final class NotionSync {
    enum State: Equatable {
        case idle, syncing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastSynced: Date?
    /// What the last sync did, e.g. "3 tasks updated, 1 created · 2 time entries".
    private(set) var summary: String?
    /// Last connection test result, for Settings.
    var testResult: (text: String, isError: Bool)?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let catalog: Catalog
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var myUserId: Int?
    @ObservationIgnored private var myUserEmail: String?

    /// Notion page ids for the Moxie records already synced, plus a fingerprint of what was last written
    /// so unchanged records cost no requests.
    private struct Links: Codable {
        struct Link: Codable {
            var page: String
            var fingerprint: String
        }
        var projects: [String: Link] = [:]
        var tasks: [String: Link] = [:]
        /// LoggedEntry id → Time Tracker page id.
        var entries: [String: String] = [:]
        /// Moxie task id → Notion status chosen at finish time, written on the next sync.
        var statusOverrides: [String: String] = [:]
        /// Pushes whose Notion mirror hasn't gone through yet. Optional so files from older versions decode.
        var queue: [MirrorJob]?
    }

    /// One pushed entry to mirror: its Time Tracker row, and the task's totals, status and ClickUp id.
    struct MirrorJob: Codable, Hashable {
        var entryId: String
        var taskId: String?
        var taskName: String?
        /// The task was moved to its complete status in Moxie during this push.
        var completed: Bool
        var clickUpTaskId: String?
        var attempts: Int = 0
        var lastError: String?
    }

    /// Mirrors waiting for a retry after Notion failed (Moxie already has the data). Shown in the menu bar.
    private(set) var waitingCount = 0
    private(set) var waitingError: String?
    @ObservationIgnored private var isMirroring = false

    /// Remembers a status the user chose when finishing a task; the next sync writes it to Notion
    /// even where the sync would otherwise leave the status alone.
    func setStatus(taskId: String, status: String) {
        links.statusOverrides[taskId] = status
        persist()
        requestSoon(after: 3)
    }

    @ObservationIgnored private var links = Links()
    @ObservationIgnored private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MoxieTimer", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: "notion-sync.json")
    }()

    init(settings: AppSettings, history: HistoryStore, catalog: Catalog) {
        self.settings = settings
        self.history = history
        self.catalog = catalog
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(Links.self, from: data) {
            links = saved
        }
        refreshQueueState()
        schedule()
        log("launch: enabled=\(settings.notionEnabled) token=\(settings.makeNotion() != nil) moxie=\(settings.isConfigured) configured=\(settings.notionIsConfigured)")
        if settings.notionIsConfigured {
            requestSoon(after: 15)
        }
    }

    var isSyncing: Bool { state == .syncing }

    // MARK: Scheduling

    /// (Re)starts the periodic sync from the interval in Settings.
    func schedule() {
        timer?.invalidate()
        timer = nil
        let minutes = max(settings.notionSyncMinutes, 5)
        let timer = Timer(timeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settings.notionIsConfigured else { return }
                Task { await self.sync(userInitiated: false) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Syncs shortly, coalescing bursts (a finished task, then its time entry a second later) into one run.
    func requestSoon(after seconds: Double = 20) {
        guard settings.notionIsConfigured else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            await self.sync(userInitiated: false)
        }
    }

    // MARK: Connection test

    func testConnection() async {
        guard let notion = settings.makeNotion() else {
            testResult = ("Paste the integration token first.", true)
            return
        }
        var names: [String] = []
        for (label, id) in [("tasks", settings.notionTasksDB), ("projects", settings.notionProjectsDB),
                            ("clients", settings.notionClientsDB), ("time", settings.notionTimeDB)] {
            do {
                names.append(try await notion.dataSourceTitle(id))
            } catch {
                testResult = ("The \(label) database: \(error.localizedDescription)", true)
                return
            }
        }
        testResult = ("Connected: \(names.joined(separator: ", ")).", false)
    }

    // MARK: Sync

    func sync(userInitiated: Bool) async {
        guard state != .syncing, !isMirroring else { return }
        guard let notion = settings.makeNotion(), let moxie = settings.makeAPI() else {
            if userInitiated { state = .failed("Add the Notion token (and your Moxie key) in Settings first.") }
            return
        }
        state = .syncing
        log("sync start\(userInitiated ? " (user)" : "")")
        do {
            var counts = Counts()
            let clientPages = try await loadClientPages(notion)
            log("clients: \(clientPages.count) Notion client names")
            let projectPages = try await syncProjects(notion: notion, moxie: moxie, clientPages: clientPages, counts: &counts)
            log("projects: \(projectPages.count) linked (\(counts.projectsCreated) created, \(counts.projectsUpdated) updated)")
            let taskPages = try await syncTasks(notion: notion, moxie: moxie, clientPages: clientPages, projectPages: projectPages, counts: &counts)
            log("tasks: \(taskPages.count) linked (\(counts.tasksCreated) created, \(counts.tasksUpdated) updated)")
            try await syncTimeEntries(notion: notion, taskPages: taskPages, counts: &counts)
            persist()
            lastSynced = .now
            summary = counts.description
            state = .idle
            log("sync done: \(counts.description)")
            await drainQueue()
        } catch {
            persist()
            state = .failed(error.localizedDescription)
            log("sync failed: \(error.localizedDescription)")
        }
    }

    /// Appends to `notion-sync.log` next to the links file, for diagnosing failures after the fact.
    nonisolated private func log(_ line: String) {
        let url = fileURL.deletingLastPathComponent().appending(path: "notion-sync.log")
        let stamp = Date.now.formatted(.iso8601)
        let text = "\(stamp) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private struct Counts {
        var projectsCreated = 0, projectsUpdated = 0
        var tasksCreated = 0, tasksUpdated = 0
        var entries = 0

        var description: String {
            var parts: [String] = []
            if tasksCreated + tasksUpdated > 0 {
                parts.append("\(tasksUpdated) task\(tasksUpdated == 1 ? "" : "s") updated, \(tasksCreated) created")
            }
            if projectsCreated + projectsUpdated > 0 {
                parts.append("\(projectsUpdated) project\(projectsUpdated == 1 ? "" : "s") updated, \(projectsCreated) created")
            }
            if entries > 0 { parts.append("\(entries) time entr\(entries == 1 ? "y" : "ies")") }
            return parts.isEmpty ? "Everything already up to date." : parts.joined(separator: " · ")
        }
    }

    // MARK: Clients

    /// Notion client page ids keyed by lower-cased Client Name and Moxie Project Name.
    private func loadClientPages(_ notion: NotionAPI) async throws -> [String: String] {
        let pages = try await notion.queryAll(dataSource: settings.notionClientsDB)
        var map: [String: String] = [:]
        for page in pages {
            for key in [page.text("Client Name"), page.text("Moxie Project Name")] {
                if let key = key?.trimmingCharacters(in: .whitespaces).lowercased(), !key.isEmpty, map[key] == nil {
                    map[key] = page.id
                }
            }
        }
        return map
    }

    private func clientPage(named name: String?, in pages: [String: String]) -> String? {
        guard let name else { return nil }
        return pages[name.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    // MARK: Projects

    private enum ProjectFields {
        static let name = "Project Name"
        static let status = "Status"
        static let clients = "🤝 Clients"
        static let moxieId = "Moxie Project ID"
        static let area = "Area"
    }

    /// Returns Moxie project id → Notion page id for every project seen.
    private func syncProjects(notion: NotionAPI, moxie: MoxieAPI, clientPages: [String: String], counts: inout Counts) async throws -> [String: String] {
        let existing = try await notion.queryAll(dataSource: settings.notionProjectsDB)
        var byMoxieId: [String: NotionAPI.Page] = [:]
        var byName: [String: NotionAPI.Page] = [:]
        for page in existing {
            if let id = page.text(ProjectFields.moxieId)?.trimmingCharacters(in: .whitespaces), !id.isEmpty { byMoxieId[id] = page }
            if let name = page.text(ProjectFields.name)?.lowercased(), byName[name] == nil { byName[name] = page }
        }

        let clients = try await moxie.clients()
        var result: [String: String] = [:]
        for client in clients {
            guard let projects = try? await moxie.projects(clientName: client.name) else { continue }
            let clientPage = clientPage(named: client.name, in: clientPages)
            for project in projects {
                let page = byMoxieId[project.id] ?? byName[project.name.lowercased()]
                var properties: [String: Any] = [
                    ProjectFields.name: NotionAPI.title(project.name),
                    ProjectFields.moxieId: NotionAPI.richText(project.id),
                ]
                if let clientPage { properties[ProjectFields.clients] = NotionAPI.relation([clientPage]) }

                if let page {
                    // A project that ended in Moxie closes the Notion one, but only from "Active" so a
                    // deliberate On Hold / Planning / Cancelled set in Notion is kept.
                    if !project.isActive, page.status(ProjectFields.status) == "Active" {
                        properties[ProjectFields.status] = NotionAPI.status("Complete")
                    }
                    let fingerprint = Self.fingerprint(properties)
                    if links.projects[project.id]?.fingerprint != fingerprint || links.projects[project.id]?.page != page.id {
                        try await notion.updatePage(page.id, properties: properties)
                        counts.projectsUpdated += 1
                        await pace()
                    }
                    links.projects[project.id] = .init(page: page.id, fingerprint: fingerprint)
                    result[project.id] = page.id
                } else if project.isActive {
                    properties[ProjectFields.status] = NotionAPI.status("Active")
                    properties[ProjectFields.area] = NotionAPI.select("Client work")
                    let id = try await notion.createPage(dataSource: settings.notionProjectsDB, properties: properties)
                    counts.projectsCreated += 1
                    links.projects[project.id] = .init(page: id, fingerprint: Self.fingerprint(properties))
                    result[project.id] = id
                    await pace()
                }
            }
        }
        return result
    }

    // MARK: Tasks

    private enum TaskFields {
        static let timeUsed = "Time Used (in Minutes)"
        static let timeTracker = "Time Tracker"
        static let clickUpId = "Rachel - Clickup Task ID"
        static let name = "Task name"
        static let status = "Status"
        static let due = "Due date"
        static let priority = "Priority"
        /// Notion's property is literally "Description " with a trailing space.
        static let description = "Description "
        static let project = "Related Project"
        static let clients = "🤝 Clients"
        static let moxieId = "Moxie Task ID"
        static let owner = "Owner"
        static let completeStatuses: Set<String> = ["Done", "Delivered", "Cancelled"]
    }

    /// Returns Moxie task id → Notion page id for every synced task.
    private func syncTasks(notion: NotionAPI, moxie: MoxieAPI, clientPages: [String: String], projectPages: [String: String], counts: inout Counts) async throws -> [String: String] {
        let existing = try await notion.queryAll(
            dataSource: settings.notionTasksDB,
            filter: ["property": TaskFields.moxieId, "rich_text": ["is_not_empty": true]]
        )
        var byMoxieId: [String: NotionAPI.Page] = [:]
        for page in existing {
            if let id = page.text(TaskFields.moxieId)?.trimmingCharacters(in: .whitespaces), !id.isEmpty { byMoxieId[id] = page }
        }

        await resolveMe(moxie)
        let all = try await moxie.allTasks()
        var result: [String: String] = [:]
        for task in all where task.isSubTask != true && isMine(task) {
            let page = byMoxieId[task.id]
            // A task with no name in Moxie is an empty row, not work; don't create one in Notion for it.
            if page == nil, task.name == "Untitled task" { continue }
            var properties: [String: Any] = [
                TaskFields.name: NotionAPI.title(task.name),
                TaskFields.moxieId: NotionAPI.richText(task.id),
            ]
            if let due = task.dueDate, due.count >= 10 { properties[TaskFields.due] = NotionAPI.date(day: String(due.prefix(10))) }
            if let priority = Self.priorityName(task) { properties[TaskFields.priority] = NotionAPI.select(priority) }
            if let text = task.description?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                properties[TaskFields.description] = NotionAPI.richText(Self.plainText(text))
            }
            if let projectId = task.projectRef?.id ?? task.projectId, let projectPage = projectPages[projectId] {
                properties[TaskFields.project] = NotionAPI.relation([projectPage])
            }
            if let clientPage = clientPage(named: task.clientRef?.name, in: clientPages) {
                properties[TaskFields.clients] = NotionAPI.relation([clientPage])
            }

            if let page {
                let current = page.status(TaskFields.status) ?? ""
                if let chosen = links.statusOverrides[task.id] {
                    properties[TaskFields.status] = NotionAPI.status(chosen)
                } else if task.archived == true {
                    if current != "Cancelled" { properties[TaskFields.status] = NotionAPI.status("Cancelled") }
                } else if !task.isOpen {
                    if !TaskFields.completeStatuses.contains(current) { properties[TaskFields.status] = NotionAPI.status("Done") }
                } else if TaskFields.completeStatuses.contains(current) {
                    // Reopened in Moxie (or closed only in Notion): Moxie wins.
                    properties[TaskFields.status] = NotionAPI.status("To Do")
                }
                let fingerprint = Self.fingerprint(properties)
                if links.tasks[task.id]?.fingerprint != fingerprint || links.tasks[task.id]?.page != page.id {
                    try await notion.updatePage(page.id, properties: properties)
                    counts.tasksUpdated += 1
                    await pace()
                }
                links.statusOverrides[task.id] = nil
                links.tasks[task.id] = .init(page: page.id, fingerprint: fingerprint)
                result[task.id] = page.id
            } else if task.isOpen {
                properties[TaskFields.status] = NotionAPI.status(links.statusOverrides[task.id] ?? "To Do")
                links.statusOverrides[task.id] = nil
                properties[TaskFields.owner] = NotionAPI.select("Molli")
                let id = try await notion.createPage(dataSource: settings.notionTasksDB, properties: properties)
                counts.tasksCreated += 1
                links.tasks[task.id] = .init(page: id, fingerprint: Self.fingerprint(properties))
                result[task.id] = id
                await pace()
            }
            // Tasks already finished in Moxie that never reached Notion are left alone: no backfilling history.
        }
        return result
    }

    /// Moxie's default priority ("Normal") says nothing, so it leaves Notion's Priority alone for planning;
    /// only an explicit Urgent/High, Medium or Low is carried across.
    private static func priorityName(_ task: MoxieTask) -> String? {
        switch task.taskPriority {
        case "Urgent", "High": return "High"
        case "Medium": return "Medium"
        case "Low": return "Low"
        default: return nil
        }
    }

    /// Moxie descriptions are HTML; keep the words.
    private static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</li>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isMine(_ task: MoxieTask) -> Bool {
        guard settings.notionOnlyMine, let me = myUserId else { return true }
        let assignees = task.assignedToList ?? []
        return assignees.isEmpty || assignees.contains(me)
    }

    private func resolveMe(_ api: MoxieAPI) async {
        let email = settings.userEmail.trimmingCharacters(in: .whitespaces).lowercased()
        guard myUserId == nil || myUserEmail != email else { return }
        guard let users = try? await api.users() else { return }
        myUserId = users.first { $0.user.email?.lowercased() == email }?.user.userId
        myUserEmail = email
    }

    // MARK: Time entries

    private enum TimeFields {
        static let name = "Name"
        static let start = "Start Time"
        static let end = "End Time"
        static let minutes = "Total Time (in Minutes)"
        static let task = "Task"
    }

    /// Mirrors every entry sent to Moxie in the last 60 days whose task has a Notion page, once each.
    private func syncTimeEntries(notion: NotionAPI, taskPages: [String: String], counts: inout Counts) async throws {
        let cutoff = Date.now.addingTimeInterval(-60 * 86_400)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        for entry in history.entries where !entry.isPending && entry.start >= cutoff {
            guard links.entries[entry.id] == nil,
                  let task = entry.draft.task, let taskPage = taskPages[task.id] else { continue }
            let minutes = (entry.duration / 60).rounded()
            guard minutes >= 1 else { continue }
            let properties: [String: Any] = [
                TimeFields.name: NotionAPI.title("\(task.name) · \(formatter.string(from: entry.start))"),
                TimeFields.start: NotionAPI.date(entry.start, time: true),
                TimeFields.end: NotionAPI.date(entry.end, time: true),
                TimeFields.minutes: NotionAPI.number(minutes),
                TimeFields.task: NotionAPI.relation([taskPage]),
            ]
            let id = try await notion.createPage(dataSource: settings.notionTimeDB, properties: properties)
            links.entries[entry.id] = id
            counts.entries += 1
            await pace()
        }
    }

    // MARK: Mirror after a push

    /// Mirrors one entry that has just reached Moxie (and, when `completedTask`, whose task Moxie has just
    /// completed). Never called before Moxie succeeds. Runs straight away; if Notion fails, the job stays in
    /// the queue and is retried on the next sync or from "Retry Notion now".
    func mirror(_ entry: LoggedEntry, completedTask: Bool) {
        guard settings.notionIsConfigured else { return }
        let clickUp = entry.draft.currentTaskMeta?.clickUpURL.flatMap { URL(string: $0) }
        let job = MirrorJob(entryId: entry.id, taskId: entry.draft.task?.id, taskName: entry.draft.task?.name,
                            completed: completedTask, clickUpTaskId: MoxieTask.clickUpTaskId(from: clickUp))
        var queue = links.queue ?? []
        if let index = queue.firstIndex(where: { $0.entryId == job.entryId }) {
            queue[index].completed = queue[index].completed || job.completed
            queue[index].clickUpTaskId = queue[index].clickUpTaskId ?? job.clickUpTaskId
        } else {
            queue.append(job)
        }
        links.queue = queue
        persist()
        refreshQueueState()
        Task { await drainQueue() }
    }

    /// Runs every queued mirror job in order. Jobs that fail stay queued with their error.
    func drainQueue() async {
        guard !isMirroring, state != .syncing, settings.notionIsConfigured, let notion = settings.makeNotion(),
              !(links.queue ?? []).isEmpty else { return }
        isMirroring = true
        defer {
            isMirroring = false
            refreshQueueState()
        }
        for job in links.queue ?? [] {
            do {
                try await run(job, notion: notion)
                links.queue?.removeAll { $0.entryId == job.entryId }
                log("mirrored entry \(job.entryId) (task \(job.taskId ?? "none")\(job.completed ? ", done" : ""))")
            } catch {
                if let index = links.queue?.firstIndex(where: { $0.entryId == job.entryId }) {
                    links.queue?[index].attempts += 1
                    links.queue?[index].lastError = error.localizedDescription
                }
                log("mirror failed for entry \(job.entryId): \(error.localizedDescription)")
            }
            persist()
        }
    }

    private func refreshQueueState() {
        let queue = links.queue ?? []
        waitingCount = queue.count
        waitingError = queue.compactMap(\.lastError).first
    }

    private func run(_ job: MirrorJob, notion: NotionAPI) async throws {
        // Time without a Moxie task has no task row to update; Notion only tracks time per task.
        guard let taskId = job.taskId, !taskId.hasPrefix("local-"),
              let entry = history.entries.first(where: { $0.id == job.entryId }) else { return }
        let taskPage = try await upsertTaskPage(taskId: taskId, name: job.taskName ?? entry.draft.task?.name ?? "Untitled task",
                                                completed: job.completed, notion: notion)

        // The entry's Time Tracker row, once.
        var newRow: (id: String, minutes: Double)?
        let minutes = (entry.duration / 60).rounded()
        if links.entries[entry.id] == nil, minutes >= 1 {
            let id = try await notion.createPage(dataSource: settings.notionTimeDB, properties: timeRowProperties(entry, taskName: job.taskName, taskPage: taskPage))
            links.entries[entry.id] = id
            persist()
            newRow = (id, minutes)
            await pace()
        }

        // Totals come from every Time Tracker row on the task, so a retry never counts an entry twice.
        let rows = try await notion.queryAll(
            dataSource: settings.notionTimeDB,
            filter: ["property": TimeFields.task, "relation": ["contains": taskPage]]
        )
        var ids = rows.map(\.id)
        var total = rows.reduce(0) { $0 + ($1.number(TimeFields.minutes) ?? 0) }
        if let newRow, !ids.contains(newRow.id) {
            // Notion's query can lag a moment behind a page it just created.
            ids.append(newRow.id)
            total += newRow.minutes
        }
        var properties: [String: Any] = [
            TaskFields.timeUsed: NotionAPI.number(total),
            TaskFields.timeTracker: NotionAPI.relation(ids),
        ]
        if job.completed {
            // Moxie's complete statuses (Done, Delivered…) are all "Done" in the planner.
            properties[TaskFields.status] = NotionAPI.status("Done")
            links.statusOverrides[taskId] = nil
        }
        if let clickUp = job.clickUpTaskId {
            properties[TaskFields.clickUpId] = NotionAPI.richText(clickUp)
        }
        try await notion.updatePage(taskPage, properties: properties)
        await pace()
    }

    /// The task's Notion page, found by "Moxie Task ID" (so there's never a second row), or created.
    private func upsertTaskPage(taskId: String, name: String, completed: Bool, notion: NotionAPI) async throws -> String {
        let found = try await notion.queryAll(
            dataSource: settings.notionTasksDB,
            filter: ["property": TaskFields.moxieId, "rich_text": ["equals": taskId]]
        )
        if let page = found.first {
            links.tasks[taskId] = .init(page: page.id, fingerprint: links.tasks[taskId]?.fingerprint ?? "")
            return page.id
        }
        let properties: [String: Any] = [
            TaskFields.name: NotionAPI.title(name),
            TaskFields.moxieId: NotionAPI.richText(taskId),
            TaskFields.status: NotionAPI.status(completed ? "Done" : "To Do"),
            TaskFields.owner: NotionAPI.select("Molli"),
        ]
        let id = try await notion.createPage(dataSource: settings.notionTasksDB, properties: properties)
        // An empty fingerprint makes the next full sync fill in due date, project and client.
        links.tasks[taskId] = .init(page: id, fingerprint: "")
        persist()
        await pace()
        return id
    }

    private func timeRowProperties(_ entry: LoggedEntry, taskName: String?, taskPage: String) -> [String: Any] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let name = taskName ?? entry.draft.task?.name ?? "Time"
        return [
            TimeFields.name: NotionAPI.title("\(name) · \(formatter.string(from: entry.start))"),
            TimeFields.start: NotionAPI.date(entry.start, time: true),
            TimeFields.end: NotionAPI.date(entry.end, time: true),
            TimeFields.minutes: NotionAPI.number((entry.duration / 60).rounded()),
            TimeFields.task: NotionAPI.relation([taskPage]),
        ]
    }

    // MARK: Helpers

    /// Stay under Notion's rate limit (about three requests a second).
    private func pace() async {
        try? await Task.sleep(for: .milliseconds(350))
    }

    private static func fingerprint(_ properties: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(properties),
              let data = try? JSONSerialization.data(withJSONObject: properties, options: [.sortedKeys]) else { return UUID().uuidString }
        return String(decoding: data, as: UTF8.self)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(links) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Forgets which Notion pages belong to which Moxie records; the next sync re-matches by Moxie ID.
    func resetLinks() {
        links = Links()
        persist()
    }
}

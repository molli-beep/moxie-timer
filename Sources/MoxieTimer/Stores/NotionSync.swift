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
    }

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
        guard state != .syncing else { return }
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

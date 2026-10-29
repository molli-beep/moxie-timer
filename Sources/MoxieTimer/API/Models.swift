import Foundation

// MARK: - Moxie API payloads (only the fields the widget uses)

struct MoxieClient: Codable, Identifiable, Hashable {
    let id: String
    let name: String
}

struct MoxieProject: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let active: Bool?
    let clientId: String?
    let hexColor: String?

    var isActive: Bool { active ?? true }
}

struct MoxieTask: Codable, Identifiable, Hashable {
    struct Micro: Codable, Hashable {
        let id: String
        let name: String?
    }

    let id: String
    let name: String
    let projectId: String?
    let status: String?
    let parentTaskId: String?
    // Fields used by the focus inbox; all optional because Moxie omits empty ones.
    var clientId: String? = nil
    var projectTypeId: String? = nil
    var statusId: String? = nil
    var client: Micro? = nil
    var project: Micro? = nil
    var description: String? = nil
    var priority: Int? = nil
    var taskPriority: String? = nil
    var assignedToList: [Int]? = nil
    var startDate: String? = nil
    var dueDate: String? = nil
    var created: String? = nil
    var completed: String? = nil
    var archived: Bool? = nil
    var isSubTask: Bool? = nil
    /// Set when this inbox item stands for a Moxie ticket rather than a task.
    var sourceTicketId: String? = nil

    var isTicket: Bool { sourceTicketId != nil }

    var isOpen: Bool { (completed ?? "").isEmpty && archived != true }

    /// `dueDate` is a plain `yyyy-MM-dd` date; interpreted in the local time zone.
    var due: Date? {
        guard let dueDate, !dueDate.isEmpty else { return nil }
        return MoxieTask.dayFormatter.date(from: String(dueDate.prefix(10)))
    }

    /// 0 (none/low) … 4 (urgent).
    var priorityRank: Int {
        switch taskPriority {
        case "Urgent": return 4
        case "High": return 3
        case "Medium": return 2
        case "Normal": return 1
        default: return min(max(priority ?? 0, 0), 4)
        }
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

extension MoxieTask.Micro {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? ""
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? nil
    }
}

extension MoxieTask {
    /// Tolerant decoding: only `id` is required. Moxie omits empty fields and some types vary between records,
    /// so a field that's missing or the wrong type becomes nil instead of failing the whole task.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil }
        id = try c.decode(String.self, forKey: .id)
        let rawName: String? = value(.name)
        name = (rawName?.isEmpty == false) ? rawName! : "Untitled task"
        projectId = value(.projectId)
        status = value(.status)
        parentTaskId = value(.parentTaskId)
        clientId = value(.clientId)
        projectTypeId = value(.projectTypeId)
        statusId = value(.statusId)
        client = value(.client)
        project = value(.project)
        description = value(.description)
        priority = value(.priority)
        taskPriority = value(.taskPriority)
        assignedToList = value(.assignedToList)
        startDate = value(.startDate)
        dueDate = value(.dueDate)
        created = value(.created)
        completed = value(.completed)
        archived = value(.archived)
        isSubTask = value(.isSubTask)
    }

    /// Client as a picker reference, falling back to the top-level `clientId`.
    var clientRef: Ref? {
        guard let name = client?.name, !name.isEmpty else { return nil }
        let id = (client?.id).flatMap { $0.isEmpty ? nil : $0 } ?? clientId
        return id.map { Ref(id: $0, name: name) }
    }

    var projectRef: Ref? {
        guard let name = project?.name, !name.isEmpty else { return nil }
        let id = (project?.id).flatMap { $0.isEmpty ? nil : $0 } ?? projectId
        return id.map { Ref(id: $0, name: name) }
    }
}

extension MoxieTask {
    /// Rachel's ClickUp tasks reach Moxie through a Make scenario that adds a "ClickUp: <url>" line to the
    /// description. The app only reads it (for a badge and the Notion field); it never talks to ClickUp.
    var clickUpURL: URL? { Self.clickUpURL(in: description) }

    static func clickUpURL(in text: String?) -> URL? {
        guard let text, !text.isEmpty else { return nil }
        // Descriptions are HTML, so the URL may sit inside a link tag after the label.
        let pattern = #"ClickUp:\s*(?:<[^>]*>\s*)*(https?://[^\s<>"']+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let raw = String(text[range]).replacingOccurrences(of: "&amp;", with: "&")
        return URL(string: raw)
    }

    /// The ClickUp task id is the last path component (`…/t/86abc123` or `…/t/<team>/CUSTOM-12`).
    static func clickUpTaskId(from url: URL?) -> String? {
        guard let last = url?.pathComponents.last, last != "/", !last.isEmpty else { return nil }
        return last
    }

    /// Moxie gives client portal users negative ids. Updating such a task can email the client.
    var hasClientPortalAssignee: Bool {
        (assignedToList ?? []).contains { $0 < 0 }
    }
}

struct MoxieTaskStage: Decodable, Hashable {
    let id: String
    let label: String?
    let complete: Bool?
}

/// `POST tickets/create`. The client is set through `formData.clientId`; the requester is the user themself,
/// so the client isn't emailed about it.
struct TicketCreateRequest: Encodable {
    struct FormData: Encodable { let clientId: String }
    let userEmail: String
    let subject: String
    let comment: String?
    let ticketType: String?
    let formData: FormData?
}

/// `POST tasks/create` — resolves client and project by exact name.
struct TaskCreateRequest: Encodable {
    let name: String
    let clientName: String?
    let projectName: String?
    let dueDate: String?
    let assignedTo: [String]?
}

struct MoxieTicket: Codable, Identifiable, Hashable {
    let id: String
    let ticketNumber: Int?
    let subject: String?
    let open: Bool?
    let status: String?
    var clientId: String? = nil
    var client: MoxieTask.Micro? = nil
    var assignedTo: [Int]? = nil
    var dueDate: String? = nil
    var created: String? = nil

    var title: String {
        let subject = (subject?.isEmpty == false) ? subject! : "Untitled ticket"
        if let ticketNumber { return "#\(ticketNumber) \(subject)" }
        return subject
    }
}

struct MoxieUser: Decodable, Hashable {
    struct Profile: Decodable, Hashable {
        let userId: Int?
        let firstName: String?
        let lastName: String?
        let email: String?
    }

    let userType: String?
    let user: Profile

    var displayName: String {
        let name = [user.firstName, user.lastName].compactMap { $0 }.joined(separator: " ")
        return name.isEmpty ? (user.email ?? "Unknown") : name
    }
}

/// `POST timeWorked/create`. Ids win over names on Moxie's side (`deliverableId` is the task id), so a task
/// is linked even when its name has changed or isn't unique. Names are kept as a fallback for records that
/// only exist locally (a task captured offline has a `local-…` id).
struct TimeEntryRequest: Encodable {
    let timerStart: String
    let timerEnd: String
    let clientName: String
    /// Optional: Moxie only requires the start and end times.
    let projectName: String?
    let deliverableName: String?
    var clientId: String? = nil
    var projectId: String? = nil
    /// The Moxie task id.
    var deliverableId: String? = nil
    let notes: String?
    let userEmail: String
    /// Defaults to true in Moxie; project billing rules still apply.
    let billable: Bool?
}

struct TimerEvent: Decodable {
    let id: String?
    let billable: Bool?
}

// MARK: - Local models

/// A lightweight reference to a Moxie record, persisted with drafts and history.
struct Ref: Codable, Hashable {
    var id: String
    var name: String
}

/// What the app knew about a task when it was picked, so review can complete it without another lookup.
/// Only trusted while `taskId` still matches the draft's task.
struct TaskMeta: Codable, Hashable {
    var taskId: String
    var projectTypeId: String?
    var assignees: [Int]?
    var clickUpURL: String?

    var hasClientPortalAssignee: Bool { (assignees ?? []).contains { $0 < 0 } }
}

/// What the time is being logged against.
struct EntryDraft: Codable, Hashable {
    var client: Ref?
    var project: Ref?
    var task: Ref?
    var ticket: Ref?
    var notes: String = ""
    /// Optional so drafts saved by older versions still decode; `nil` means billable.
    var billable: Bool? = true
    /// Set by the task picker; nil for drafts from older versions or tasks picked in the field editor.
    var taskMeta: TaskMeta? = nil
    /// "Mark task done" ticked in review: completing the task in Moxie rides along with the push.
    var markTaskDone: Bool? = nil
    /// Second tick for tasks with a client portal assignee, who may be emailed about the change.
    var confirmClientNotice: Bool? = nil

    /// Meta for the current task, ignoring meta left over from a task picked earlier.
    var currentTaskMeta: TaskMeta? {
        guard let task, let taskMeta, taskMeta.taskId == task.id else { return nil }
        return taskMeta
    }

    /// Everything needed to log time against an open Moxie task.
    init(task: MoxieTask, billable: Bool? = true) {
        client = task.clientRef
        project = task.projectRef
        self.task = Ref(id: task.id, name: task.name)
        self.billable = billable
        taskMeta = TaskMeta(taskId: task.id, projectTypeId: task.projectTypeId, assignees: task.assignedToList,
                            clickUpURL: task.clickUpURL?.absoluteString)
    }

    init(client: Ref? = nil, project: Ref? = nil, task: Ref? = nil, ticket: Ref? = nil, notes: String = "",
         billable: Bool? = true, taskMeta: TaskMeta? = nil) {
        self.client = client
        self.project = project
        self.task = task
        self.ticket = ticket
        self.notes = notes
        self.billable = billable
        self.taskMeta = taskMeta
    }

    var isBillable: Bool {
        get { billable ?? true }
        set { billable = newValue }
    }

    mutating func setClient(_ newValue: Ref?) {
        guard newValue != client else { return }
        client = newValue
        project = nil
        task = nil
        ticket = nil
    }

    mutating func setProject(_ newValue: Ref?) {
        guard newValue != project else { return }
        project = newValue
        task = nil
    }

    /// The Moxie create endpoint has no ticket field, so the ticket is folded into the notes.
    var composedNotes: String? {
        var parts: [String] = []
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(trimmed) }
        if let ticket { parts.append("Ticket \(ticket.name)") }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// Same client/project/task, fresh notes — used when starting again from a past entry.
    var reusable: EntryDraft {
        EntryDraft(client: client, project: project, task: task, ticket: ticket, notes: "", billable: billable, taskMeta: currentTaskMeta)
    }
}

/// An entry this widget successfully pushed to Moxie.
struct LoggedEntry: Codable, Identifiable, Hashable {
    var id: String
    var moxieId: String?
    var start: Date
    var end: Date
    var draft: EntryDraft
    /// What Moxie reported back for `billable`, when it reported anything.
    var moxieBillable: Bool?
    /// True while the entry is held locally for review (nil for entries from older versions, which were all sent).
    var pending: Bool?
    /// Why the last attempt to send this entry failed.
    var sendError: String?

    var isPending: Bool { pending == true }
    /// Ready to send: a client is enough; project, task and ticket are optional.
    var hasCategory: Bool { draft.client != nil }
    /// Time with no Moxie task never shows up against a task; review flags it.
    var hasTask: Bool { draft.task != nil }
    var duration: TimeInterval { end.timeIntervalSince(start) }
    /// Billable state as Moxie stored it, falling back to what was requested.
    var isBillable: Bool { moxieBillable ?? draft.isBillable }
}

/// A running or paused timer. Elapsed time excludes pauses; the reported start time is
/// derived as `end - elapsed`, so editing the duration moves the start ("start follows along").
struct TimerSession: Codable, Equatable {
    var accumulated: TimeInterval = 0
    var runningSince: Date?
    var pausedAt: Date?

    var isRunning: Bool { runningSince != nil }

    func end(at now: Date) -> Date {
        runningSince != nil ? now : (pausedAt ?? now)
    }

    func elapsed(at now: Date) -> TimeInterval {
        accumulated + (runningSince.map { now.timeIntervalSince($0) } ?? 0)
    }

    func start(at now: Date) -> Date {
        end(at: now).addingTimeInterval(-elapsed(at: now))
    }

    mutating func pause(at now: Date) {
        guard let runningSince else { return }
        accumulated += now.timeIntervalSince(runningSince)
        self.runningSince = nil
        pausedAt = now
    }

    mutating func resume(at now: Date) {
        guard runningSince == nil else { return }
        runningSince = now
        pausedAt = nil
    }

    mutating func setElapsed(_ value: TimeInterval, at now: Date) {
        accumulated = max(0, value)
        if isRunning { runningSince = now }
    }
}

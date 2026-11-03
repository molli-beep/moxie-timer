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
    /// Custom field values (e.g. the "Sub-project" select). Moxie names the field on each value.
    var customValues: [CustomValue]? = nil
    /// Set when this inbox item stands for a Moxie ticket rather than a task.
    var sourceTicketId: String? = nil

    var isTicket: Bool { sourceTicketId != nil }

    /// A custom field's value, found by its name (case-insensitive) or mapping key, trimmed; nil when blank.
    func customValue(named name: String) -> String? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        let key = wanted.filter { $0.isLetter || $0.isNumber }
        let match = customValues?.first {
            ($0.fieldName ?? "").trimmingCharacters(in: .whitespaces).lowercased() == wanted
                || ($0.mappingKey ?? "").lowercased() == key
        }
        let text = (match?.valueAsString ?? match?.value)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    /// One entry of `customValues`. Every field is optional and tolerantly decoded; `value` keeps a
    /// string form of whatever Moxie sent (string, number or bool).
    struct CustomValue: Codable, Hashable {
        var fieldId: String?
        var fieldName: String?
        var mappingKey: String?
        var valueAsString: String?
        var value: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fieldId = (try? c.decodeIfPresent(String.self, forKey: .fieldId)) ?? nil
            fieldName = (try? c.decodeIfPresent(String.self, forKey: .fieldName)) ?? nil
            mappingKey = (try? c.decodeIfPresent(String.self, forKey: .mappingKey)) ?? nil
            valueAsString = (try? c.decodeIfPresent(String.self, forKey: .valueAsString)) ?? nil
            if let text = try? c.decodeIfPresent(String.self, forKey: .value) {
                value = text
            } else if let number = try? c.decodeIfPresent(Double.self, forKey: .value) {
                value = number == number.rounded() ? String(Int(number)) : String(number)
            } else if let flag = try? c.decodeIfPresent(Bool.self, forKey: .value) {
                value = flag ? "true" : "false"
            }
        }
    }

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
        customValues = value(.customValues)
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

struct TimeEntryRequest: Encodable {
    let timerStart: String
    let timerEnd: String
    let clientName: String
    /// Optional: Moxie only requires the start and end times.
    let projectName: String?
    let deliverableName: String?
    let notes: String?
    let userEmail: String
    /// Not in the documented request schema; Moxie's TimerEvent has a `billable` field, so we send it and
    /// check the response to see whether it was applied.
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

/// What the time is being logged against.
struct EntryDraft: Codable, Hashable {
    var client: Ref?
    var project: Ref?
    var task: Ref?
    var ticket: Ref?
    var notes: String = ""
    /// Optional so drafts saved by older versions still decode; `nil` means billable.
    var billable: Bool? = true

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
        EntryDraft(client: client, project: project, task: task, ticket: ticket, notes: "", billable: billable)
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

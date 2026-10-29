import Foundation
import Observation

/// Pushes reviewed entries in the order the systems depend on each other:
/// 1. the time entry to Moxie (with its task id),
/// 2. when "Mark task done" is ticked, the task to its project type's complete status in Moxie,
/// 3. only then the Notion mirror. A Moxie failure stops the entry there; nothing reaches Notion.
@MainActor @Observable
final class ReviewPusher {
    struct Outcome {
        var sent = 0
        var failed = 0
        var skipped = 0
        var completed = 0
        /// Tasks whose time went through but which weren't completed, with the reason.
        var notCompleted: [String] = []

        var summary: String? {
            var parts: [String] = []
            if sent > 0 { parts.append("Sent \(sent) to Moxie") }
            if completed > 0 { parts.append("\(completed) task\(completed == 1 ? "" : "s") marked done") }
            if failed > 0 { parts.append("\(failed) failed (see the red notes)") }
            if skipped > 0 { parts.append("\(skipped) still need a client") }
            var text = parts.isEmpty ? "" : parts.joined(separator: " · ") + "."
            if !notCompleted.isEmpty { text += " Not completed: " + notCompleted.joined(separator: "; ") + "." }
            return text.isEmpty ? nil : text
        }
    }

    private(set) var isPushing = false

    @ObservationIgnored private let timer: TimerStore
    @ObservationIgnored private let inbox: TaskInbox
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let notion: NotionSync

    init(timer: TimerStore, inbox: TaskInbox, history: HistoryStore, notion: NotionSync) {
        self.timer = timer
        self.inbox = inbox
        self.history = history
        self.notion = notion
    }

    /// Whether completing this entry's task may email a client (a client portal user is assigned).
    func mayNotifyClient(_ entry: LoggedEntry) -> Bool {
        guard let task = entry.draft.task else { return false }
        if let live = inbox.task(id: task.id) { return live.hasClientPortalAssignee }
        return entry.draft.currentTaskMeta?.hasClientPortalAssignee ?? false
    }

    func push(_ entry: LoggedEntry) async -> Outcome {
        guard !isPushing else { return Outcome() }
        isPushing = true
        defer { isPushing = false }
        var outcome = Outcome()
        var done: Set<String> = []
        await prepare([entry])
        await push(entry, outcome: &outcome, completedTasks: &done)
        return outcome
    }

    /// Every held entry with a client, oldest first. Failures stay held with their error.
    func pushAll() async -> Outcome {
        guard !isPushing else { return Outcome() }
        isPushing = true
        defer { isPushing = false }
        var outcome = Outcome()
        var done: Set<String> = []
        let pending = history.pending
        await prepare(pending)
        for entry in pending {
            await push(entry, outcome: &outcome, completedTasks: &done)
        }
        return outcome
    }

    /// Completing needs each task's project type and assignees; reload tasks once if any are unknown.
    private func prepare(_ entries: [LoggedEntry]) async {
        let needsLookup = entries.contains { entry in
            guard entry.draft.markTaskDone == true, let task = entry.draft.task else { return false }
            return inbox.task(id: task.id) == nil && entry.draft.currentTaskMeta?.projectTypeId == nil
        }
        if needsLookup { await inbox.refresh() }
    }

    private func push(_ entry: LoggedEntry, outcome: inout Outcome, completedTasks: inout Set<String>) async {
        guard entry.hasCategory else {
            outcome.skipped += 1
            return
        }

        // 1. Time to Moxie.
        let sent: LoggedEntry
        do {
            sent = try await timer.send(entry, notify: false)
            outcome.sent += 1
        } catch {
            var held = entry
            held.sendError = error.localizedDescription
            history.update(held)
            outcome.failed += 1
            return
        }

        // 2. Status to Moxie.
        var completed = false
        if sent.draft.markTaskDone == true, let ref = sent.draft.task {
            if completedTasks.contains(ref.id) {
                completed = true
            } else if mayNotifyClient(sent), sent.draft.confirmClientNotice != true {
                outcome.notCompleted.append("“\(ref.name)” needs the second tick (the client may be notified)")
            } else if let task = completable(ref, draft: sent.draft) {
                do {
                    if try await inbox.markComplete(task) {
                        completed = true
                        completedTasks.insert(ref.id)
                        outcome.completed += 1
                    } else {
                        outcome.notCompleted.append("Moxie didn't confirm “\(ref.name)” as done")
                    }
                } catch {
                    outcome.notCompleted.append("“\(ref.name)”: \(error.localizedDescription)")
                }
            } else {
                outcome.notCompleted.append("couldn't tell the project type of “\(ref.name)”; reload tasks and complete it again")
            }
        }

        // 3. Notion, only now that Moxie has everything.
        notion.mirror(sent, completedTask: completed)
        notion.requestSoon()
    }

    /// The task to complete: the live copy when it's still open, otherwise a stand-in from what was saved
    /// when it was picked. Without a known project type there's no safe status id, so nil.
    private func completable(_ ref: Ref, draft: EntryDraft) -> MoxieTask? {
        if var live = inbox.task(id: ref.id) {
            if live.projectTypeId == nil { live.projectTypeId = draft.currentTaskMeta?.projectTypeId }
            return live
        }
        guard let meta = draft.currentTaskMeta, let type = meta.projectTypeId else { return nil }
        return MoxieTask(id: ref.id, name: ref.name, projectId: draft.project?.id, status: nil, parentTaskId: nil,
                         projectTypeId: type, assignedToList: meta.assignees)
    }
}

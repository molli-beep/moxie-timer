import AppKit
import Observation

/// What the user has chosen to work on right now.
struct FocusTarget: Codable, Equatable {
    var name: String
    var taskId: String?
    var ticketId: String?
    var projectTypeId: String?
    var clientName: String?
    var projectName: String?
    var due: String?
    var firstStep: String = ""

    var context: String {
        [clientName, projectName].compactMap { $0 }.joined(separator: " · ")
    }
}

/// One focus block and the break that follows it.
struct FocusBlock: Codable, Equatable {
    enum Phase: String, Codable {
        case warmup, focus, breakDue, onBreak, breakOver
    }

    var phase: Phase
    /// Planned focus length, including the warm-up.
    var length: TimeInterval
    var startedAt: Date
    var phaseEndsAt: Date
    var breakLength: TimeInterval
    var snoozed = false
    var pausedAt: Date?

    var isWorking: Bool { phase == .warmup || phase == .focus }

    func remaining(at now: Date) -> TimeInterval {
        max(0, phaseEndsAt.timeIntervalSince(pausedAt ?? now))
    }

    /// 0…1 progress through the current phase, for the ring.
    func progress(at now: Date) -> Double {
        let total: TimeInterval
        switch phase {
        case .warmup: total = FocusStore.warmupLength
        case .focus: total = snoozed ? FocusStore.snoozeLength : length
        case .onBreak: total = breakLength
        case .breakDue, .breakOver: return 1
        }
        guard total > 0 else { return 1 }
        return min(max(1 - remaining(at: now) / total, 0), 1)
    }

    mutating func shift(by delta: TimeInterval) {
        startedAt += delta
        phaseEndsAt += delta
    }
}

/// Drives one-thing mode: warm-up → focus block → break (with one snooze) → back to work.
/// Block length adapts: +5 min after a completed block, −5 after one abandoned before halfway.
@MainActor @Observable
final class FocusStore {
    nonisolated static let warmupLength: TimeInterval = 5 * 60
    nonisolated static let snoozeLength: TimeInterval = 5 * 60
    static let presetMinutes = [15, 25, 45, 90]

    private struct Persisted: Codable {
        var target: FocusTarget?
        var block: FocusBlock?
        var suggestedMinutes: Int
    }

    var target: FocusTarget? { didSet { persist() } }
    private(set) var block: FocusBlock? {
        didSet {
            persist()
            if oldValue?.phase != block?.phase || (oldValue == nil) != (block == nil) { onPhaseChange?() }
        }
    }
    private(set) var suggestedMinutes: Int { didSet { persist() } }
    var warmupEnabled: Bool {
        didSet { UserDefaults.standard.set(warmupEnabled, forKey: "focusWarmup") }
    }

    /// Short-lived messages for the Focus tab.
    var banner: String?
    var pickReason: String?
    var lastError: String?
    private(set) var isFinishing = false

    @ObservationIgnored var onPhaseChange: (() -> Void)?
    /// Called after a task is finished or completed, so other systems (Notion sync) can catch up.
    @ObservationIgnored var onTaskChanged: (() -> Void)?
    @ObservationIgnored private let timer: TimerStore
    @ObservationIgnored private let inbox: TaskInbox
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private let storageKey = "focusState"

    @ObservationIgnored private let stats: StatsStore

    init(timer: TimerStore, inbox: TaskInbox, stats: StatsStore) {
        self.timer = timer
        self.inbox = inbox
        self.stats = stats
        warmupEnabled = UserDefaults.standard.object(forKey: "focusWarmup") as? Bool ?? true
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let state = try? JSONDecoder().decode(Persisted.self, from: data) {
            target = state.target
            block = state.block
            suggestedMinutes = state.suggestedMinutes
        } else {
            suggestedMinutes = 25
        }

        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    /// Set by the app: true while on a call. The break screen never covers a call; a due break waits until it ends.
    @ObservationIgnored var isInCall: () -> Bool = { false }

    var needsOverlay: Bool {
        guard let phase = block?.phase, !isInCall() else { return false }
        return phase == .breakDue || phase == .onBreak || phase == .breakOver
    }

    var isPaused: Bool { block?.pausedAt != nil }

    // MARK: Choosing what to work on

    /// Switches focus to a Moxie task. Any running time is saved first so it isn't misattributed.
    func select(_ task: MoxieTask) async {
        guard await saveRunningTimeBeforeSwitching() else { return }
        var draft = timer.draft
        draft.client = task.clientRef
        draft.notes = ""
        if let ticketId = task.sourceTicketId {
            // Tickets have no project: reuse the last project logged for this client (changeable in Timer/Review).
            draft.project = draft.client.flatMap { timer.lastProject(forClient: $0.id) }
            draft.task = nil
            draft.ticket = Ref(id: ticketId, name: task.name)
        } else {
            draft.project = task.projectRef
            draft.task = Ref(id: task.id, name: task.name)
            draft.taskMeta = EntryDraft(task: task).taskMeta
            draft.ticket = nil
        }
        target = FocusTarget(
            name: task.name, taskId: task.isTicket ? nil : task.id, ticketId: task.sourceTicketId,
            projectTypeId: task.projectTypeId,
            clientName: task.client?.name, projectName: draft.project?.name, due: task.dueDate
        )
        timer.draft = draft
        pickReason = nil
        inbox.clearJustAdded(task.id)
    }

    /// Focus on something that isn't a Moxie task. Client/project are picked in the Timer tab.
    func select(freeform name: String) async {
        guard await saveRunningTimeBeforeSwitching() else { return }
        target = FocusTarget(name: name)
        timer.draft.task = nil
        timer.draft.notes = name
        pickReason = nil
    }

    func clearTarget() {
        guard block == nil else { return }
        target = nil
        pickReason = nil
    }

    private func saveRunningTimeBeforeSwitching() async -> Bool {
        guard timer.session != nil else { return true }
        guard timer.canSaveCurrent else {
            // Nothing to save against yet — the running time simply carries over to the new task.
            return true
        }
        let previous = timer.draft.task?.name ?? timer.draft.project?.name ?? "previous work"
        let elapsed = timer.session?.elapsed(at: .now) ?? 0
        block = nil
        await timer.stopAndSave()
        if let error = timer.lastError {
            lastError = "Couldn't save the previous time: \(error)"
            return false
        }
        banner = timer.holdsForReview
            ? "Held \(DurationFormat.short(elapsed)) on “\(previous)” for review before switching."
            : "Saved \(DurationFormat.short(elapsed)) on “\(previous)” to Moxie before switching."
        return true
    }

    // MARK: Blocks

    /// Turns the running plain timer into a focus block on the same work, keeping the tracked time.
    func startFromTimer() {
        guard block == nil, timer.session != nil else { return }
        if target == nil {
            let draft = timer.draft
            let notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            target = FocusTarget(
                name: draft.task?.name ?? (notes.isEmpty ? (draft.project?.name ?? "Current work") : notes),
                taskId: draft.task?.id,
                clientName: draft.client?.name,
                projectName: draft.project?.name
            )
        }
        startBlock(minutes: suggestedMinutes, warmup: false)
    }

    func startBlock(minutes: Int, warmup: Bool? = nil) {
        let length = TimeInterval(max(minutes, 5) * 60)
        let now = Date.now
        let useWarmup = (warmup ?? warmupEnabled) && length > Self.warmupLength
        if timer.session == nil { timer.start() } else { timer.resume() }
        block = FocusBlock(
            phase: useWarmup ? .warmup : .focus,
            length: length,
            startedAt: now,
            phaseEndsAt: now.addingTimeInterval(useWarmup ? Self.warmupLength : length),
            breakLength: Self.breakLength(for: length)
        )
        banner = nil
    }

    func pauseBlock() {
        guard var current = block, current.pausedAt == nil, current.isWorking else { return }
        current.pausedAt = .now
        block = current
        timer.pause()
    }

    func resumeBlock() {
        guard var current = block, let pausedAt = current.pausedAt else { return }
        current.shift(by: Date.now.timeIntervalSince(pausedAt))
        current.pausedAt = nil
        block = current
        timer.resume()
    }

    /// Stops the block without finishing the task. The tracked time stays in the Timer tab.
    /// Adds the focus time of a block that ends early (completed blocks are counted when they complete).
    private func recordUnfinished(_ current: FocusBlock) {
        guard current.isWorking else { return }
        let worked = max(0, (current.pausedAt ?? .now).timeIntervalSince(current.startedAt))
        // A snoozed block was already counted in full; only the snooze minutes are extra.
        let extra = current.snoozed ? max(0, worked - current.length) : worked
        if extra > 0 { stats.record { $0.focusSeconds += extra } }
    }

    func stopBlock() {
        guard let current = block else { return }
        recordUnfinished(current)
        let worked = (current.pausedAt ?? .now).timeIntervalSince(current.startedAt)
        if current.isWorking, !current.snoozed, worked < current.length / 2 {
            adapt(completed: false, length: current.length)
        }
        block = nil
        timer.pause()
    }

    /// Saves the running time but keeps the task as "Up next" to continue later.
    func saveForLater() async {
        guard !isFinishing else { return }
        isFinishing = true
        defer { isFinishing = false }
        if let current = block { recordUnfinished(current) }
        block = nil
        let worked = timer.session?.elapsed(at: .now) ?? 0
        guard timer.session != nil else { return }
        await timer.stopAndSave()
        if let error = timer.lastError {
            lastError = error
            return
        }
        banner = "Saved \(DurationFormat.short(worked)) — “\(target?.name ?? "task")” stays up next."
    }

    /// Finishes the work: saves the time, clears it from "Up next" and counts it as done.
    /// With `closeInMoxie` the task is also completed (or the ticket closed) in Moxie; otherwise Moxie is untouched.
    /// What happens to the task when you finish working on it.
    enum TaskOutcome: Equatable {
        /// Complete it in Moxie (close a ticket); Notion follows with "Done".
        case done
        /// Leave it open everywhere; only the time is saved.
        case keepOpen
        /// Set a status (a Notion status name, e.g. "Waiting on Client"). Moxie gets the same stage when its
        /// project type has one with that label.
        case status(String)
    }

    /// The task just finished, kept for the quick actions under the celebration banner.
    struct FinishedTask: Equatable {
        var name: String
        var taskId: String?
        var client: Ref?
        var project: Ref?
    }

    private(set) var lastFinished: FinishedTask?
    /// Called with (Moxie task id, status name) when the user picks a status at finish time.
    @ObservationIgnored var onStatusChosen: ((String, String) -> Void)?

    func clearBanner() {
        banner = nil
        lastFinished = nil
    }

    func finish(outcome: TaskOutcome) async {
        let markComplete = outcome == .done
        guard !isFinishing else { return }
        isFinishing = true
        defer { isFinishing = false }
        let finishedTarget = target
        let focused = timer.session?.elapsed(at: .now) ?? 0
        if let current = block { recordUnfinished(current) }
        block = nil

        if timer.session != nil {
            await timer.stopAndSave()
            if let error = timer.lastError {
                lastError = error
                return
            }
        }

        var message: String
        switch outcome {
        case .done: message = "Nice work — “\(finishedTarget?.name ?? "task")” done"
        case .keepOpen: message = "Saved — “\(finishedTarget?.name ?? "task")” stays open"
        case let .status(name): message = "“\(finishedTarget?.name ?? "task")” → \(name)"
        }
        if focused >= 60 { message += " after \(DurationFormat.short(focused)) of focus" }
        message += "."
        if case let .status(name) = outcome, let taskId = finishedTarget?.taskId {
            onStatusChosen?(taskId, name)
            let task = inbox.tasks.first { $0.id == taskId }
                ?? MoxieTask(id: taskId, name: finishedTarget?.name ?? "", projectId: nil, status: nil, parentTaskId: nil,
                             projectTypeId: finishedTarget?.projectTypeId)
            if let matched = try? await inbox.setStage(task, label: name) {
                message += matched ? " Moxie updated ✓" : " (Moxie has no “\(name)” stage, so it stays as is there.)"
            }
        }
        if markComplete, let ticketId = finishedTarget?.ticketId {
            do {
                let confirmed = try await inbox.closeTicket(id: ticketId)
                message += confirmed ? " Ticket closed in Moxie ✓" : " Moxie didn't confirm the ticket status — check the ticket."
            } catch {
                lastError = "Time saved, but closing the ticket failed: \(error.localizedDescription)"
            }
        } else if markComplete, let taskId = finishedTarget?.taskId {
            let task = inbox.tasks.first { $0.id == taskId }
                ?? MoxieTask(id: taskId, name: finishedTarget?.name ?? "", projectId: nil, status: nil, parentTaskId: nil,
                             projectTypeId: finishedTarget?.projectTypeId)
            do {
                let confirmed = try await inbox.markComplete(task)
                message += confirmed ? " Marked complete in Moxie ✓" : " Moxie didn't confirm the status change — check the task."
            } catch {
                lastError = "Time saved, but marking the task complete failed: \(error.localizedDescription)"
            }
        }
        if markComplete { stats.record { $0.tasksDone += 1 } }
        let inboxTask = finishedTarget?.taskId.flatMap { id in inbox.tasks.first { $0.id == id } }
        target = nil
        banner = message
        lastFinished = finishedTarget.map {
            FinishedTask(name: $0.name, taskId: $0.taskId,
                         client: inboxTask?.clientRef ?? timer.draft.client,
                         project: inboxTask?.projectRef ?? timer.draft.project)
        }
        if markComplete { NSSound(named: "Hero")?.play() }
        onTaskChanged?()
    }

    /// Completes a task (or closes a ticket) straight from a list, without focusing on it.
    func complete(_ task: MoxieTask) async {
        do {
            let confirmed: Bool
            if let ticketId = task.sourceTicketId {
                confirmed = try await inbox.closeTicket(id: ticketId)
            } else {
                confirmed = try await inbox.markComplete(task)
            }
            stats.record { $0.tasksDone += 1 }
            if target?.taskId == task.id || (task.sourceTicketId != nil && target?.ticketId == task.sourceTicketId), block == nil {
                target = nil
            }
            banner = confirmed
                ? "“\(task.name)” \(task.isTicket ? "closed" : "marked complete") in Moxie ✓"
                : "Sent to Moxie, but it didn't confirm “\(task.name)” — check it there."
            NSSound(named: "Hero")?.play()
            onTaskChanged?()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Breaks

    func startBreak() {
        guard var current = block else { return }
        timer.pause()
        current.phase = .onBreak
        current.phaseEndsAt = Date.now.addingTimeInterval(current.breakLength)
        current.pausedAt = nil
        block = current
    }

    /// One snooze per block; after that the break overlay stays.
    func snoozeBreak() {
        guard var current = block, current.phase == .breakDue, !current.snoozed else { return }
        current.phase = .focus
        current.snoozed = true
        current.phaseEndsAt = Date.now.addingTimeInterval(Self.snoozeLength)
        block = current
    }

    /// Emergency exit: keep working without a break; a fresh block starts right away.
    func skipBreak() {
        startBlock(minutes: suggestedMinutes, warmup: false)
    }

    func endBreakEarly() {
        guard var current = block, current.phase == .onBreak else { return }
        current.phase = .breakOver
        current.phaseEndsAt = .distantFuture
        block = current
    }

    func backToWork() {
        startBlock(minutes: suggestedMinutes, warmup: false)
    }

    /// From the break-over screen: stop focusing for now and keep the time (paused) in the Timer tab.
    func doneForNow() {
        block = nil
    }

    // MARK: Idle

    /// Time discarded by the idle prompt shouldn't count toward the block either.
    func discardIdle(_ duration: TimeInterval) {
        guard var current = block, current.isWorking else { return }
        current.shift(by: duration)
        block = current
    }

    // MARK: Clock

    private func tick() {
        guard var current = block else { return }
        // The timer was stopped or discarded elsewhere (Timer tab, menu bar): the block ends with it.
        if current.isWorking, timer.session == nil {
            block = nil
            return
        }
        guard current.pausedAt == nil, Date.now >= current.phaseEndsAt else { return }

        switch current.phase {
        case .warmup:
            current.phase = .focus
            current.phaseEndsAt = current.startedAt.addingTimeInterval(current.length)
            banner = "Warm-up done — you're in. Keep going."
            NSSound(named: "Tink")?.play()
        case .focus:
            if !current.snoozed {
                adapt(completed: true, length: current.length)
                let length = current.length
                stats.record {
                    $0.blocksCompleted += 1
                    $0.focusSeconds += length
                }
            }
            current.phase = .breakDue
            current.phaseEndsAt = .distantFuture
            NSSound(named: "Glass")?.play()
        case .onBreak:
            current.phase = .breakOver
            current.phaseEndsAt = .distantFuture
            NSSound(named: "Glass")?.play()
        case .breakDue, .breakOver:
            return
        }
        block = current
    }

    private func adapt(completed: Bool, length: TimeInterval) {
        let minutes = Int(length / 60)
        suggestedMinutes = completed ? min(90, minutes + 5) : max(15, minutes - 5)
    }

    static func breakLength(for length: TimeInterval) -> TimeInterval {
        max(3, (length / 60 / 5).rounded()) * 60
    }

    private func persist() {
        let state = Persisted(target: target, block: block, suggestedMinutes: suggestedMinutes)
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

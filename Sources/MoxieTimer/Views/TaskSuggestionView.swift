import SwiftUI

/// Word-overlap matching between what you typed in Notes and your open Moxie tasks. Cheap and instant;
/// the AI step is only asked when this finds nothing convincing.
enum TaskMatch {
    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "into", "onto", "that", "this", "then", "than", "about", "some", "more",
        "work", "working", "worked", "on", "to", "of", "a", "an", "in", "at", "by", "it", "its", "my", "our", "their",
        "was", "were", "did", "done", "doing", "do", "get", "got", "making", "made", "make", "stuff", "things", "thing",
        "task", "tasks", "new", "re", "up", "out", "all", "just", "also", "again", "still", "today",
    ]

    /// Lower-cased, de-pluralised words of three letters or more, minus filler.
    static func words(_ text: String) -> Set<String> {
        let parts = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(parts.compactMap { word -> String? in
            guard word.count >= 3, !stopWords.contains(word) else { return nil }
            return stem(word)
        })
    }

    private static func stem(_ word: String) -> String {
        for suffix in ["ing", "ed", "es", "s"] where word.count > suffix.count + 3 && word.hasSuffix(suffix) {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    /// 0…1: how much of the task's name the note covers, with a little credit for client/project words.
    static func score(notes: Set<String>, task: MoxieTask) -> Double {
        let name = words(task.name)
        guard !notes.isEmpty, !name.isEmpty else { return 0 }
        func hits(_ target: Set<String>) -> Int {
            target.filter { word in
                notes.contains(word) || notes.contains { note in
                    note.count >= 4 && word.count >= 4 && (note.hasPrefix(word) || word.hasPrefix(note))
                }
            }.count
        }
        let nameHits = hits(name)
        guard nameHits > 0 else { return 0 }
        let context = words([task.client?.name, task.project?.name].compactMap { $0 }.joined(separator: " "))
        let coverage = Double(nameHits) / Double(name.count)
        let precision = Double(nameHits) / Double(notes.count)
        return min(1, 0.65 * coverage + 0.25 * precision + (hits(context) > 0 ? 0.1 : 0))
    }

    static func ranked(notes: String, tasks: [MoxieTask]) -> [(task: MoxieTask, score: Double)] {
        let noteWords = words(notes)
        return tasks.map { (task: $0, score: score(notes: noteWords, task: $0)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
    }
}

/// Under Notes: "Is this “Update onboarding emails”?" with Yes / No, so you don't have to dig through the
/// task list. Shown while no task (or ticket) is chosen; picking Yes fills in client, project and task.
struct TaskSuggestionView: View {
    @Binding var draft: EntryDraft
    @Environment(TaskInbox.self) private var inbox
    @Environment(AIService.self) private var ai
    @Environment(Catalog.self) private var catalog
    @Environment(AppSettings.self) private var settings

    private struct Suggestion: Equatable {
        let task: MoxieTask
        let reason: String?
        let byAI: Bool
    }

    @State private var suggestion: Suggestion?
    @State private var thinking = false
    @State private var rejected: Set<String> = []
    /// Notes text the user said "not a task" for; no more suggestions until it changes meaningfully.
    @State private var silencedFor: String?

    private var notes: String { draft.notes.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var active: Bool {
        settings.suggestTaskFromNotes && draft.task == nil && draft.ticket == nil && notes.count >= 4
            && silencedFor.map { !notes.hasPrefix($0) } != false
    }

    /// Re-run whenever what we'd match against changes.
    private var key: String {
        [notes, draft.client?.id ?? "", draft.project?.id ?? "", draft.task?.id ?? "", draft.ticket?.id ?? "",
         rejected.sorted().joined(separator: ","), active ? "1" : "0"].joined(separator: "|")
    }

    var body: some View {
        Group {
            if active, let suggestion {
                card(suggestion)
            } else if active, thinking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Looking for the matching task…").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 4)
            }
        }
        .task(id: key) { await refresh() }
    }

    private func card(_ suggestion: Suggestion) -> some View {
        let task = suggestion.task
        let context = [task.client?.name, task.project?.name].compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: suggestion.byAI ? "sparkles" : "link")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.navy)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    (Text("Is this ").foregroundStyle(Theme.muted) + Text("“\(task.name)”").bold() + Text("?").foregroundStyle(Theme.muted))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if !context.isEmpty {
                        Text(context).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    if let reason = suggestion.reason, !reason.isEmpty {
                        Text(reason).font(.system(size: 10)).foregroundStyle(Theme.faint).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Button("Yes, link it") { accept(task) }
                    .buttonStyle(ChipButtonStyle())
                Button("No, another") {
                    rejected.insert(task.id)
                    self.suggestion = nil
                }
                .buttonStyle(ChipButtonStyle())
                .help("Suggest a different task")
                Spacer(minLength: 0)
                Button("Not a task") {
                    silencedFor = notes
                    self.suggestion = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .help("Stop suggesting for this note")
            }
            .font(.system(size: 11))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.navy.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.navy.opacity(0.18)))
        .padding(.vertical, 6)
    }

    private func accept(_ task: MoxieTask) {
        // Set all three directly: setClient/setProject would clear the fields below them.
        draft.client = task.clientRef ?? draft.client
        draft.project = task.projectRef ?? draft.project
        draft.task = Ref(id: task.id, name: task.name)
        suggestion = nil
        rejected = []
        if let client = draft.client { Task { await catalog.loadProjects(for: client) } }
        if let project = draft.project { Task { await catalog.loadTasks(for: project) } }
    }

    private func refresh() async {
        guard active else {
            suggestion = nil
            thinking = false
            return
        }
        // Wait for typing to settle; a new keystroke cancels this run.
        try? await Task.sleep(for: .milliseconds(900))
        guard !Task.isCancelled else { return }
        if inbox.tasks.isEmpty { await inbox.refreshIfStale() }

        let candidates = inbox.tasks.filter { task in
            guard !task.isTicket, !rejected.contains(task.id) else { return false }
            if let client = draft.client, task.clientRef?.id != client.id { return false }
            if let project = draft.project, task.projectRef?.id != project.id { return false }
            return true
        }
        guard !candidates.isEmpty else {
            suggestion = nil
            return
        }

        let ranked = TaskMatch.ranked(notes: notes, tasks: candidates)
        // A clear word match needs no AI.
        if let best = ranked.first, best.score >= 0.5 {
            suggestion = Suggestion(task: best.task, reason: nil, byAI: false)
            return
        }
        guard ai.hasEnabledEngine, TaskMatch.words(notes).count >= 1 else {
            suggestion = ranked.first.map { Suggestion(task: $0.task, reason: nil, byAI: false) }
            return
        }

        // Give the AI the closest word matches first, then the best-ranked rest, capped to keep it quick.
        let shortlist = Array((ranked.map { $0.task } + TaskInbox.ranked(candidates, now: .now)).uniqued(by: \.id).prefix(40))
        let lines = shortlist.map { task in
            let context = [task.client?.name, task.project?.name].compactMap { $0 }.joined(separator: " · ")
            return context.isEmpty ? task.name : "\(task.name) — \(context)"
        }
        suggestion = nil
        thinking = true
        defer { thinking = false }
        do {
            let match = try await ai.matchTask(notes: notes, candidates: lines)
            guard !Task.isCancelled else { return }
            if let match {
                suggestion = Suggestion(task: shortlist[match.index], reason: match.reason, byAI: true)
            } else {
                suggestion = ranked.first.map { Suggestion(task: $0.task, reason: nil, byAI: false) }
            }
        } catch {
            guard !Task.isCancelled else { return }
            suggestion = ranked.first.map { Suggestion(task: $0.task, reason: nil, byAI: false) }
        }
    }
}

private extension Array {
    func uniqued<Key: Hashable>(by key: (Element) -> Key) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert(key($0)).inserted }
    }
}

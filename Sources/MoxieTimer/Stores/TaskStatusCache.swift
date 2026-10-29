import Foundation

/// The "complete" task status for each Moxie project type (board). Status ids differ per type, so they are
/// looked up from Moxie's task stages and cached on disk in `task-statuses.json`.
///
/// Order of trust: a fresh lookup from Moxie, then the last good lookup (any age), then the seed entries in
/// the same file. The seed is written once with the workspace's known types and can be edited by hand; it is
/// only used when Moxie can't be reached or doesn't flag any stage as complete.
@MainActor
final class TaskStatusCache {
    struct Status: Codable, Hashable {
        var id: String
        var label: String
        /// Project type name, for people reading the file.
        var projectType: String?
        /// When Moxie last confirmed this; nil for seed entries.
        var fetched: Date? = nil
    }

    private struct Stored: Codable {
        /// Project type id ("default" when a task has none) → complete status.
        var complete: [String: Status] = [:]
        var seed: [String: Status] = [:]
    }

    /// Fallbacks for the Virtually Molli workspace, written to the file on first launch.
    static let seed: [String: Status] = [
        "69d304a3280bf7085964c585": Status(id: "ca16e594-8a4d-462c-bd01-1edf9e922891", label: "Done", projectType: "Client Build"),
        "69d529977a45eb131d9cb058": Status(id: "64b74037-758f-48d6-a6d8-6e3189bcb24c", label: "Done", projectType: "OBM Retainer"),
        "69d0666f280bf708596459ae": Status(id: "5133a5fd-eac7-417f-9290-abdc054de484", label: "Delivered", projectType: "Consult Calls"),
    ]

    /// How long a lookup is trusted before Moxie is asked again.
    private static let maxAge: TimeInterval = 24 * 3600

    private var stored = Stored()
    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MoxieTimer", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: "task-statuses.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL), let saved = try? Self.decoder.decode(Stored.self, from: data) {
            stored = saved
        }
        if stored.seed.isEmpty {
            stored.seed = Self.seed
            persist()
        }
    }

    /// The complete status for a project type, asking Moxie when the cache is missing or stale.
    func completeStatus(projectTypeId: String?, api: MoxieAPI) async throws -> Status {
        let key = Self.key(projectTypeId)
        if let cached = stored.complete[key], let fetched = cached.fetched, Date.now.timeIntervalSince(fetched) < Self.maxAge {
            return cached
        }
        do {
            let stages = try await api.taskStages(projectTypeId: projectTypeId)
            // Several stages can be flagged complete; the last one is the end of the board.
            if let done = stages.last(where: { $0.complete == true }) {
                let status = Status(id: done.id, label: done.label ?? "Done", projectType: stored.seed[key]?.projectType,
                                    fetched: .now)
                stored.complete[key] = status
                persist()
                return status
            }
        } catch {
            if let fallback = stored.complete[key] ?? stored.seed[key] { return fallback }
            throw error
        }
        if let fallback = stored.complete[key] ?? stored.seed[key] { return fallback }
        throw UpdateError("Couldn't find a “complete” status for this task's project type in Moxie.")
    }

    /// Forgets lookups so the next completion asks Moxie again (e.g. after editing a board's statuses).
    func clear() {
        stored.complete = [:]
        persist()
    }

    private static func key(_ projectTypeId: String?) -> String {
        guard let id = projectTypeId?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return "default" }
        return id
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

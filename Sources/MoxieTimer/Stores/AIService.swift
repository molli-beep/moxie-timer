import Foundation
import Observation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AIEngine: String, CaseIterable, Codable, Identifiable {
    case apple, ollama, claude, codex, gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "Apple on-device"
        case .ollama: return "Ollama"
        case .claude: return "Claude Code CLI"
        case .codex: return "Codex CLI"
        case .gemini: return "Gemini CLI"
        }
    }

    var detail: String {
        switch self {
        case .apple: return "Free, offline, private (macOS 26)"
        case .ollama: return "Local model via localhost:11434"
        case .claude: return "Uses your Claude subscription"
        case .codex: return "Uses your ChatGPT subscription"
        case .gemini: return "Uses your Google account"
        }
    }

    /// Command-line tool name for the subscription-backed engines.
    var executable: String? {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .gemini: return "gemini"
        default: return nil
        }
    }
}

/// Runs short prompts on whichever engine is enabled and available, in the user's order.
@MainActor @Observable
final class AIService {
    private(set) var order: [AIEngine]
    private(set) var enabled: Set<AIEngine>
    var ollamaModel: String {
        didSet { UserDefaults.standard.set(ollamaModel, forKey: "aiOllamaModel") }
    }
    private(set) var lastEngine: AIEngine?
    private(set) var isWorking = false

    @ObservationIgnored private var loginPath: String?

    init() {
        let defaults = UserDefaults.standard
        let savedOrder = (defaults.stringArray(forKey: "aiOrder") ?? []).compactMap(AIEngine.init(rawValue:))
        order = savedOrder + AIEngine.allCases.filter { !savedOrder.contains($0) }
        if let saved = defaults.stringArray(forKey: "aiEnabled") {
            enabled = Set(saved.compactMap(AIEngine.init(rawValue:)))
        } else {
            enabled = Set(AIEngine.allCases)
        }
        ollamaModel = defaults.string(forKey: "aiOllamaModel") ?? ""
    }

    var hasEnabledEngine: Bool { !enabled.isEmpty }

    func setEnabled(_ engine: AIEngine, _ on: Bool) {
        if on { enabled.insert(engine) } else { enabled.remove(engine) }
        UserDefaults.standard.set(enabled.map(\.rawValue), forKey: "aiEnabled")
    }

    func move(_ engine: AIEngine, by offset: Int) {
        guard let index = order.firstIndex(of: engine) else { return }
        let target = min(max(index + offset, 0), order.count - 1)
        order.remove(at: index)
        order.insert(engine, at: target)
        UserDefaults.standard.set(order.map(\.rawValue), forKey: "aiOrder")
    }

    // MARK: Prompts

    /// One concrete action under two minutes that gets the task started.
    func firstStep(task: String, context: String) async throws -> String {
        let reply = try await generate(
            instructions: """
            You help a person with ADHD get started on work. Reply with ONE concrete, physical first action that takes \
            under two minutes, in at most 12 words, imperative mood. No preamble, no quotes, no list.
            """,
            prompt: "Task: \(task)\n\(context)"
        )
        return Self.firstLine(reply)
    }

    /// Picks one candidate. Returns its index and a short reason.
    func pick(from candidates: [String]) async throws -> (index: Int, reason: String) {
        let numbered = candidates.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let reply = try await generate(
            instructions: """
            You help a person with ADHD decide what to work on right now. Prefer overdue or due-soon work, then high \
            priority, then quick wins that build momentum. Reply on one line exactly as: <number>|<reason in under 12 words>
            """,
            prompt: "Today is \(Date.now.formatted(date: .complete, time: .omitted)).\nTasks:\n\(numbered)"
        )
        let line = reply.split(separator: "\n").map(String.init).first { $0.contains("|") && $0.contains(where: \.isNumber) }
            ?? Self.firstLine(reply)
        let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let number = parts.first.flatMap({ Int($0.filter(\.isNumber)) }), (1...candidates.count).contains(number) else {
            throw UpdateError("The AI reply didn't name a task.")
        }
        return (number - 1, parts.count > 1 ? parts[1] : "")
    }

    /// Which task (if any) the person's note describes. Returns the candidate's index, or nil for "none of these".
    func matchTask(notes: String, candidates: [String]) async throws -> (index: Int, reason: String)? {
        let numbered = candidates.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let reply = try await generate(
            instructions: """
            Someone logged time with a short note. Decide which task from the list the note is about. Match on meaning, \
            not exact words (e.g. "fixed the welcome emails" matches "Update onboarding email sequence"). If none clearly \
            fits, answer 0. Reply on one line exactly as: <number>|<reason in under 10 words>
            """,
            prompt: "Note: \(notes)\nTasks (task — client · project):\n\(numbered)"
        )
        let line = reply.split(separator: "\n").map(String.init).first { $0.contains("|") && $0.contains(where: \.isNumber) }
            ?? Self.firstLine(reply)
        let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let number = parts.first.flatMap({ Int($0.filter(\.isNumber)) }) else {
            throw UpdateError("The AI reply didn't name a task.")
        }
        guard (1...candidates.count).contains(number) else { return nil }
        return (number - 1, parts.count > 1 ? parts[1] : "")
    }

    // MARK: Engines

    /// Runs on the enabled engines in the user's order. `preferring` is tried first even when it's switched off
    /// (used for the pet's daily line writing, which is worth a better model); the rest are the fallback.
    func generate(instructions: String, prompt: String, preferring preferred: AIEngine? = nil) async throws -> String {
        isWorking = true
        defer { isWorking = false }
        var failures: [String] = []
        let engines = (preferred.map { [$0] } ?? []) + order.filter { enabled.contains($0) && $0 != preferred }
        for engine in engines {
            do {
                let text = try await run(engine, instructions: instructions, prompt: prompt)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    lastEngine = engine
                    return text
                }
            } catch {
                failures.append("\(engine.title): \(error.localizedDescription)")
            }
        }
        throw UpdateError(failures.isEmpty ? "No AI engine is enabled (Settings → AI)." : "No AI engine answered.\n" + failures.joined(separator: "\n"))
    }

    /// Quick availability probe for Settings.
    func test(_ engine: AIEngine) async -> String {
        do {
            let reply = try await run(engine, instructions: "Reply with the single word: ready", prompt: "Are you there?")
            return "✓ " + Self.firstLine(reply)
        } catch {
            return "✗ " + error.localizedDescription
        }
    }

    private func run(_ engine: AIEngine, instructions: String, prompt: String) async throws -> String {
        switch engine {
        case .apple: return try await runApple(instructions: instructions, prompt: prompt)
        case .ollama: return try await runOllama(instructions: instructions, prompt: prompt)
        case .claude: return try await runCLI(engine, arguments: ["-p", "--model", "haiku"], prompt: instructions + "\n\n" + prompt)
        case .codex: return try await runCLI(engine, arguments: ["exec", "--skip-git-repo-check"], prompt: instructions + "\n\n" + prompt)
        case .gemini: return try await runCLI(engine, arguments: ["-p"], prompt: instructions + "\n\n" + prompt)
        }
    }

    private func runApple(instructions: String, prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                throw UpdateError("Apple Intelligence is off or unsupported — turn it on in System Settings.")
            }
            let session = LanguageModelSession(instructions: instructions)
            return try await session.respond(to: prompt).content
        }
        #endif
        throw UpdateError("Needs macOS 26 with Apple Intelligence.")
    }

    private func runOllama(instructions: String, prompt: String) async throws -> String {
        let base = URL(string: "http://localhost:11434")!
        var model = ollamaModel.trimmingCharacters(in: .whitespaces)
        if model.isEmpty {
            struct Tags: Decodable { struct Model: Decodable { let name: String }; let models: [Model] }
            let data: Data
            do {
                (data, _) = try await URLSession.shared.data(from: base.appending(path: "api/tags"))
            } catch {
                throw UpdateError("Ollama isn't running — open the Ollama app.")
            }
            guard let first = try JSONDecoder().decode(Tags.self, from: data).models.first?.name else {
                throw UpdateError("Ollama has no models installed (run `ollama pull llama3.2`).")
            }
            model = first
        }
        struct Request: Encodable { let model: String; let system: String; let prompt: String; let stream: Bool }
        struct Response: Decodable { let response: String }
        var request = URLRequest(url: base.appending(path: "api/generate"), timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(model: model, system: instructions, prompt: prompt, stream: false))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Ollama returned an error.") }
        return try JSONDecoder().decode(Response.self, from: data).response
    }

    private func runCLI(_ engine: AIEngine, arguments: [String], prompt: String) async throws -> String {
        guard let name = engine.executable else { throw UpdateError("Not a CLI engine.") }
        let path = await resolvedLoginPath()
        guard let binary = path.split(separator: ":").map({ "\($0)/\(name)" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw UpdateError("`\(name)` isn't installed or isn't on your shell PATH.")
        }
        return try await Self.execute(binary: binary, arguments: arguments + [prompt], path: path, timeout: 90)
    }

    /// GUI apps don't inherit the shell PATH, and these CLIs need it (most are Node scripts).
    func resolvedLoginPath() async -> String {
        if let loginPath { return loginPath }
        let marker = "__MOXIETIMER_PATH__"
        let output = (try? await Self.execute(
            binary: "/bin/zsh", arguments: ["-lic", "print -r -- \"\(marker)$PATH\""],
            path: "/usr/bin:/bin:/usr/sbin:/sbin", timeout: 15
        )) ?? ""
        let found = output.split(separator: "\n").last { $0.hasPrefix(marker) }.map { String($0.dropFirst(marker.count)) }
        let path = found ?? "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:/usr/bin:/bin"
        loginPath = path
        return path
    }

    private nonisolated static func execute(binary: String, arguments: [String], path: String, timeout: TimeInterval) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = path
            process.environment = environment
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice
            try process.run()

            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()

            guard process.terminationStatus == 0 else {
                let message = String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw UpdateError(message.isEmpty ? "Exited with status \(process.terminationStatus)." : String(message.suffix(200)))
            }
            return String(decoding: output, as: UTF8.self)
        }.value
    }

    private static func firstLine(_ text: String) -> String {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // CLIs sometimes print banners first; the answer is the last non-empty line.
        let line = lines.last ?? ""
        return line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*- "))
    }
}

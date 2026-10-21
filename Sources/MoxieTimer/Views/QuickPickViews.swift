import SwiftUI

/// "What are you working on?" — one-click client/project choices shown when a timer is running with no
/// client yet. The chips are the combinations logged most often in the last 60 days, so the regulars
/// (a retainer client, a current build) are always one click away. The full pickers stay underneath.
struct QuickPickStrip: View {
    @Environment(TimerStore.self) private var timer
    @Environment(HistoryStore.self) private var history
    @Environment(Catalog.self) private var catalog
    @Environment(WidgetUI.self) private var ui
    @Environment(FocusStore.self) private var focus

    private struct Choice: Hashable, Identifiable {
        let client: Ref
        let project: Ref?
        var id: String { client.id + "/" + (project?.id ?? "") }
        var title: String { project.map { "\(client.name) · \($0.name)" } ?? client.name }
    }

    var body: some View {
        let choices = popular
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("What are you working on?")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button {
                    ui.askWhatNow = false
                    ui.route = .tasks
                } label: {
                    Label("Pick a task", systemImage: "list.bullet")
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.navy)
                .help("Choose from Up next; the timer keeps running")
            }

            // The task already lined up in Focus, and whatever the timer is set to now, come first.
            HStack(spacing: 6) {
                if let target = focus.target, focus.block == nil {
                    Button {
                        ui.askWhatNow = false
                        focus.startFromTimer()
                        ui.tab = .focus
                    } label: {
                        Label("Focus: \(target.name)", systemImage: "scope").lineLimit(1)
                    }
                    .buttonStyle(ChipButtonStyle())
                    .help("Turn this timer into a focus block on \(target.name)")
                }
                if let client = timer.draft.client {
                    Button {
                        ui.askWhatNow = false
                    } label: {
                        Label("Keep: \(client.name)\(timer.draft.project.map { " · \($0.name)" } ?? "")", systemImage: "checkmark").lineLimit(1)
                    }
                    .buttonStyle(ChipButtonStyle())
                    .help("Carry on with what the timer is already set to")
                }
            }

            if choices.isEmpty {
                Text("Your most-used clients and projects will show here once you've logged a few entries. Choose below for now.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(choices) { choice in
                        Button {
                            timer.draft.setClient(choice.client)
                            if let project = choice.project { timer.draft.setProject(project) }
                            ui.askWhatNow = false
                            Task { await catalog.loadProjects(for: choice.client) }
                        } label: {
                            HStack(spacing: 5) {
                                ClientAvatar(name: choice.client.name, size: 16)
                                Text(choice.title).lineLimit(1)
                            }
                        }
                        .buttonStyle(ChipButtonStyle())
                        .help("Log this time to \(choice.title)")
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.navy.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.navy.opacity(0.15)))
    }

    /// Client/project pairs ranked by how often they were logged recently, most recent first on ties.
    private var popular: [Choice] {
        let cutoff = Date.now.addingTimeInterval(-60 * 86_400)
        var counts: [Choice: (count: Int, last: Date)] = [:]
        for entry in history.entries where entry.start >= cutoff {
            guard let client = entry.draft.client else { continue }
            let choice = Choice(client: client, project: entry.draft.project)
            let current = counts[choice] ?? (0, .distantPast)
            counts[choice] = (current.count + 1, max(current.last, entry.start))
        }
        return counts
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.value.last > $1.value.last }
            .prefix(6)
            .map(\.key)
    }
}

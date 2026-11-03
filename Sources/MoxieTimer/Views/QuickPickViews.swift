import SwiftUI

/// "What are you working on?" — shown under the clock right after play. The task lined up in Focus is
/// offered (never assumed), then the client/project pairs logged most often in the last 60 days, then
/// Pick a task, Search clients and Decide later.
struct QuickPickStrip: View {
    /// Opens the full pickers.
    var onSearch: () -> Void

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
        VStack(alignment: .leading, spacing: 10) {
            Text("What are you working on?")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.ink)

            if let target = focus.target, focus.block == nil {
                Button {
                    ui.askWhatNow = false
                    focus.startFromTimer()
                    ui.tab = .focus
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "scope")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.navy)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(target.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            Text(upNextSubtitle(target))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text("Focus · \(focus.suggestedMinutes) min")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.navy)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.navy.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.navy.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Turn this timer into a focus block on the task lined up in Focus")
            }

            if !choices.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(choices) { choice in
                        Button {
                            timer.draft.setClient(choice.client)
                            if let project = choice.project { timer.draft.setProject(project) }
                            ui.askWhatNow = false
                            Task { await catalog.loadProjects(for: choice.client) }
                        } label: {
                            HStack(spacing: 6) {
                                ClientAvatar(name: choice.client.name, size: 20)
                                Text(choice.title).lineLimit(1)
                            }
                        }
                        .buttonStyle(QuickChipStyle())
                        .help("Log this time to \(choice.title)")
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    ui.askWhatNow = false
                    ui.route = .tasks
                } label: {
                    Label("Pick a task", systemImage: "list.bullet")
                }
                .buttonStyle(QuickChipStyle())
                .help("Choose from Up next; the timer keeps running")
                Button(action: onSearch) {
                    Label("Search clients…", systemImage: "magnifyingglass")
                }
                .buttonStyle(QuickChipStyle())
                .help("Open the full client, project and task pickers")
                Spacer()
                Button("Decide later") { ui.askWhatNow = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .help("Keep tracking; set the client before saving or in the end-of-day review")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.cream))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }

    private func upNextSubtitle(_ target: FocusTarget) -> String {
        var parts = ["Up next"]
        if let client = target.clientName, !client.isEmpty { parts.append(client) }
        if let due = target.due, let date = MoxieTask.dayFormatter.date(from: String(due.prefix(10))) {
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: date).day ?? 0
            switch days {
            case ..<0: parts.append("overdue")
            case 0: parts.append("due today")
            case 1: parts.append("due tomorrow")
            default: parts.append("due \(date.formatted(.dateTime.month(.abbreviated).day()))")
            }
        }
        return parts.joined(separator: " · ")
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

/// A white pill chip, a little taller than ChipButtonStyle so an avatar fits.
struct QuickChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.ink)
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .frame(height: 32)
            .background(Capsule().fill(configuration.isPressed ? Theme.pill : .white))
            .overlay(Capsule().strokeBorder(Theme.border))
            .contentShape(Capsule())
    }
}

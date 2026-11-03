import SwiftUI

/// A task's status as a small menu: pick To Do, In progress, Waiting on Client… and both Notion and Moxie
/// follow, without finishing the task or stopping the timer. Done completes it in Moxie (Notion → Done).
struct StatusMenu: View {
    let taskId: String
    let name: String
    let projectTypeId: String?
    /// Moxie's own status label, shown until Notion's is known.
    var fallback: String? = nil
    /// Dot only, for tight rows.
    var compact = false
    let onDone: () async -> Void

    @Environment(FocusStore.self) private var focus
    @Environment(AppSettings.self) private var settings
    @Environment(NotionSync.self) private var notion
    @State private var working = false

    private var current: String? { notion.status(for: taskId) ?? fallback }

    var body: some View {
        Menu {
            ForEach(settings.statusChoices, id: \.self) { status in
                Button {
                    run { await focus.setStatus(status, taskId: taskId, name: name, projectTypeId: projectTypeId) }
                } label: {
                    if current?.caseInsensitiveCompare(status) == .orderedSame {
                        Label(status, systemImage: "checkmark")
                    } else {
                        Text(status)
                    }
                }
            }
            Divider()
            Button {
                run(onDone)
            } label: {
                Label("Done", systemImage: "checkmark.circle")
            }
        } label: {
            HStack(spacing: 4) {
                if working {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(StatusMenu.color(for: current))
                }
                if !compact {
                    Text(current ?? "Set status")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(current == nil ? Theme.muted : Theme.ink)
                        .lineLimit(1)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(compact ? .hidden : .visible)
        .fixedSize()
        .disabled(working || taskId.hasPrefix("local-"))
        .help("Set the status in Notion and Moxie (doesn't stop the timer)")
    }

    private func run(_ work: @escaping () async -> Void) {
        working = true
        Task {
            await work()
            working = false
        }
    }

    static func color(for status: String?) -> Color {
        let name = (status ?? "").lowercased()
        if name.isEmpty || name == "to do" || name == "backlog" { return Theme.faint }
        if ["done", "delivered"].contains(name) { return Theme.running }
        if name == "cancelled" || name.contains("revise") { return Theme.danger }
        if name.contains("waiting") || name.contains("approval") { return Theme.onBreak }
        return Theme.warmup
    }
}

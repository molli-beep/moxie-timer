import SwiftUI

/// A task's Notion status, shown as a dot and label. Read-only: Status is set in Notion (Make carries it
/// to Moxie). The app changes it only on timer start (To Do → In progress) and when you press Done.
struct StatusMenu: View {
    let taskId: String
    /// Moxie's own status label, shown until Notion's is known.
    var fallback: String? = nil
    /// Dot only, for tight rows.
    var compact = false

    @Environment(NotionSync.self) private var notion

    private var current: String? { notion.status(for: taskId) ?? fallback }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(StatusMenu.color(for: current))
            if !compact {
                Text(current ?? "No status")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(current == nil ? Theme.muted : Theme.ink)
                    .lineLimit(1)
            }
        }
        .fixedSize()
        .help("Status in Notion: \(current ?? "not known yet"). Change it in Notion.")
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

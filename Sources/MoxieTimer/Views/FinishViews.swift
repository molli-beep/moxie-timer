import SwiftUI

/// The Finish button. Pressing it asks how the task should be updated (done, a status, or just save the
/// time) instead of finishing straight away. `trailing` is shown next to the button while it's collapsed.
struct FinishControl<Trailing: View>: View {
    let target: FocusTarget
    var primary: Bool
    @ViewBuilder var trailing: Trailing

    @Environment(FocusStore.self) private var focus
    @Environment(AppSettings.self) private var settings
    @Environment(TimerStore.self) private var timer
    @State private var choosing = false

    init(target: FocusTarget, primary: Bool, @ViewBuilder trailing: () -> Trailing) {
        self.target = target
        self.primary = primary
        self.trailing = trailing()
    }

    var body: some View {
        if choosing {
            chooser
        } else {
            HStack(spacing: 8) {
                trailing
                Button { choosing = true } label: {
                    Label("Finish", systemImage: "checkmark").lineLimit(1).frame(maxWidth: .infinity)
                }
                .modifier(FinishStyle(primary: primary))
                .disabled(focus.isFinishing)
                .help(timer.session != nil ? "Saves the running time, then asks how to update the task." : "Asks how to update the task.")
            }
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("How should “\(target.name)” be updated?")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Spacer()
                Button { choosing = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.muted)
            }
            if timer.session != nil {
                Text("The running time is saved first, whichever you pick.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
            }

            FlowLayout(spacing: 6) {
                outcomeButton(target.ticketId != nil ? "Done · close ticket" : "Done", icon: "checkmark", outcome: .done, filled: true)
                if target.ticketId == nil {
                    ForEach(settings.finishStatusList, id: \.self) { status in
                        outcomeButton(status, icon: nil, outcome: .status(status), filled: false)
                    }
                }
                outcomeButton("Just save the time", icon: "clock", outcome: .keepOpen, filled: false)
            }
            .disabled(focus.isFinishing)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cream))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }

    private func outcomeButton(_ title: String, icon: String?, outcome: FocusStore.TaskOutcome, filled: Bool) -> some View {
        Button {
            Task {
                await focus.finish(outcome: outcome)
                choosing = false
            }
        } label: {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
                Text(title)
            }
        }
        .modifier(FinishStyle(primary: filled, compact: true))
    }
}

extension FinishControl where Trailing == EmptyView {
    init(target: FocusTarget, primary: Bool) {
        self.init(target: target, primary: primary) { EmptyView() }
    }
}

/// Primary (navy) or chip (white) look for the finish buttons, in the standard or a compact height.
private struct FinishStyle: ViewModifier {
    var primary: Bool
    var compact = false

    func body(content: Content) -> some View {
        if primary {
            if compact {
                content.buttonStyle(CompactPrimaryButtonStyle())
            } else {
                content.buttonStyle(PrimaryButtonStyle())
            }
        } else {
            content.buttonStyle(ChipButtonStyle())
        }
    }
}

private struct CompactPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule().fill(Theme.navy.opacity(configuration.isPressed ? 0.85 : 1)))
            .contentShape(Capsule())
    }
}

/// Shortcuts offered right after a task is finished: a follow-up task with the same client and project,
/// or straight on to the next task.
struct QuickActionsRow: View {
    let finished: FocusStore.FinishedTask
    let onDone: () -> Void

    @Environment(WidgetUI.self) private var ui
    @Environment(TaskInbox.self) private var inbox

    var body: some View {
        HStack(spacing: 6) {
            Button {
                ui.captureSeed = .init(client: finished.client, project: finished.project)
                onDone()
                ui.route = .capture
            } label: {
                Label("Follow-up task", systemImage: "plus")
            }
            .help(finished.client.map { "New task for \($0.name)\(finished.project.map { " · \($0.name)" } ?? "")" } ?? "New task")

            Button {
                onDone()
                ui.route = .tasks
            } label: {
                Label("Pick next", systemImage: "arrow.right")
            }
            .help("Open Up next")

            if let client = finished.client {
                Button {
                    inbox.filterClient = client
                    if let project = finished.project { inbox.filterProject = project }
                    onDone()
                    ui.route = .tasks
                } label: {
                    Label("More for \(client.name)", systemImage: "line.3.horizontal.decrease")
                }
                .help("Up next, filtered to this client")
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(ChipButtonStyle())
        .font(.system(size: 11))
    }
}

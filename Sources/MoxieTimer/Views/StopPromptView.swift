import SwiftUI

/// Shown when Stop is pressed on a timer that's on a task: "Do you want to mark this as done?"
/// The time is frozen while it's open. Yes saves the entry with "Mark task done" ticked: in review mode it
/// waits in review with the box ticked; otherwise the time goes to Moxie, then the task is completed.
struct StopPromptView: View {
    @Environment(TimerStore.self) private var timer
    @Environment(FocusStore.self) private var focus
    @Environment(ReviewPusher.self) private var pusher
    @Environment(WidgetUI.self) private var ui

    @State private var confirmClient = false
    @State private var working = false
    @State private var error: String?
    /// Set once the entry is saved, so closing the card doesn't restart the timer.
    @State private var finished = false

    var body: some View {
        let draft = timer.draft
        let mayNotify = pusher.mayNotifyClient(draft)

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Do you want to mark this as done?")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                WindowDragArea().frame(maxWidth: .infinity, minHeight: 24)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(draft.task?.name ?? "This task")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                    if draft.currentTaskMeta?.clickUpURL != nil { ClickUpBadge() }
                }
                let context = [draft.client?.name, draft.project?.name].compactMap { $0 }.joined(separator: " · ")
                if !context.isEmpty {
                    Text(context).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                if let session = timer.session {
                    Text("Time on this entry: \(DurationFormat.short(session.elapsed(at: .now)))")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cream))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))

            if mayNotify {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Client may be notified: a client portal user is assigned to this task.", systemImage: "envelope.badge")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.onBreak)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Complete it anyway", isOn: $confirmClient)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                }
            }

            Text(timer.holdsForReview
                 ? "The time is held for review either way. Yes ticks “Mark task done”, so it's completed in Moxie when you send."
                 : "The time goes to Moxie now. Yes also moves the task to its project's complete status.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                ErrorBanner(message: error) { self.error = nil }
            }

            HStack(spacing: 8) {
                Button { keepTiming() } label: { Text("Keep timing").frame(maxWidth: .infinity) }
                    .buttonStyle(ChipButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button { Task { await finish(markDone: false) } } label: { Text("Not yet").frame(maxWidth: .infinity) }
                    .buttonStyle(ChipButtonStyle())
                    .help("Save the time and leave the task open")
                Button { Task { await finish(markDone: true) } } label: {
                    HStack(spacing: 6) {
                        if working { ProgressView().controlSize(.small).tint(.white) } else { Image(systemName: "checkmark") }
                        Text("Yes, mark done")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(mayNotify && !confirmClient)
            }
            .disabled(working)
        }
        .padding(16)
        // Closing the card any other way (Esc, a click outside) counts as "Keep timing".
        .onDisappear { if !finished { resumeTiming() } }
    }

    /// Cancel: the time picks up where it was frozen.
    private func keepTiming() {
        resumeTiming()
        ui.route = nil
        ui.collapse()
    }

    private func resumeTiming() {
        if focus.block?.pausedAt != nil { focus.resumeBlock() } else { timer.resume() }
    }

    private func finish(markDone: Bool) async {
        working = true
        defer { working = false }
        error = nil
        let mayNotify = pusher.mayNotifyClient(timer.draft)
        timer.draft.markTaskDone = markDone ? true : nil
        timer.draft.confirmClientNotice = markDone && mayNotify && confirmClient ? true : nil
        guard let entry = await timer.stopAndSave() else {
            error = timer.lastError ?? "Couldn't save the time."
            return
        }
        finished = true
        focus.clearTarget()
        if markDone, !timer.holdsForReview, let problem = await pusher.completeAfterStop(entry) {
            // The time is safe in Moxie; only completing the task didn't happen.
            timer.notice = problem
        }
        ui.route = nil
        ui.collapse()
    }
}

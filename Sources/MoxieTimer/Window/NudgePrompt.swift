import AppKit
import SwiftUI

/// The last step of the not-tracking reminder: a small prompt in the middle of the screen.
@MainActor
final class NudgePromptController {
    private var panel: NSPanel?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .aqua)

        let root = NudgePromptView { [weak self] in self?.hide() }
            .environment(model.activity)
            .environment(model.ui)
            .environment(model.pet)
            .environment(model.settings)
        let host = NSHostingView(rootView: root)
        panel.contentView = host
        let size = host.fittingSize
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2 + screen.height * 0.12,
                                  width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
        NSSound(named: "Ping")?.play()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct NudgePromptView: View {
    @Environment(ActivityWatcher.self) private var activity
    @Environment(WidgetUI.self) private var ui
    let close: () -> Void

    var body: some View {
        Group {
            if activity.promptKind == .drift {
                driftContent
            } else {
                notTrackingContent
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.onBreak.opacity(0.5), lineWidth: 1.5))
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .padding(30)
    }

    // MARK: Drifting to a distraction while the timer runs

    private var driftContent: some View {
        let minutes = max(1, Int((Date.now.timeIntervalSince(activity.driftSince ?? .now) / 60).rounded()))
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                PetView(size: 46, expression: .upset)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Back to “\(activity.currentTaskName)”?")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                    Text("You've been on \(activity.driftLabel ?? "something else") for \(minutes) min while the timer runs.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
            }

            Button {
                activity.backToWork(dropDrift: false)
                close()
            } label: { Text("Back to it").frame(maxWidth: .infinity) }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)

            HStack(spacing: 8) {
                Button {
                    activity.backToWork(dropDrift: true)
                    close()
                } label: { Text("Back, drop \(minutes) min").frame(maxWidth: .infinity) }
                    .buttonStyle(ChipButtonStyle())
                    .help("Return to work and remove the drifted time from the timer")
                Button {
                    activity.takeBreak()
                    close()
                } label: { Text("Take a break").frame(maxWidth: .infinity) }
                    .buttonStyle(ChipButtonStyle())
            }

            HStack {
                Button("It's for work — allow 15 min") {
                    activity.allowForWork()
                    close()
                }
                Spacer()
                Button("Switch task") {
                    activity.allowForWork()
                    close()
                    ui.tab = .focus
                    ui.onVisibilityRequest?(true)
                    ui.expand(route: .tasks)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.muted)
        }
    }

    // MARK: Working with no timer running

    private var notTrackingContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "stopwatch")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.onBreak)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Working on something?")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    if let since = activity.untrackedSince {
                        Text("You've been active since \(since.formatted(date: .omitted, time: .shortened)) with no timer running.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                    }
                }
            }

            if let suggestion = activity.suggestion {
                Button {
                    activity.startTracking(useSuggestion: true)
                    close()
                } label: {
                    VStack(spacing: 2) {
                        Text("Track \(suggestion.choice.label)").lineLimit(1)
                        Text("from \(activity.untrackedSince?.formatted(date: .omitted, time: .shortened) ?? "now") · \(suggestion.reason)")
                            .font(.system(size: 10, weight: .regular))
                            .opacity(0.8)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(PrimaryButtonStyle())
            }

            HStack(spacing: 8) {
                Button {
                    activity.startTracking(useSuggestion: false)
                    close()
                } label: { Text(activity.suggestion == nil ? "Start timer" : "Something else").frame(maxWidth: .infinity) }
                    .buttonStyle(activity.suggestion == nil ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(ChipButtonStyle()))
                Button {
                    activity.startTracking(useSuggestion: false)
                    close()
                    ui.tab = .timer
                    ui.onVisibilityRequest?(true)
                    ui.expand()
                } label: { Text("Choose…").frame(maxWidth: .infinity) }
                    .buttonStyle(ChipButtonStyle())
            }

            HStack {
                Button("Remind me in 10 min") {
                    activity.remindLater()
                    close()
                }
                Spacer()
                Button("Not working right now") {
                    activity.notWorking()
                    close()
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.muted)
        }
    }
}

/// Lets one button pick between two styles at runtime.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

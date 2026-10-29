import AppKit
import SwiftUI

/// Borderless, transparent panel that floats above other windows. It is non-activating so
/// clicking pause/stop doesn't steal focus from the app you're working in.
final class FloatingPanel: NSPanel {
    /// Called after the user drags the widget to a new spot.
    var onUserMoved: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        appearance = NSAppearance(named: .aqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the panel. The widget is anchored by its top-right corner so expanding the card
/// grows it downward from the pill, like the dropdown in the Moxie web app.
@MainActor
final class PanelController {
    let panel = FloatingPanel()
    private let model: AppModel
    private var anchor: NSPoint
    private var contentSize = CGSize(width: 320, height: 80)
    private let anchorKey = "panelAnchor"
    private let hiddenKey = "panelHidden"
    /// Hidden by "hide while a timer runs" rather than by the user; stopping the timer brings it back.
    private var autoHidden = false
    private var wasRunning = false
    private var wasExpanded = false

    init(model: AppModel) {
        self.model = model
        anchor = Self.defaultAnchor()
        if let saved = UserDefaults.standard.string(forKey: anchorKey) {
            let point = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }) { anchor = point }
        }

        let root = WidgetRoot { [weak self] size in self?.resize(to: size) }
            .environment(model.settings)
            .environment(model.history)
            .environment(model.catalog)
            .environment(model.timer)
            .environment(model.ui)
            .environment(model.clock)
            .environment(model.updater)
            .environment(model.ai)
            .environment(model.inbox)
            .environment(model.focus)
            .environment(model.idle)
            .environment(model.activity)
            .environment(model.stats)
            .environment(model.pet)
            .environment(model.voice)
            .environment(model.petLines)
            .environment(model.petSkills)
            .environment(model.calls)
            .environment(model.notion)
            .environment(model.pusher)

        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host
        panel.onUserMoved = { [weak self] in self?.userMovedPanel() }

        model.settings.onWindowPreferencesChange = { [weak self] in self?.applyPreferences() }
        model.ui.onVisibilityRequest = { [weak self] visible in self?.setVisible(visible) }
        applyPreferences()
        layout()
        // Come back the way the user left it; setup needs the widget, so it shows until Moxie is connected.
        if !UserDefaults.standard.bool(forKey: hiddenKey) || !model.settings.isConfigured {
            panel.orderFrontRegardless()
        }
        wasExpanded = model.ui.expanded
        observeAutoHide()

        // Clicks that go to other apps (desktop, Finder, browser…) close the open card, like a popover.
        // Global mouse monitors don't need Accessibility permission; clicks in our own windows aren't reported here.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleOutsideClick() }
        }
    }

    private var outsideClickMonitor: Any?

    private func handleOutsideClick() {
        guard model.settings.closeOnOutsideClick, model.ui.expanded, panel.isVisible,
              !panel.frame.contains(NSEvent.mouseLocation) else { return }
        model.ui.collapse()
    }

    var isVisible: Bool { panel.isVisible }

    func setVisible(_ visible: Bool) {
        autoHidden = false
        UserDefaults.standard.set(!visible, forKey: hiddenKey)
        if visible {
            panel.orderFrontRegardless()
        } else {
            model.ui.collapse()
            panel.orderOut(nil)
        }
    }

    func toggleVisible() {
        setVisible(!panel.isVisible)
    }

    // MARK: Hide while a timer runs

    /// Re-arms after every change to the timer, the card or the setting.
    private func observeAutoHide() {
        withObservationTracking {
            _ = model.timer.session
            _ = model.ui.expanded
            _ = model.settings.autoHideWhileRunning
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.observeAutoHide() }
            }
        }
        applyAutoHide()
    }

    /// Hides when a timer starts running or its card is closed while it runs, so the start picker and
    /// anything opened on purpose stay on screen. Brings the widget back when the timer is stopped.
    private func applyAutoHide() {
        let running = model.timer.session?.isRunning == true
        let expanded = model.ui.expanded
        defer {
            wasRunning = running
            wasExpanded = expanded
        }
        if model.timer.session == nil, autoHidden {
            autoHidden = false
            panel.orderFrontRegardless()
            return
        }
        guard model.settings.autoHideWhileRunning, running, !expanded, panel.isVisible else { return }
        let justStarted = !wasRunning
        let justClosed = wasExpanded
        guard justStarted || justClosed else { return }
        autoHidden = true
        panel.orderOut(nil)
    }

    func applyPreferences() {
        panel.level = model.settings.keepOnTop ? .floating : .normal
        var behavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        behavior.insert(model.settings.showOnAllSpaces ? .canJoinAllSpaces : .moveToActiveSpace)
        panel.collectionBehavior = behavior
    }

    func resetPosition() {
        anchor = Self.defaultAnchor()
        UserDefaults.standard.removeObject(forKey: anchorKey)
        layout()
    }

    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0, size != contentSize else { return }
        contentSize = size
        layout()
    }

    private func layout() {
        var frame = NSRect(
            x: anchor.x - contentSize.width,
            y: anchor.y - contentSize.height,
            width: contentSize.width,
            height: contentSize.height
        )
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.x - 1, y: anchor.y - 1)) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        panel.setFrame(frame, display: true)
    }

    private func userMovedPanel() {
        anchor = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        UserDefaults.standard.set(NSStringFromPoint(anchor), forKey: anchorKey)
        layout()
    }

    private static func defaultAnchor() -> NSPoint {
        let visible = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.maxX - 8, y: visible.maxY - 4)
    }
}

// MARK: - Drag handle

/// Transparent AppKit view that drags the window, or reports a click if the mouse didn't move.
struct WindowDragArea: NSViewRepresentable {
    var onClick: () -> Void = {}

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.onClick = onClick
    }

    final class DragView: NSView {
        var onClick: () -> Void = {}

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let startMouse = NSEvent.mouseLocation
            let startOrigin = window.frame.origin
            var dragged = false

            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp { break }
                let mouse = NSEvent.mouseLocation
                let dx = mouse.x - startMouse.x, dy = mouse.y - startMouse.y
                if !dragged, hypot(dx, dy) < 3 { continue }
                dragged = true
                window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
            }
            if dragged {
                (window as? FloatingPanel)?.onUserMoved?()
            } else {
                onClick()
            }
        }
    }
}

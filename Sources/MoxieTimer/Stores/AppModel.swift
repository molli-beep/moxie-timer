import AppKit
import Observation

/// Ticks once a second so every timer readout (widget + menu bar) stays live.
@MainActor @Observable
final class Clock {
    private(set) var now = Date()
    @ObservationIgnored private var timer: Timer?

    init() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

/// Which screen the expanded widget is showing.
@MainActor @Observable
final class WidgetUI {
    enum Tab { case focus, timer, recent, insights, pet }
    enum Route { case settings, addEntry, tasks, capture, review, pickTask }

    /// How the entry editor should open: blank, prefilled with a time range (filling a gap), or editing a held entry.
    struct EditorSeed {
        var start: Date?
        var end: Date?
        var editId: String?
        var returnTo: Route?
    }

    private(set) var expanded = false
    var tab: Tab = .focus
    var route: Route?
    var editorSeed: EditorSeed?
    /// Client/project the capture screen should start from (a follow-up to the task just finished).
    struct CaptureSeed {
        var client: Ref?
        var project: Ref?
    }
    var captureSeed: CaptureSeed?
    /// Set when play is pressed: the Timer tab asks "What are you working on?" until a choice is made.
    var askWhatNow = false
    /// Set by the panel controller; shows/hides the floating widget.
    @ObservationIgnored var onVisibilityRequest: ((Bool) -> Void)?

    func expand(route: Route? = nil) {
        self.route = route
        expanded = true
        NSApp.activate()
        NSApp.windows.first { $0 is FloatingPanel }?.makeKey()
    }

    func collapse() {
        expanded = false
        route = nil
    }

    func toggle() {
        expanded ? collapse() : expand()
    }
}

@MainActor
final class AppModel {
    static let shared = AppModel()

    let settings: AppSettings
    let history: HistoryStore
    let stats = StatsStore()
    let catalog: Catalog
    let timer: TimerStore
    let ui = WidgetUI()
    let clock = Clock()
    let updater = Updater()
    let ai = AIService()
    let voice: PetVoice
    let petSkills: PetSkillStore
    let petLines: PetLineLibrary
    let inbox: TaskInbox
    let focus: FocusStore
    let idle: IdleMonitor
    let activity: ActivityWatcher
    let pet: PetStore
    let calls: CallDetector
    let notion: NotionSync

    private init() {
        settings = AppSettings()
        history = HistoryStore()
        catalog = Catalog(settings: settings)
        timer = TimerStore(settings: settings, history: history)
        inbox = TaskInbox(settings: settings, catalog: catalog)
        focus = FocusStore(timer: timer, inbox: inbox, stats: stats)
        idle = IdleMonitor(timer: timer, focus: focus)
        activity = ActivityWatcher(settings: settings, timer: timer, focus: focus, history: history, stats: stats)
        voice = PetVoice(settings: settings, ai: ai)
        petSkills = PetSkillStore(settings: settings)
        petLines = PetLineLibrary(settings: settings, ai: ai, skills: petSkills)
        pet = PetStore(settings: settings, stats: stats, activity: activity, focus: focus, timer: timer, idle: idle, ai: ai,
                       voice: voice, library: petLines, skills: petSkills)
        calls = CallDetector(settings: settings)
        let calls = calls
        focus.isInCall = { calls.inCall }
        activity.isInCall = { calls.inCall }
        idle.isInCall = { calls.inCall }
        pet.isInCall = { calls.inCall }
        let inbox = inbox
        pet.taskDue = { id in inbox.tasks.first { $0.id == id }?.due }
        notion = NotionSync(settings: settings, history: history, catalog: catalog)
        let notion = notion
        // A finished task or a logged entry reaches Notion within seconds, not at the next scheduled sync.
        focus.onTaskChanged = { notion.requestSoon() }
        focus.onStatusChosen = { id, status in notion.setStatus(taskId: id, status: status) }
        timer.onEntrySent = { notion.requestSoon() }
    }
}

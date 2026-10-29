import Carbon.HIToolbox

/// A system-wide keyboard shortcut via Carbon's RegisterEventHotKey (no Accessibility permission needed).
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    /// Tells this shortcut's presses apart from the app's other hotkeys; every handler sees every press.
    private let id: UInt32

    /// Default capture shortcut: ⌃⌥Space.
    static let captureDescription = "⌃⌥Space"
    /// Show/hide the widget: ⌃⌥M.
    static let toggleDescription = "⌃⌥M"

    init?(id: UInt32 = 1, keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(controlKey | optionKey),
          action: @escaping () -> Void) {
        self.action = action
        self.id = id
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            guard read == noErr, pressed.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &eventType, selfPointer, &handlerRef)
        guard status == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D584D54), id: id) // "MXMT"
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

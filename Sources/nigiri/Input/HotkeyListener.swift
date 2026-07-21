import Carbon
import Foundation

// Registers global hotkeys via Carbon's RegisterEventHotKey/InstallEventHandler
// - the same tier of API System Settings' own Keyboard Shortcuts pane uses,
// one level below the fully-privileged symbolic hotkeys the WindowServer
// itself resolves. Deliberately NOT CGEventTap: that requires Input
// Monitoring permission (the same class of API a keylogger would use - a
// global tap on the raw keyboard stream), and ties trust to the exact signed
// binary. RegisterEventHotKey needs no special permission at all - it asks
// the OS "tell me when this exact combo fires" rather than watching
// everything, and only supports modifier+key combos (Cmd+Option+H, not an
// arbitrary held key acting as its own modifier).
final class HotkeyListener {
    struct Modifiers: OptionSet {
        let rawValue: UInt32
        static let command = Modifiers(rawValue: UInt32(cmdKey))
        static let option = Modifiers(rawValue: UInt32(optionKey))
        static let control = Modifiers(rawValue: UInt32(controlKey))
        static let shift = Modifiers(rawValue: UInt32(shiftKey))
    }

    // Per-INSTANCE signature, not a shared static: every listener installs
    // its handler on the same event dispatcher target, so all handlers see
    // ALL hotkey events. Without a signature check, listener B's id=1
    // fires listener A's id=1 action too (the overview's bare Escape was
    // triggering the main listener's focus-column-left - same id, shared
    // target). The handler now runs an action only for its OWN signature.
    private static var nextSignature: OSType = 0x4e494700  // 'NIG\0' base
    private let signature: OSType
    private var actions: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    init() {
        signature = Self.nextSignature
        Self.nextSignature += 1
    }

    // Returns false if this exact combo is already claimed by macOS or
    // another app (RegisterEventHotKey fails with eventHotKeyExistsErr
    // rather than silently stealing it) - callers should pick a different
    // combo rather than ignore this.
    @discardableResult
    func register(_ keyCode: CGKeyCode, modifiers: Modifiers, action: @escaping () -> Void) -> Bool {
        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var hotKeyRef: EventHotKeyRef?
        // options: 0, not kEventHotKeyExclusive - matches Magnet
        // (github.com/Clipy/Magnet), a real, maintained macOS window-snapping
        // app using this same API for letter-key hotkeys.
        let status = RegisterEventHotKey(
            UInt32(keyCode), modifiers.rawValue, hotKeyID,
            GetEventDispatcherTarget(), 0, &hotKeyRef
        )
        guard status == noErr, let hotKeyRef else {
            print(
                "[hotkey] RegisterEventHotKey failed for keyCode \(keyCode) mods \(modifiers.rawValue): OSStatus \(status)"
                    + (status == eventHotKeyExistsErr
                        ? " (already registered by macOS or another app - check System Settings > Keyboard Shortcuts)"
                        : ""))
            return false
        }
        actions[id] = action
        hotKeyRefs.append(hotKeyRef)
        return true
    }

    // Config live-reload re-registers every bind from scratch - without
    // this, each reload would LAYER a new registration over the old one
    // (same combo firing twice) and removed binds would never die.
    func unregisterAll() {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs = []
        actions = [:]
    }

    func start() -> Bool {
        // Idempotent: the overview calls this every time it opens, and each
        // InstallEventHandler overwrote `eventHandler` without removing the
        // previous one - a leaked handler, permanently installed on the
        // shared dispatcher target, per overview open.
        guard eventHandler == nil else { return true }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                // eventNotHandledErr, NOT noErr, whenever this handler does
                // not act: handlers on the shared dispatcher target run
                // newest-first, and returning noErr means "handled - stop".
                // A second listener (the overview's Escape/Enter) therefore
                // swallowed every OTHER listener's hotkeys the moment it
                // installed itself: all 74 config binds died, silently, the
                // first time the overview opened. Verified live - the
                // overview still opened through the control FIFO while
                // Mod+Tab did nothing.
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard err == noErr else { return OSStatus(eventNotHandledErr) }
                // C function pointers are implicitly @Sendable; the Carbon
                // event dispatcher delivers on the main thread, so state
                // that here once instead of requiring every registered
                // action closure to be Sendable.
                let id = hotKeyID.id
                let sig = hotKeyID.signature
                return MainActor.assumeIsolated {
                    let listener = Unmanaged<HotkeyListener>.fromOpaque(userData).takeUnretainedValue()
                    // Only OUR own hotkeys - every listener's handler sees
                    // every listener's events on the shared target; anything
                    // else has to be handed on to the next handler.
                    guard sig == listener.signature, let action = listener.actions[id] else {
                        return OSStatus(eventNotHandledErr)
                    }
                    action()
                    return noErr
                }
            },
            1, &eventType, selfPtr, &eventHandler
        )
        return status == noErr
    }
}

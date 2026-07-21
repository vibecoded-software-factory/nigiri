import AppKit

// Mod+drag: interactive mouse move/reorder (left button) and resize
// (right button) of managed windows - niri's Mod+drag, via a MOUSE-ONLY
// CGEventTap.
//
// Deliberate scope note: HotkeyListener refuses CGEventTap for KEYBOARD
// events (the keylogger-class API, gated behind Input Monitoring). A tap
// masked to mouse buttons sees clicks and drags, never a keystroke, is
// covered by the Accessibility grant nigiri already holds, and was
// explicitly opted into by the user. If nigiri ever hangs, macOS
// auto-disables an unresponsive tap and clicks flow normally again - the
// tap re-enables itself on the next callback.
final class MouseDragController {
    nonisolated enum Phase { case idle, move, resize, plain }
    private var tap: CFMachPort?
    private(set) var phase: Phase = .idle

    // Claim check: return true to own the drag - from then until mouse-up
    // every event of that button is consumed (the app under the cursor
    // never sees the click).
    var onBegin: ((CGPoint, Phase) -> Bool)?
    var onMove: ((CGPoint) -> Void)?
    var onEnd: ((CGPoint) -> Void)?
    // Plain (un-modified) left press - overview claims these. onPlainClick
    // returns true at mouse-DOWN to own the whole press; the rest (drags,
    // the up) is then consumed and delivered as onPlainDrag/onPlainUp so the
    // owner can tell a click (select) from a drag (rearrange) on release.
    // The app under the cursor never sees half a click either way.
    var onPlainClick: ((CGPoint) -> Bool)?
    var onPlainDrag: ((CGPoint) -> Void)?
    var onPlainUp: ((CGPoint) -> Void)?

    // niri's Mod+WheelScroll* bindings, MOUSE wheel only: a real hardware
    // scroll IS delivered to this HID tap (unlike synthetic trackpad
    // scroll, which macOS consumes upstream - verified). Fires with a key
    // like "mod-down"/"mod-ctrl-left" while Mod (Cmd+Opt) is held; the
    // scroll is consumed so the app under the cursor doesn't also scroll.
    var onWheel: ((String) -> Void)?
    // A wheel/two-finger scroll with NO modifier, in pixel deltas plus the
    // cursor position. Returns true when it was used (the overview panning
    // the strip under the cursor), which consumes the event; anything else
    // passes straight through to the app below, untouched.
    var onScroll: ((CGFloat, CGFloat, CGPoint) -> Bool)?
    // Mouse-button binds (niri's MouseMiddle/MouseBack/MouseForward and the
    // modifier'd left/right). Keyed "<mods>-<button>"; returns true when the
    // press was claimed, in which case it is consumed.
    var onButton: ((String) -> Bool)?
    private var lastWheelFire = Date.distantPast
    // Buttons whose press was claimed by a bind: their up is swallowed too.
    private var claimedButtons: Set<String> = []

    // input { mod-key }: what Mod means for drags, wheel and button binds.
    nonisolated(unsafe) static var modMask: HotkeyListener.Modifiers = [.command, .option]

    private static func modHeld(_ flags: CGEventFlags) -> Bool {
        var needed: CGEventFlags = []
        if modMask.contains(.command) { needed.insert(.maskCommand) }
        if modMask.contains(.option) { needed.insert(.maskAlternate) }
        if modMask.contains(.control) { needed.insert(.maskControl) }
        if modMask.contains(.shift) { needed.insert(.maskShift) }
        guard !needed.isEmpty else { return false }
        return flags.isSuperset(of: needed)
    }

    // The table key for a button press: the same "<mods>-<button>" shape the
    // config parser produces.
    private static func buttonKey(_ button: String, flags: CGEventFlags) -> String {
        var mods: Set<String> = []
        if modHeld(flags) {
            mods.insert("mod")
        } else {
            if flags.contains(.maskCommand) { mods.insert("cmd") }
            if flags.contains(.maskAlternate) { mods.insert("opt") }
        }
        if flags.contains(.maskControl), !modMask.contains(.control) { mods.insert("ctrl") }
        if flags.contains(.maskShift), !modMask.contains(.shift) { mods.insert("shift") }
        // Through the config's own canonicalizer: this is the other half of a
        // lookup, and the two halves have to spell the key the same way.
        return NigiriConfig.bindingKey(mods: mods, suffix: button)
    }

    func start() {
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue) | (1 << CGEventType.rightMouseUp.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue) | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<MouseDragController>.fromOpaque(refcon).takeUnretainedValue()
            // The tap's run loop source lives on the main run loop.
            return MainActor.assumeIsolated { controller.handle(type: type, event: event) }
        }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            print("[drag] CGEventTap creation failed - Mod+drag disabled")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The mouse-up that happened while the tap was dead never reached
            // us, so an in-progress drag would stay claimed forever: its
            // beginApplyingLayout is never balanced, and from then on
            // WindowWatcher drops EVERY AX notification (no window is adopted
            // or purged again) and every later Mod+drag is refused. Close the
            // drag out before re-arming.
            // A claimed button's mouse-up never arrived either, so the claim
            // would outlive the tap: the next press of that button would be
            // swallowed as the "up" of a press the app never saw.
            claimedButtons.removeAll()
            if phase != .idle {
                let point = event.location
                switch phase {
                case .move, .resize: onEnd?(point)
                case .plain: onPlainUp?(point)
                case .idle: break
                }
                phase = .idle
            }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .scrollWheel:
            guard Self.modHeld(event.flags) else {
                // Pixel deltas, not the notch count: a trackpad/Magic Mouse
                // swipe has to pan by what the fingers actually travelled.
                let dx = CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2))
                let dy = CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
                if (dx != 0 || dy != 0), onScroll?(dx, dy, event.location) == true { return nil }
                return Unmanaged.passUnretained(event)
            }
            let dy = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)  // vertical
            let dx = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)  // horizontal
            if dx != 0 || dy != 0, Date().timeIntervalSince(lastWheelFire) > 0.15 {
                lastWheelFire = Date()
                var mods: Set<String> = ["mod"]
                if event.flags.contains(.maskControl) { mods.insert("ctrl") }
                if event.flags.contains(.maskShift) { mods.insert("shift") }
                let dir = abs(dy) >= abs(dx) ? (dy > 0 ? "up" : "down") : (dx > 0 ? "right" : "left")
                onWheel?(NigiriConfig.bindingKey(mods: mods, suffix: dir))
            }
            return nil  // consumed while Mod is held
        case .otherMouseDown:
            // Buttons 2+ : middle, then back/forward on the usual mice.
            let number = event.getIntegerValueField(.mouseEventButtonNumber)
            let name: String
            switch number {
            case 2: name = "middle"
            case 3: name = "back"
            case 4: name = "forward"
            default: return Unmanaged.passUnretained(event)
            }
            if onButton?(Self.buttonKey(name, flags: event.flags)) == true {
                claimedButtons.insert(name)
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .otherMouseUp:
            // Swallow the up of a claimed press so the app never sees half a
            // click; unclaimed buttons pass through untouched.
            let number = event.getIntegerValueField(.mouseEventButtonNumber)
            let name = number == 2 ? "middle" : (number == 3 ? "back" : (number == 4 ? "forward" : ""))
            if !name.isEmpty, onButton != nil, claimedButtons.contains(name) {
                claimedButtons.remove(name)
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .leftMouseDown, .rightMouseDown:
            guard phase == .idle else { return Unmanaged.passUnretained(event) }
            // A bound left/right press acts as a bind and never starts a drag.
            let buttonName = type == .leftMouseDown ? "left" : "right"
            if onButton?(Self.buttonKey(buttonName, flags: event.flags)) == true {
                claimedButtons.insert(buttonName)
                return nil
            }
            if !Self.modHeld(event.flags) {
                if type == .leftMouseDown, onPlainClick?(event.location) == true {
                    phase = .plain
                    return nil
                }
                return Unmanaged.passUnretained(event)
            }
            let candidate: Phase = type == .leftMouseDown ? .move : .resize
            if onBegin?(event.location, candidate) == true {
                phase = candidate
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .leftMouseDragged, .rightMouseDragged:
            guard phase != .idle else { return Unmanaged.passUnretained(event) }
            switch phase {
            case .move, .resize: onMove?(event.location)
            case .plain: onPlainDrag?(event.location)
            case .idle: break
            }
            return nil
        case .leftMouseUp, .rightMouseUp:
            let upName = type == .leftMouseUp ? "left" : "right"
            if claimedButtons.remove(upName) != nil { return nil }
            guard phase != .idle else { return Unmanaged.passUnretained(event) }
            switch phase {
            case .move, .resize: onEnd?(event.location)
            case .plain: onPlainUp?(event.location)
            case .idle: break
            }
            phase = .idle
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

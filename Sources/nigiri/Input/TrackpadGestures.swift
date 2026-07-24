import Foundation

// Continuous trackpad gestures via Apple's private MultitouchSupport
// framework - the same source Swish/BetterTouchTool read. NSEvent can't do
// this: with the system three-finger gestures disabled (which is what frees
// them for us), macOS emits no .swipe/.gesture events and global monitors
// never see raw touches (verified empirically). MultitouchSupport delivers
// the raw contact frames - finger count and per-finger position - which is
// exactly what libinput hands niri: this layer emits begin/update(dx, dy)/
// end just like GestureSwipeBegin/Update/End (input/mod.rs:3843-4010), and
// the engine runs niri's own SwipeTracker state machines on top. Loaded via
// dlopen so there's no link-time dependency on a private framework.

// The MTTouch contact struct, laid out to match the framework's ABI (the
// well-known reverse-engineered layout; only frame/timestamp/state and the
// normalized position are read - the rest is padding to keep the stride
// correct). Field order/size must not change.
private struct MTPoint { var x: Float = 0; var y: Float = 0 }
private struct MTReadout { var pos = MTPoint(); var vel = MTPoint() }
private struct MTTouch {
    var frame: Int32 = 0
    var timestamp: Double = 0
    var identifier: Int32 = 0
    var state: Int32 = 0
    var fingerID: Int32 = 0
    var handID: Int32 = 0
    var normalized = MTReadout()
    var size: Float = 0
    var pressure: Int32 = 0
    var angle: Float = 0
    var majorAxis: Float = 0
    var minorAxis: Float = 0
    var absolute = MTReadout()
    var pad0: Int32 = 0
    var pad1: Int32 = 0
    var density: Float = 0
}

// The callback takes a raw pointer (the struct isn't @convention(c)-
// representable through the generic pointer); the body rebinds it to
// MTTouch.
private typealias MTContactCallback = @convention(c) (Int32, UnsafeRawPointer?, Int32, Double, Int32) -> Int32
private typealias MTDeviceCreateDefaultFn = @convention(c) () -> UnsafeMutableRawPointer?
// Every multitouch device, not just the default one: a Magic Mouse is a
// multitouch surface too, and MTDeviceCreateDefault only ever returns the
// built-in trackpad.
private typealias MTDeviceCreateListFn = @convention(c) () -> CFArray?
private typealias MTDeviceGetFamilyIDFn =
    @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>) -> Int32
private typealias MTRegisterFn = @convention(c) (UnsafeMutableRawPointer?, MTContactCallback) -> Void
private typealias MTStartFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
private typealias MTStopFn = @convention(c) (UnsafeMutableRawPointer?) -> Void

// One frame of the continuous gesture stream, the shape of libinput's
// swipe events: fingers at begin, per-frame deltas in 1000dpi-normalized
// pixels (libinput's unaccelerated unit, which every niri gesture constant
// is calibrated against), timestamps in seconds.
enum SwipePhase {
    case begin(fingers: Int)
    case update(dx: CGFloat, dy: CGFloat, timestamp: TimeInterval)
    case end
}

// The per-device centroid differentiator, owned by the multitouch thread.
// It lives OUTSIDE the MainActor-isolated recognizer on purpose: mtCallback
// runs on MultitouchSupport's own thread, so mutating the recognizer's
// stored properties from there was a genuine data race. State is guarded by
// its own lock, and the only thing crossing to the main actor is the
// emitted phase.
private nonisolated final class ContinuousTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var fingers = 0
    private var lastX: Float = 0
    private var lastY: Float = 0

    // MT positions are normalized [0,1] over the pad surface; libinput
    // reports gesture deltas normalized to 1000dpi. A built-in trackpad is
    // roughly 160x100mm, so a full-width traversal is 160mm * 1000/25.4 -
    // the macOS-forced conversion that keeps niri's constants (300px per
    // workspace, 1200px per view width, 16px axis lock) meaning what they
    // mean upstream.
    static let padWidthPx: CGFloat = 160.0 * 1000.0 / 25.4
    static let padHeightPx: CGFloat = 100.0 * 1000.0 / 25.4

    // Feeds one contact frame; returns the phases to emit (a finger-count
    // change ends the old gesture and may begin a new one in one frame).
    func feed(fingers n: Int, centroidX cx: Float, centroidY cy: Float, now: Double) -> [SwipePhase] {
        lock.lock(); defer { lock.unlock() }
        var out: [SwipePhase] = []
        if active, n != fingers {
            active = false
            out.append(.end)
        }
        guard n == 3 || n == 4 else { return out }
        if !active {
            active = true
            fingers = n
            lastX = cx
            lastY = cy
            out.append(.begin(fingers: n))
            return out
        }
        let dx = CGFloat(cx - lastX) * Self.padWidthPx
        // MT y grows UPWARD; libinput's grows downward. The engine's state
        // machines are written against the MT sign (fingers up = dy > 0).
        let dy = CGFloat(cy - lastY) * Self.padHeightPx
        lastX = cx
        lastY = cy
        out.append(.update(dx: dx, dy: dy, timestamp: now))
        return out
    }

    func reset() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let was = active
        active = false
        return was
    }
}

final class TrackpadGestures {
    // The @convention(c) callback can't capture context, so it reaches the
    // live recognizer through this single shared instance.
    nonisolated(unsafe) static weak var shared: TrackpadGestures?

    // Fired on the main thread with each phase of a continuous 3- or
    // 4-finger trackpad gesture. niri has no Magic Mouse gestures, so mouse
    // devices are ignored (their 1-2 finger surface IS scrolling).
    var onGesture: ((SwipePhase) -> Void)?
    // Read from the MT thread, so it is a Sendable box of its own.
    // One recognizer per device: a Magic Mouse and the trackpad deliver
    // frames independently, and a shared state machine let one device's
    // reset cancel the other's half-finished swipe.
    private nonisolated let recognizers = RecognizerTable()

    private var devices: [UnsafeMutableRawPointer] = []
    // MT device id -> family id, filled at startup and read from the MT
    // thread to tell a Magic Mouse frame from a trackpad frame.
    nonisolated(unsafe) static var deviceFamilies: [Int32: Int32] = [:]
    private var device: UnsafeMutableRawPointer?
    private var registerFn: MTRegisterFn?
    private var startFn: MTStartFn?
    private var stopFn: MTStopFn?

    // Magic Mouse families, from what the hardware reports (printed at
    // startup, so an unknown device is identifiable instead of silently
    // misclassified). Trackpads report 98-103 and 128+.
    nonisolated static func isMouseFamily(_ family: Int32) -> Bool {
        (112...113).contains(family)
    }

    func start() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW) else {
            print("[gestures] MultitouchSupport unavailable - three-finger swipes disabled")
            return
        }
        guard let createSym = dlsym(handle, "MTDeviceCreateDefault"),
            let registerSym = dlsym(handle, "MTRegisterContactFrameCallback"),
            let startSym = dlsym(handle, "MTDeviceStart"),
            let stopSym = dlsym(handle, "MTDeviceStop")
        else {
            print("[gestures] MultitouchSupport symbols missing - disabled")
            return
        }
        let create = unsafeBitCast(createSym, to: MTDeviceCreateDefaultFn.self)
        registerFn = unsafeBitCast(registerSym, to: MTRegisterFn.self)
        startFn = unsafeBitCast(startSym, to: MTStartFn.self)
        stopFn = unsafeBitCast(stopSym, to: MTStopFn.self)
        let familyFn = dlsym(handle, "MTDeviceGetFamilyID").map {
            unsafeBitCast($0, to: MTDeviceGetFamilyIDFn.self)
        }

        // Every device: the built-in trackpad AND anything else with a touch
        // surface (a Magic Mouse, a Magic Trackpad).
        if let listSym = dlsym(handle, "MTDeviceCreateList"),
            let list = unsafeBitCast(listSym, to: MTDeviceCreateListFn.self)() as [AnyObject]?
        {
            for entry in list {
                devices.append(Unmanaged.passUnretained(entry).toOpaque())
            }
        }
        if devices.isEmpty, let dev = create() { devices.append(dev) }
        guard !devices.isEmpty else {
            print("[gestures] no multitouch device - disabled")
            return
        }
        device = devices.first
        Self.shared = self
        var described: [String] = []
        // One trampoline per device, so the slot - not the callback's device
        // id - is what identifies the source. Devices past the trampolines
        // are left unregistered rather than misattributed.
        // TWO passes, and the order matters: the callback of a started device
        // runs on the MultitouchSupport thread and reads deviceFamilies for
        // its slot. Filling and starting in one loop meant slot 0 was already
        // delivering frames while the main thread was still writing slot 1 -
        // a write racing a read on the same dictionary. Fill everything
        // first, start nothing until it is all there.
        let registrable = devices.prefix(mtCallbacks.count)
        if devices.count > mtCallbacks.count {
            print(
                "[gestures] \(devices.count - mtCallbacks.count) device(s) not registered: there are only \(mtCallbacks.count) slots"
            )
        }
        for (slot, dev) in registrable.enumerated() {
            var family: Int32 = 0
            _ = familyFn?(dev, &family)
            Self.deviceFamilies[Int32(slot)] = family
            described.append("family \(family)\(Self.isMouseFamily(family) ? " (mouse)" : "")")
        }
        for (slot, dev) in registrable.enumerated() {
            registerFn?(dev, mtCallbacks[slot])
            startFn?(dev, 0)
        }
        print("[gestures] \(described.count) multitouch device(s): \(described.joined(separator: ", "))")
    }

    // Called on the MT thread. Differentiates the centroid of the touches
    // while three or four fingers are down and streams the phases to the
    // main thread, in order, exactly like libinput's swipe events.
    fileprivate nonisolated func handleFrame(slot device: Int32, _ raw: UnsafeRawPointer?, _ count: Int32) {
        let n = Int(count)
        // niri has no Magic Mouse gestures: a mouse's touch surface stays
        // the system's (one finger IS scrolling there).
        if Self.isMouseFamily(Self.deviceFamilies[device] ?? 0) { return }
        guard n == 3 || n == 4, let raw else {
            if recognizers.reset(device) { emit([.end]) }
            return
        }
        let touches = raw.bindMemory(to: MTTouch.self, capacity: n)
        var cx: Float = 0
        var cy: Float = 0
        for i in 0..<n {
            cx += touches[i].normalized.pos.x
            cy += touches[i].normalized.pos.y
        }
        cx /= Float(n); cy /= Float(n)
        let phases = recognizers.feed(
            device, fingers: n, centroidX: cx, centroidY: cy,
            now: Date().timeIntervalSinceReferenceDate)
        if !phases.isEmpty { emit(phases) }
    }

    private nonisolated func emit(_ phases: [SwipePhase]) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                for phase in phases { self?.onGesture?(phase) }
            }
        }
    }
}

// One C callback per device SLOT. The callback's first argument is a
// device id whose numbering does not match what MTDeviceGetDeviceID
// reports - the map keyed on it missed every time, so the Magic Mouse fell
// through to the trackpad branch and three fingers on the mouse drove the
// three-finger trackpad bindings (reported live: "the overview works for me
// with 3 fingers on the mouse"). A @convention(c) function can't capture, so the
// slot is baked into one trampoline per device instead of being looked up.
private func mtCallback0(_ d: Int32, _ t: UnsafeRawPointer?, _ c: Int32, _ ts: Double, _ f: Int32) -> Int32 {
    TrackpadGestures.shared?.handleFrame(slot: 0, t, c); return 0
}
private func mtCallback1(_ d: Int32, _ t: UnsafeRawPointer?, _ c: Int32, _ ts: Double, _ f: Int32) -> Int32 {
    TrackpadGestures.shared?.handleFrame(slot: 1, t, c); return 0
}
private func mtCallback2(_ d: Int32, _ t: UnsafeRawPointer?, _ c: Int32, _ ts: Double, _ f: Int32) -> Int32 {
    TrackpadGestures.shared?.handleFrame(slot: 2, t, c); return 0
}
private func mtCallback3(_ d: Int32, _ t: UnsafeRawPointer?, _ c: Int32, _ ts: Double, _ f: Int32) -> Int32 {
    TrackpadGestures.shared?.handleFrame(slot: 3, t, c); return 0
}
private let mtCallbacks: [MTContactCallback] = [mtCallback0, mtCallback1, mtCallback2, mtCallback3]

// One ContinuousTracker per device id, behind the same lock discipline:
// the table is read and written from the MultitouchSupport thread only.
private nonisolated final class RecognizerTable: @unchecked Sendable {
    private let lock = NSLock()
    private var recognizers: [Int32: ContinuousTracker] = [:]

    private func recognizer(_ device: Int32) -> ContinuousTracker {
        if let existing = recognizers[device] { return existing }
        let made = ContinuousTracker()
        recognizers[device] = made
        return made
    }
    func reset(_ device: Int32) -> Bool {
        lock.lock(); let r = recognizer(device); lock.unlock()
        return r.reset()
    }
    func feed(_ device: Int32, fingers: Int, centroidX: Float, centroidY: Float, now: Double) -> [SwipePhase]
    {
        lock.lock(); let r = recognizer(device); lock.unlock()
        return r.feed(fingers: fingers, centroidX: centroidX, centroidY: centroidY, now: now)
    }
}

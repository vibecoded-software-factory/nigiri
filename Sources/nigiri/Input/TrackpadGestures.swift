import Foundation

// Three-finger trackpad swipes via Apple's private MultitouchSupport
// framework - the same source Swish/BetterTouchTool read. NSEvent can't do
// this: with the system three-finger gestures disabled (which is what frees
// them for us), macOS emits no .swipe/.gesture events and global monitors
// never see raw touches (verified empirically). MultitouchSupport delivers
// the raw contact frames - finger count and per-finger position - so a
// clean three-finger swipe is recognizable without colliding with
// two-finger scroll. Loaded via dlopen so there's no link-time dependency
// on a private framework.

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
private typealias MTDeviceGetFamilyIDFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>) -> Int32
private typealias MTRegisterFn = @convention(c) (UnsafeMutableRawPointer?, MTContactCallback) -> Void
private typealias MTStartFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
private typealias MTStopFn = @convention(c) (UnsafeMutableRawPointer?) -> Void

enum SwipeDirection: Hashable { case left, right, up, down }

// The swipe state machine, owned by the multitouch thread. It lives OUTSIDE
// the MainActor-isolated recognizer on purpose: mtCallback runs on
// MultitouchSupport's own thread, so mutating the recognizer's stored
// properties from there was a genuine data race - it only compiled because
// the module is pinned to Swift 5 language mode. Here the state is
// nonisolated and guarded by its own lock, and the ONLY thing that crosses
// to the main actor is the recognized direction.
private nonisolated final class SwipeRecognizer: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var startX: Float = 0
    private var startY: Float = 0
    private var lastFireTime: Double = 0

    private let threshold: Float = 0.18
    private let cooldown: Double = 0.4

    func reset() {
        lock.lock(); defer { lock.unlock() }
        active = false
    }

    // Returns a direction only when this frame completes a swipe.
    func feed(centroidX cx: Float, centroidY cy: Float, now: Double) -> SwipeDirection? {
        lock.lock(); defer { lock.unlock() }
        if !active {
            active = true
            startX = cx; startY = cy
            return nil
        }
        let dx = cx - startX
        let dy = cy - startY
        guard now - lastFireTime > cooldown else { return nil }
        var dir: SwipeDirection?
        if abs(dx) > threshold, abs(dx) > abs(dy) {
            dir = dx > 0 ? .right : .left
        } else if abs(dy) > threshold, abs(dy) > abs(dx) {
            // Trackpad Y grows upward; a downward finger motion is dy < 0.
            dir = dy > 0 ? .up : .down
        }
        guard let dir else { return nil }
        lastFireTime = now
        startX = cx; startY = cy   // re-arm so a continued drag can repeat
        return dir
    }
}

final class TrackpadGestures {
    // The @convention(c) callback can't capture context, so it reaches the
    // live recognizer through this single shared instance.
    nonisolated(unsafe) static weak var shared: TrackpadGestures?

    // Fired on the main thread with a recognized three-finger swipe.
    // The finger count travels with the direction: three- and four-finger
    // swipes are separate bindings.
    // (direction, fingers, isMouse): a two-finger swipe on a Magic Mouse
    // and a two-finger swipe on the trackpad are different gestures.
    var onSwipe: ((SwipeDirection, Int, Bool) -> Void)?
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
              let stopSym = dlsym(handle, "MTDeviceStop") else {
            print("[gestures] MultitouchSupport symbols missing - disabled")
            return
        }
        let create = unsafeBitCast(createSym, to: MTDeviceCreateDefaultFn.self)
        registerFn = unsafeBitCast(registerSym, to: MTRegisterFn.self)
        startFn = unsafeBitCast(startSym, to: MTStartFn.self)
        stopFn = unsafeBitCast(stopSym, to: MTStopFn.self)
        let familyFn = dlsym(handle, "MTDeviceGetFamilyID").map { unsafeBitCast($0, to: MTDeviceGetFamilyIDFn.self) }

        // Every device: the built-in trackpad AND anything else with a touch
        // surface (a Magic Mouse, a Magic Trackpad).
        if let listSym = dlsym(handle, "MTDeviceCreateList"),
           let list = unsafeBitCast(listSym, to: MTDeviceCreateListFn.self)() as [AnyObject]? {
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
            print("[gestures] \(devices.count - mtCallbacks.count) dispositivo(s) sin registrar: solo hay \(mtCallbacks.count) ranuras")
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
        print("[gestures] \(described.count) dispositivo(s) multitouch: \(described.joined(separator: ", "))")
    }

    // Called on the MT thread. Tracks the centroid of the touches while
    // exactly three fingers are down and, on a dominant-axis move past the
    // threshold, reports the swipe (once per gesture) on the main thread.
    fileprivate nonisolated func handleFrame(slot device: Int32, _ raw: UnsafeRawPointer?, _ count: Int32) {
        let n = Int(count)
        let isMouse = Self.isMouseFamily(Self.deviceFamilies[device] ?? 0)
        // A Magic Mouse has room for one or two fingers, a trackpad is read
        // at three or four (two is scroll there, one is the pointer).
        let recognized = isMouse ? (n == 1 || n == 2) : (n == 3 || n == 4)
        guard recognized, let raw else {
            recognizers.reset(device)
            return
        }
        // A finger added or lifted mid-swipe is a different gesture: drop
        // the partial track instead of attributing it to the new count.
        if recognizers.fingerCount(device) != n {
            recognizers.reset(device)
            recognizers.setFingerCount(device, n)
        }
        let touches = raw.bindMemory(to: MTTouch.self, capacity: n)
        var cx: Float = 0, cy: Float = 0
        for i in 0..<n {
            cx += touches[i].normalized.pos.x
            cy += touches[i].normalized.pos.y
        }
        cx /= Float(n); cy /= Float(n)
        guard let dir = recognizers.feed(device, centroidX: cx, centroidY: cy,
                                         now: Date().timeIntervalSinceReferenceDate) else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onSwipe?(dir, n, isMouse) }
        }
    }
}

// One C callback per device SLOT. The callback's first argument is a
// device id whose numbering does not match what MTDeviceGetDeviceID
// reports - the map keyed on it missed every time, so the Magic Mouse fell
// through to the trackpad branch and three fingers on the mouse drove the
// three-finger trackpad bindings (reported live: "el overview me anda con
// 3 dedos en el mouse"). A @convention(c) function can't capture, so the
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

// One SwipeRecognizer per device id, behind the same lock discipline: the
// table is read and written from the MultitouchSupport thread only.
private nonisolated final class RecognizerTable: @unchecked Sendable {
    private let lock = NSLock()
    private var recognizers: [Int32: SwipeRecognizer] = [:]
    private var fingerCounts: [Int32: Int] = [:]

    private func recognizer(_ device: Int32) -> SwipeRecognizer {
        if let existing = recognizers[device] { return existing }
        let made = SwipeRecognizer()
        recognizers[device] = made
        return made
    }
    func reset(_ device: Int32) {
        lock.lock(); let r = recognizer(device); lock.unlock()
        r.reset()
    }
    func fingerCount(_ device: Int32) -> Int {
        lock.lock(); defer { lock.unlock() }
        return fingerCounts[device] ?? 0
    }
    func setFingerCount(_ device: Int32, _ n: Int) {
        lock.lock(); defer { lock.unlock() }
        fingerCounts[device] = n
    }
    func feed(_ device: Int32, centroidX: Float, centroidY: Float, now: Double) -> SwipeDirection? {
        lock.lock(); let r = recognizer(device); lock.unlock()
        return r.feed(centroidX: centroidX, centroidY: centroidY, now: now)
    }
}

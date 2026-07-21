import AppKit
import ApplicationServices

final class WindowWatcher {
    private var observers: [pid_t: AXObserver] = [:]
    // A depth COUNTER, not a boolean: an animation, its settle-time layout
    // pass and a workspace transition's minimize calls all guard
    // independently and overlap freely - with a boolean, whichever of them
    // ended first reopened the guard while the others were still writing.
    private var applyDepth = 0
    var isApplyingLayout: Bool { applyDepth > 0 }
    var onLayoutInvalidated: (() -> Void)?
    // A window died, reported the instant it happens. The relayout's purge
    // learns the same thing, but only after the app's window list has missed
    // it on several consecutive scans (a zombie has to prove it is dead) -
    // far too late for a close animation, which has to start on the frame the
    // window disappears.
    var onWindowDestroyed: ((AXUIElement) -> Void)?

    func watch(pid: pid_t) {
        guard observers[pid] == nil else { return }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            // C function pointers are implicitly @Sendable; the observer's
            // run loop source is installed on the main run loop, so state
            // that here once rather than making every downstream handler
            // Sendable.
            let name = notification as String
            MainActor.assumeIsolated {
                Unmanaged<WindowWatcher>.fromOpaque(refcon).takeUnretainedValue()
                    .handle(notification: name, element: element)
            }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(observer, appElement, name as CFString, selfPtr)
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    // kAXUIElementDestroyedNotification must be registered per-window (not
    // app-level like the others), for every window discovered both from
    // initial enumeration and from later kAXWindowCreatedNotification events.
    // Registered destruction notifications, so a rescan does not re-register
    // every window: this ran once per window per relayout, and relayout runs
    // on every window notification from every watched app.
    // The elements themselves, not their hashes: CFHash collides, and the
    // rest of the codebase always pairs it with CFEqual for exactly that
    // reason (knownWindow, the purge, the element index). A collision here
    // would silently skip registering a real window's destruction notice.
    // There is no "forget" counterpart: a dead element is never re-registered
    // (nothing hands out a destroyed AXUIElement again), and AXObserver drops
    // its own registration when the element dies. The one that existed was
    // dead code - no call sites, and a comment describing a slot reuse that
    // does not happen.
    private var destructionWatched: [AXUIElement] = []

    func watchForDestruction(_ window: AXUIElement, pid: pid_t) {
        guard let observer = observers[pid] else { return }
        guard !destructionWatched.contains(where: { CFEqual($0, window) }) else { return }
        destructionWatched.append(window)
        AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
    }

    // Observers of quit apps otherwise accumulate for the process's whole
    // lifetime - each an installed run loop source serving a dead AX
    // connection, and watch() would trust the stale entry if the OS ever
    // recycled that pid onto a new app.
    func unwatch(pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    // Wrap any code that calls AXUIElementSetAttributeValue through this so
    // the moved/resized notifications it generates don't re-trigger
    // onLayoutInvalidated and thrash/loop against our own layout pass.
    // For a write that spans an entire ASYNC multi-tick animation instead of
    // one synchronous call, use the begin/end pair directly - once before
    // the first tick, once after the animation settles or is cancelled -
    // instead of wrapping every tick: notifications from one tick can arrive
    // after that tick's own brief guard window closed but before the next
    // tick starts. Every begin must be balanced by exactly one end.
    func applyingLayout(_ body: () -> Void) {
        beginApplyingLayout()
        body()
        endApplyingLayout()
    }

    func beginApplyingLayout() { applyDepth += 1 }
    // The decrement is deferred one run loop turn: AXObserver delivers a
    // write's notifications asynchronously (verified live - never within the
    // same call that made the write), so decrementing synchronously reopens
    // the guard before the write's own notifications have arrived, letting
    // them through as if they were external events - each triggering another
    // relayout, whose writes' notifications arrive just as late, a
    // self-sustaining loop with no real change driving it. One turn isn't a
    // guarantee for a laggy app's notifications either - the guard is only
    // the first line of defense; actual loop-immunity comes from a converged
    // layout performing zero writes (see ColumnLayoutEngine.applyFrame).
    func endApplyingLayout() {
        DispatchQueue.main.async { [self] in applyDepth = max(0, applyDepth - 1) }
    }

    private func handle(notification: String, element: AXUIElement) {
        // Before the isApplyingLayout guard: a window dying while we happen to
        // be writing frames is still a window dying, and nothing we did caused
        // it - that guard is there to stop our OWN writes from feeding back.
        if notification == kAXUIElementDestroyedNotification as String {
            onWindowDestroyed?(element)
        }
        guard !isApplyingLayout else { return }
        onLayoutInvalidated?()
    }
}

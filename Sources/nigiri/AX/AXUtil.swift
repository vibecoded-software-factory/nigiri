import ApplicationServices
import Foundation

// The AXUIElement C API's out-parameter dance (declare a CFTypeRef?, call,
// check the AXError, cast) was pasted at ~15 call sites across the module -
// every new feature re-typed it and every reviewer re-verified it. These
// wrappers are the one place that dance happens.
//
// Two deliberate omissions: reads that must DISTINGUISH error codes (the
// zombie check cares about .invalidUIElement specifically) and AXValue
// struct decoding (WindowMover.currentFrame) stay hand-written - collapsing
// those here would just move their subtlety behind a misleadingly simple
// name.
// One flag, one gate - the `ProcessInfo...["NIGIRI_DEBUG"] != nil` check was
// re-evaluated inline at seven call sites. @autoclosure keeps message
// construction free when the flag is off.
let debugEnabled = ProcessInfo.processInfo.environment["NIGIRI_DEBUG"] != nil
func debugLog(_ message: @autoclosure () -> String) {
    if debugEnabled { print(message()) }
}

enum AX {
    // Every AX read is a blocking round-trip to the owning app, and Apple's
    // default timeout is SIX SECONDS. The animator's tick has 8.3ms: one
    // unresponsive app was enough to freeze an animation mid-flight, with no
    // way to tell from the outside that the app - not nigiri - was the one
    // that stopped. Set on the system-wide element, which is the default for
    // every element this process creates without one of its own.
    //
    // One second, not less: a slow-but-alive app that misses the deadline
    // reports its write as refused, and three refusals demote a window to the
    // floating layer. Bounded, not aggressive.
    static func setGlobalMessagingTimeout(_ seconds: Float = 1.0) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    // Bridged attribute values (String, Bool, NSNumber, arrays). NOT for
    // single AXUIElement results - CF types don't support conditional
    // downcast (`as? AXUIElement` succeeds for ANY CF value), which is why
    // element(_:_:) below exists and does a real type-id check.
    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
        return ref as? T
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    // "Does this window expose this attribute at all" - the close-button /
    // default-button probes, where only presence matters, not the value.
    static func hasAttribute(_ element: AXUIElement, _ name: String) -> Bool {
        var ref: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success && ref != nil
    }

    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, name as CFString, &settable)
        return settable.boolValue
    }

    static func windows(ofPid pid: pid_t) -> [AXUIElement]? {
        attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute as String)
    }

    static func focusedWindow(ofPid pid: pid_t) -> AXUIElement? {
        element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as String)
    }
}

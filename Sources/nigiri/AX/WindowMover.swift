import AppKit
import ApplicationServices

enum WindowMover {
    enum MoveError: Error, CustomStringConvertible {
        case notFound
        case positionNotSettable
        case sizeNotSettable
        case axFailure(AXError)

        var description: String {
            switch self {
            case .notFound: return "no window matching that app/title was found"
            case .positionNotSettable: return "cannot move: kAXPositionAttribute not settable on this window"
            case .sizeNotSettable: return "cannot resize: kAXSizeAttribute not settable on this window"
            case .axFailure(let err): return "AX call failed with error \(err.rawValue)"
            }
        }
    }

    static func findWindow(appContains: String, titleContains: String) -> AXUIElement? {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let name = app.localizedName, name.localizedCaseInsensitiveContains(appContains) else { continue }
            guard let windows = AX.windows(ofPid: app.processIdentifier) else { continue }
            if titleContains.isEmpty, let first = windows.first { return first }
            for w in windows {
                if let t: String = AX.attribute(w, kAXTitleAttribute as String), t.localizedCaseInsensitiveContains(titleContains) { return w }
            }
        }
        return nil
    }

    // Stays hand-written (see AXUtil's header): AXValue struct decoding is
    // its own dance, distinct from the bridged-value reads AX.attribute
    // covers.
    static func currentFrame(_ window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    // Actually raises and activates a window - not just internal bookkeeping.
    // Without this, "focus-column-left/right" would change which column
    // nigiri considers focused without the user ever seeing or being able to
    // type into that window, since kAXFocusedWindowChanged notifications flow
    // the other way (window -> us), not this one (us -> window).
    static func focus(_ window: AXUIElement, pid: pid_t) {
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    // Position-only write: does NOT touch kAXSizeAttribute. A size write
    // forces the target app to re-layout its whole content (Chrome reflows
    // the page) - far more expensive than a move. Animations whose frames
    // only translate (workspace falls/rises, horizontal strip scrolls) use
    // this per tick and leave size to the one-off settle pass.
    // `assumeSettable` skips the settable probe: it is a full IPC round-trip
    // (measured 0.046ms, about as expensive as the write itself) for an
    // answer that does not change, and the animator asks it twice per window
    // per tick at 120Hz. collectCurrentAXWindows already probes it.
    static func setPosition(_ window: AXUIElement, to origin: CGPoint, assumeSettable: Bool = false) throws {
        guard assumeSettable || AX.isSettable(window, kAXPositionAttribute as String) else { throw MoveError.positionNotSettable }
        var origin = origin
        guard let posVal = AXValueCreate(.cgPoint, &origin) else { return }
        let posErr = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
        guard posErr == .success else { throw MoveError.axFailure(posErr) }
    }

    static func setFrame(_ window: AXUIElement, to frame: CGRect) throws {
        guard AX.isSettable(window, kAXPositionAttribute as String) else { throw MoveError.positionNotSettable }
        guard AX.isSettable(window, kAXSizeAttribute as String) else { throw MoveError.sizeNotSettable }

        var origin = frame.origin
        var size = frame.size
        guard let posVal = AXValueCreate(.cgPoint, &origin), let sizeVal = AXValueCreate(.cgSize, &size) else { return }

        // Position first, then size - some apps clamp size relative to the
        // window's current position, so setting position first reduces
        // surprising clamping. Callers should re-read the frame afterward
        // since some apps silently enforce a minimum size regardless.
        let posErr = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
        guard posErr == .success else { throw MoveError.axFailure(posErr) }
        let sizeErr = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
        guard sizeErr == .success else { throw MoveError.axFailure(sizeErr) }
    }
}

import AppKit

enum ScreenGeometry {
    // niri's layout { struts }: insets removed from the working area, for a
    // bar or anything else that must not be covered.
    nonisolated(unsafe) static var struts = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    // AX/CoreGraphics global space: origin top-left of the PRIMARY display, Y down.
    // Uses visibleFrame (excludes the menu bar and Dock), not the raw frame -
    // macOS refuses to place a window's top edge under the menu bar, so
    // laying out against the full frame silently overflows past the bottom
    // edge by exactly the menu bar's height instead of leaving a real gap.
    // Must read NSScreen.screens.first (the primary), never NSScreen.main
    // (the "key window's" screen) - deferred properly to the multi-monitor
    // milestone.
    // Whether there is a screen to lay out on at all. Every geometry caller
    // used to derive from a silent .zero: usableWidth became -20,
    // columnPlacements clamped every width to 0 and each managed window got a
    // 0x0 frame written over AX. The trigger is real and immediate - a
    // display disappearing fires didChangeScreenParameters, which relayouts
    // unconditionally - and it left no log line at all.
    static var hasUsableScreen: Bool { NSScreen.screens.first != nil }

    static func primaryScreenVisibleFrameInAXSpace() -> CGRect {
        visibleFrameInAXSpace(for: NSScreen.screens.first)
    }

    // The working area of ANY screen, in AX/CG top-left space. The Y flip is
    // always against the PRIMARY's height, because the global CG origin is the
    // primary's top-left - an external monitor at AppKit origin (1470, -124)
    // maps to AX (1470, 0). visibleFrame already excludes that screen's own
    // menu bar / Dock; the config struts are carved off on top of that. Falls
    // back to the primary (then .zero) so a nil screen never crashes a caller.
    static func visibleFrameInAXSpace(for screen: NSScreen?) -> CGRect {
        guard let primary = NSScreen.screens.first else { return .zero }
        let target = screen ?? primary
        let visible = target.visibleFrame
        let flippedY = primary.frame.height - visible.origin.y - visible.height
        let s = struts
        var frame = CGRect(
            x: visible.origin.x + s.left, y: flippedY + s.top,
            width: visible.width - s.left - s.right,
            height: visible.height - s.top - s.bottom)
        frame.size.width = max(1, frame.size.width)
        frame.size.height = max(1, frame.size.height)
        return frame
    }

    // Every window the WindowServer currently has ordered in on THIS Space,
    // as pid -> bounds (already in AX/CG top-left space). AX has no public
    // notion of macOS Spaces at all - a window on another Space reads and
    // writes exactly like a visible one - but CGWindowList's onScreenOnly
    // option omits other-Space (and minimized/hidden) windows, so absence
    // from this list is the one public-API signal that focusing a window
    // would frame something the user cannot see.
    static func onScreenWindowBoundsByPid() -> [pid_t: [CGRect]] {
        var result: [pid_t: [CGRect]] = [:]
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: AnyObject]] else {
            return result
        }
        for entry in list {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            let frame = CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0)
            result[pid, default: []].append(frame)
        }
        return result
    }

    // The inverse of the AX-space math above - NSWindow.setFrame wants
    // AppKit's bottom-left-origin space, so an overlay tracking an
    // AX-space managed-window frame needs this conversion before display.
    static func axFrameToAppKit(_ axFrame: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return axFrame }
        let flippedY = primary.frame.height - axFrame.origin.y - axFrame.height
        return CGRect(x: axFrame.origin.x, y: flippedY, width: axFrame.width, height: axFrame.height)
    }
}

extension CGRect {
    // A cheap, stable digest of a rect, for change detection only - rounded
    // to the pixel so a sub-pixel wobble is not a "change".
    var integerHash: Int {
        var h = Int(origin.x.rounded())
        h = h &* 31 &+ Int(origin.y.rounded())
        h = h &* 31 &+ Int(size.width.rounded())
        h = h &* 31 &+ Int(size.height.rounded())
        return abs(h)
    }
}

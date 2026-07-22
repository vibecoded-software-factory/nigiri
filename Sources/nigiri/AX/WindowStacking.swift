import AppKit
import CoreGraphics

// Who is in front of whom, read from WindowServer.
//
// Our decorations are separate always-on-top windows, because macOS gives no
// way to draw inside another process's window. That means a border knows
// nothing about whether the window it belongs to is actually visible: it
// paints over whatever happens to be there.
//
// The rule this replaced assumed a FLOATING window is the only thing that can
// cover another one - true in niri, where the layout owns the stack. On macOS
// it is false: activating an app raises ALL of that app's windows, so an
// ordinary tiled window routinely ends up in front of a floating one. Seen
// live: Calculator floating behind Font Book, its border still drawn across
// Font Book's content, outlining a window nobody could see.
//
// So the stack is asked for rather than inferred. `CGWindowListCopyWindowInfo`
// with `.optionOnScreenOnly` returns the on-screen windows FRONT TO BACK, and
// needs no permission beyond what nigiri already has (window TITLES need
// Screen Recording; the order and bounds do not, and neither is read here).
//
// Measured on this machine: 0.634ms average, 5.3ms worst case, 15 windows.
// That is too expensive for an 8.3ms animation tick, so it is read once per
// pass - at the same point the expensive AX half is already paid - and the
// depths are carried through the tick.
enum WindowStacking {
    struct Entry {
        let pid: pid_t
        let frame: CGRect
    }

    // Front to back. Only layer 0: the higher layers are the menu bar, the
    // Dock, Control Center and OUR OWN chrome, none of which is a window a
    // border can be hidden behind - and our overlays are in front of
    // everything by construction, so counting them would hide every border.
    static func onScreen(
        excludingPid excluded: pid_t = ProcessInfo.processInfo.processIdentifier
    )
        -> [Entry]
    {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { entry in
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != excluded,
                let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                let x = bounds["X"], let y = bounds["Y"],
                let width = bounds["Width"], let height = bounds["Height"]
            else { return nil }
            // kCGWindowBounds is already top-left origin in global display
            // space, which is the same space AX reports frames in - no flip.
            return Entry(pid: pid, frame: CGRect(x: x, y: y, width: width, height: height))
        }
    }

    // The frames of every window sitting ABOVE the normal level (layer != 0),
    // grouped by owning pid. These are the macOS analogue of Wayland layer
    // surfaces: status bars, panels, HUDs and system overlays - the things a
    // tiling WM must never adopt as a toplevel. niri never sees them because
    // in Wayland they are not toplevels at all; here a bar drawn by a shell
    // (a borderless window pinned to the status-bar level) otherwise looks
    // like an ordinary window and gets tiled into a column.
    //
    // Grouped by pid so the caller can skip the whole check for an app that
    // has no elevated window (every ordinary app), paying the per-window frame
    // read only for the few processes that actually own a panel.
    static func elevatedFramesByPid(
        excludingPid excluded: pid_t = ProcessInfo.processInfo.processIdentifier
    )
        -> [pid_t: [CGRect]]
    {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var byPid: [pid_t: [CGRect]] = [:]
        for entry in raw {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer != 0,
                let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != excluded,
                let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                let x = bounds["X"], let y = bounds["Y"],
                let width = bounds["Width"], let height = bounds["Height"]
            else { continue }
            byPid[pid, default: []].append(CGRect(x: x, y: y, width: width, height: height))
        }
        return byPid
    }

    // How deep each window sits, 0 being the frontmost. Pure, so the matching
    // is covered by the selftest rather than by looking at a screen.
    //
    // Matching is by pid and frame because nigiri has no CGWindowID for its
    // AX windows (the overview pays for that mapping through
    // SCShareableContent, which is far too expensive for every decoration
    // pass). Entries are CLAIMED front to back: the windows of a tabbed
    // column share one frame exactly, and claiming in order gives the visible
    // one the front depth and the ones behind it the depths behind - which is
    // precisely the case where a border must not be drawn.
    //
    // nil means "no match" - an app that reports a frame AX and WindowServer
    // disagree about, or a window that is not on screen at all. Those keep
    // their decoration: a border that is drawn when it should not be is a
    // cosmetic bug, and one that vanishes for a window the user is looking at
    // reads as the window manager having lost it.
    static func depths(
        of windows: [(pid: pid_t, frame: CGRect)], in stacking: [Entry], tolerance: CGFloat = 2
    ) -> [Int?] {
        var result = [Int?](repeating: nil, count: windows.count)
        var claimed = Set<Int>()
        for (depth, entry) in stacking.enumerated() {
            var best: Int? = nil
            var bestDistance = CGFloat.greatestFiniteMagnitude
            for (index, window) in windows.enumerated()
            where !claimed.contains(index) && window.pid == entry.pid {
                let distance = max(
                    abs(window.frame.origin.x - entry.frame.origin.x),
                    abs(window.frame.origin.y - entry.frame.origin.y),
                    abs(window.frame.width - entry.frame.width),
                    abs(window.frame.height - entry.frame.height))
                if distance <= tolerance && distance < bestDistance {
                    best = index
                    bestDistance = distance
                }
            }
            if let best {
                result[best] = depth
                claimed.insert(best)
            }
        }
        return result
    }
}

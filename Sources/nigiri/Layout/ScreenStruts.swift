import CoreGraphics

// A strip of the screen reserved along one edge, requested over the IPC socket.
// This is the compositor side of niri's layer-shell exclusive zone: a panel or
// bar asks for space at an edge, and the layout leaves it free. nigiri neither
// knows nor cares which client asked - it is a plain screen-edge reservation.
//
// niri does this IN THE COMPOSITOR: it lays the tiled windows out in the space
// that is left. macOS has no equivalent - a window's `NSScreen.visibleFrame` is
// read-only and only the system Dock and menu bar reserve space - so nigiri
// takes the compositor's place and honors the reservation here, by shrinking
// the area the tiling layout uses.
//
// The honest limit: only nigiri-managed windows are laid out against a strut.
// An app the user zooms with the green button uses the system visibleFrame and
// will still cover the reserved strip; there is no public API to change that.
struct ScreenStrut: Equatable {
    enum Edge: String { case top, bottom, left, right }
    let edge: Edge
    let size: CGFloat
    // The requesting client's pid, when it sent one. A reservation is dropped
    // the moment that process dies (didTerminateApplicationNotification), so a
    // panel that crashes or is killed without clearing its own zone cannot
    // leave the layout permanently shrunk. nil = no owner given, kept until an
    // explicit clear-zone.
    var ownerPid: pid_t? = nil
}

// Per-edge insets, in points. Plain data so the strut math stays pure and
// selftestable away from NSScreen.
struct EdgeInsets: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
    var left: CGFloat = 0
    var right: CGFloat = 0
}

enum ScreenStruts {
    // Combine the system's own insets (menu-bar/notch strip, Dock) with the
    // IPC-reserved struts: per edge, the LARGER of the two wins - not the sum.
    // A reservation is measured from the PHYSICAL screen edge, like a
    // layer-shell exclusive zone, and the panel that reserved it typically
    // covers the system strip itself (window levels above normal may occupy
    // it). Summing would double-count and open a dead gap between the panel
    // and the first window. With no reservation on an edge the system inset
    // still wins, so windows never land under the strip the WindowServer
    // refuses them. Struts on the same edge stack with each other first.
    static func effectiveInsets(system: EdgeInsets, reserved: [ScreenStrut]) -> EdgeInsets {
        var sum = EdgeInsets()
        for strut in reserved where strut.size > 0 {
            switch strut.edge {
            case .top: sum.top += strut.size
            case .bottom: sum.bottom += strut.size
            case .left: sum.left += strut.size
            case .right: sum.right += strut.size
            }
        }
        return EdgeInsets(
            top: max(system.top, sum.top),
            bottom: max(system.bottom, sum.bottom),
            left: max(system.left, sum.left),
            right: max(system.right, sum.right))
    }

    // Inset a frame (AX space: top-left origin, y grows downward) by every
    // strut. Struts on the same edge stack. Clamped so an over-large strut
    // reserves the whole screen rather than producing a negative rect.
    static func inset(_ frame: CGRect, by struts: [ScreenStrut]) -> CGRect {
        var top: CGFloat = 0
        var bottom: CGFloat = 0
        var left: CGFloat = 0
        var right: CGFloat = 0
        for strut in struts where strut.size > 0 {
            switch strut.edge {
            case .top: top += strut.size
            case .bottom: bottom += strut.size
            case .left: left += strut.size
            case .right: right += strut.size
            }
        }
        let width = max(0, frame.width - left - right)
        let height = max(0, frame.height - top - bottom)
        return CGRect(x: frame.minX + left, y: frame.minY + top, width: width, height: height)
    }
}

import AppKit

// niri's insert hint (layout { insert-hint }): while a window is being
// dragged, a filled translucent slab marks exactly where it will land -
// a full-height column-wide slab for a new column, a tile-sized band for
// a slot inside a column's stack. Default colour is niri's own:
// rgba(127, 200, 255, 128).
final class InsertHintOverlay {
    private let window: NSWindow
    private var color = NSColor(calibratedRed: 127 / 255.0, green: 200 / 255.0, blue: 255 / 255.0, alpha: 128 / 255.0)
    private var isOff = false

    init() {
        window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        // Above the windows being rearranged, below the panels.
        window.level = ChromeLevel.decoration
        window.collectionBehavior = [.stationary, .ignoresCycle]
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.cornerRadius = macOSWindowCornerRadius
        window.contentView = view
    }

    func applyStyle(off: Bool, color: NSColor) {
        isOff = off
        self.color = color
        window.contentView?.layer?.backgroundColor = color.cgColor
        if off { window.orderOut(nil) }
    }

    // `frame` is in AX space, like every other overlay here.
    // Called on every mouse-move of a drag, so it does the least it can: the
    // colour is already on the layer (applyStyle owns it), the window is
    // already in front (ordering front again on every event is a WindowServer
    // round-trip), and display: false lets the frame ride the same CA commit
    // as everything else instead of forcing a synchronous redraw.
    func show(_ frame: CGRect) {
        guard !isOff else { return }
        // No implicit animation: the hint has to track the cursor, and a
        // CALayer sliding into place reads as lag.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.setFrame(ScreenGeometry.axFrameToAppKit(frame), display: false)
        CATransaction.commit()
        if !window.isVisible { window.orderFront(nil) }
    }

    func hide() { window.orderOut(nil) }
}

import AppKit

// niri's layout.border: a plain stroke around every VISIBLE non-focused
// managed window - the focused one wears the gradient focus ring instead.
// Off by default, exactly like niri. One borderless click-through window
// per bordered app window, pooled and repositioned every animation tick
// alongside the ring (they used to snap only at settle, which read as the
// border lagging behind its window all the way across the screen).
final class InactiveDecorations {
    private var overlays: [NSWindow] = []
    private var width: CGFloat = 0
    private var color: NSColor = .darkGray

    // Style is written to the layers HERE, not per frame: setting
    // borderWidth/borderColor/cornerRadius inside the update loop allocated
    // a fresh CGColor on every window on every tick (measured 0.149ms per
    // overlay per tick - 1.34ms of an 8.33ms budget with nine windows).
    func applyStyle(width: CGFloat, color: NSColor) {
        self.width = width
        self.color = color
        if width <= 0 { hideAll(); return }
        styleGeneration += 1
        for overlay in overlays { style(overlay) }
    }

    private var styleGeneration = 0
    private var styledGeneration: [ObjectIdentifier: Int] = [:]

    private func style(_ overlay: NSWindow) {
        guard let layer = overlay.contentView?.layer else { return }
        layer.borderWidth = width
        layer.borderColor = color.cgColor
        // Concentric with the window's own corner: the overlay sits `width`
        // outside it, so the outer radius is windowRadius + width.
        layer.cornerRadius = macOSWindowCornerRadius + width
        styledGeneration[ObjectIdentifier(overlay)] = styleGeneration
    }

    // `frames` in AX space, one per window that should wear a border.
    func update(frames: [CGRect]) {
        guard width > 0 else { hideAll(); return }
        while overlays.count < frames.count { overlays.append(Self.makeOverlay()) }
        // CALayer animates bounds/position IMPLICITLY: each frame written
        // here kicked off a ~0.25s animation of the border's OWN layer, so
        // the stroke crawled after its window instead of moving with it -
        // which is what still read as lag after the per-tick updates were
        // added. RingView.layout() already does this; the borders never did.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (i, overlay) in overlays.enumerated() {
            guard i < frames.count else {
                if overlay.isVisible { overlay.orderOut(nil) }
                continue
            }
            if styledGeneration[ObjectIdentifier(overlay)] != styleGeneration { style(overlay) }
            // Same geometry as the focus ring: the stroke lives in the gap
            // OUTSIDE the window's edges, not on top of its content.
            let target = ScreenGeometry.axFrameToAppKit(frames[i].insetBy(dx: -width, dy: -width))
            if overlay.frame != target { overlay.setFrame(target, display: true) }
            // orderFront is a WindowServer round-trip; skip it once visible.
            if !overlay.isVisible { overlay.orderFront(nil) }
        }
    }

    func hideAll() {
        for overlay in overlays { overlay.orderOut(nil) }
    }

    private static func makeOverlay() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        // One level BELOW the focus ring: where an inactive border and the
        // ring overlap (adjacent windows sharing a gap), the ring wins.
        window.level = ChromeLevel.decoration
        window.collectionBehavior = [.stationary, .ignoresCycle]
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = view
        return window
    }
}

import AppKit

// niri's layout.border: a plain stroke around every VISIBLE non-focused
// managed window - the focused one wears the gradient focus ring instead.
// Off by default, exactly like niri. One borderless click-through window
// per bordered app window, pooled and repositioned every animation tick
// alongside the ring (they used to snap only at settle, which read as the
// border lagging behind its window all the way across the screen).
//
// The stroke is a CAShapeLayer bezier, NOT a CALayer borderWidth. They target
// the same geometry, but a thick CALayer border draws a squared-off corner
// that overhangs the window's rounded corner - reported live: the inactive
// frame looked bigger than the window at the corners, while the focused
// window's ring (already a bezier) hugged them. Stroking the ring's exact
// path fixes the corner because it IS the ring's corner.
final class InactiveDecorations {
    private var overlays: [NSWindow] = []
    private var width: CGFloat = 0
    private var color: NSColor = .darkGray

    // Style is written to the layers HERE, not per frame: setting the stroke
    // colour and line width inside the update loop allocated a fresh CGColor
    // on every window on every tick (measured 0.149ms per overlay per tick -
    // 1.34ms of an 8.33ms budget with nine windows).
    func applyStyle(width: CGFloat, color: NSColor) {
        self.width = width
        self.color = color
        if width <= 0 { hideAll(); return }
        styleGeneration += 1
        for overlay in overlays { style(overlay) }
    }

    private var styleGeneration = 0
    private var styledGeneration: [ObjectIdentifier: Int] = [:]
    // The bounds the current path was built for, per overlay: the path is a
    // function of size only, so it is rebuilt when a window RESIZES, never on
    // the far more common move (same size, new position).
    private var pathBounds: [ObjectIdentifier: CGRect] = [:]

    private func shapeLayer(_ overlay: NSWindow) -> CAShapeLayer? {
        overlay.contentView?.layer as? CAShapeLayer
    }

    private func style(_ overlay: NSWindow) {
        guard let layer = shapeLayer(overlay) else { return }
        layer.strokeColor = color.cgColor
        layer.fillColor = NSColor.clear.cgColor
        layer.lineWidth = width
        styledGeneration[ObjectIdentifier(overlay)] = styleGeneration
        // The line width changed, so the cached path is stale.
        pathBounds[ObjectIdentifier(overlay)] = nil
    }

    // `frames` in AX space, one per window that should wear a border.
    func update(frames: [CGRect]) {
        guard width > 0 else { hideAll(); return }
        while overlays.count < frames.count { overlays.append(Self.makeOverlay()) }
        // CALayer animates path/position IMPLICITLY: each frame written here
        // would kick off a ~0.25s animation of the stroke's OWN layer, so it
        // crawled after its window instead of moving with it. RingView.layout
        // disables the same actions for the same reason.
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
            if let layer = shapeLayer(overlay), let view = overlay.contentView {
                let key = ObjectIdentifier(overlay)
                if pathBounds[key] != view.bounds {
                    layer.frame = view.bounds
                    // Concentric with the window corner, exactly as the ring:
                    // centerline radius = R + w/2, so the inner stroke edge
                    // lands on radius R (hugging the window) and the outer on
                    // R + w.
                    let radius = macOSWindowCornerRadius + width / 2
                    layer.path =
                        NSBezierPath(
                            roundedRect: view.bounds.insetBy(dx: width / 2, dy: width / 2),
                            xRadius: radius, yRadius: radius
                        ).cgPath
                    pathBounds[key] = view.bounds
                }
            }
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
        // Layer-hosting with a CAShapeLayer as the backing layer, so the
        // stroke is a real bezier with the ring's corner, not a border box.
        view.layer = CAShapeLayer()
        view.wantsLayer = true
        window.contentView = view
        return window
    }
}

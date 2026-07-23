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
    private var activeOverlay: NSWindow?
    private var width: CGFloat = 0
    private var color: NSColor = .darkGray
    // niri draws the border on EVERY window when enabled - the focused one
    // in active-color (default rgb(255,200,127), appearance.rs), UNDER its
    // focus ring; only the rest wear inactive-color.
    private var activeColor: NSColor = NSColor(
        calibratedRed: 255 / 255.0, green: 200 / 255.0, blue: 127 / 255.0, alpha: 1)

    // Style is written to the layers HERE, not per frame: setting the stroke
    // colour and line width inside the update loop allocated a fresh CGColor
    // on every window on every tick (measured 0.149ms per overlay per tick -
    // 1.34ms of an 8.33ms budget with nine windows).
    func applyStyle(width: CGFloat, color: NSColor, activeColor: NSColor? = nil) {
        self.width = width
        self.color = color
        if let activeColor { self.activeColor = activeColor }
        if width <= 0 { hideAll(); return }
        styleGeneration += 1
        for overlay in overlays { style(overlay) }
        if let active = activeOverlay { style(active, stroke: self.activeColor) }
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

    private func style(_ overlay: NSWindow, stroke: NSColor? = nil) {
        guard let layer = shapeLayer(overlay) else { return }
        layer.strokeColor = (stroke ?? color).cgColor
        layer.fillColor = NSColor.clear.cgColor
        layer.lineWidth = width
        styledGeneration[ObjectIdentifier(overlay)] = styleGeneration
        // The line width changed, so the cached path is stale.
        pathBounds[ObjectIdentifier(overlay)] = nil
    }

    // `frames` in AX space, one per window that should wear a border;
    // `active` is the FOCUSED window's frame, stroked in active-color like
    // niri's border on the active window (the ring rides above it).
    func update(frames: [CGRect], active: CGRect? = nil) {
        guard width > 0 else { hideAll(); return }
        while overlays.count < frames.count { overlays.append(Self.makeOverlay()) }
        if let active {
            let overlay = activeOverlay ?? Self.makeOverlay()
            if activeOverlay == nil {
                activeOverlay = overlay
                style(overlay, stroke: activeColor)
            }
            if styledGeneration[ObjectIdentifier(overlay)] != styleGeneration {
                style(overlay, stroke: activeColor)
            }
            place(overlay, frame: active)
            if !overlay.isVisible { overlay.orderFront(nil) }
        } else if let overlay = activeOverlay, overlay.isVisible {
            overlay.orderOut(nil)
        }
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
            place(overlay, frame: frames[i])
            // orderFront is a WindowServer round-trip; skip it once visible.
            if !overlay.isVisible { overlay.orderFront(nil) }
        }
    }

    // Shared geometry for both flavors: the stroke lives in the gap OUTSIDE
    // the window's edges, concentric with the macOS corner exactly like the
    // ring (centerline radius R + w/2).
    private func place(_ overlay: NSWindow, frame: CGRect) {
        let target = ScreenGeometry.axFrameToAppKit(frame.insetBy(dx: -width, dy: -width))
        if overlay.frame != target { overlay.setFrame(target, display: true) }
        if let layer = shapeLayer(overlay), let view = overlay.contentView {
            let key = ObjectIdentifier(overlay)
            if pathBounds[key] != view.bounds {
                layer.frame = view.bounds
                let radius = macOSWindowCornerRadius + width / 2
                layer.path =
                    NSBezierPath(
                        roundedRect: view.bounds.insetBy(dx: width / 2, dy: width / 2),
                        xRadius: radius, yRadius: radius
                    ).cgPath
                pathBounds[key] = view.bounds
            }
        }
    }

    func hideAll() {
        for overlay in overlays { overlay.orderOut(nil) }
        activeOverlay?.orderOut(nil)
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

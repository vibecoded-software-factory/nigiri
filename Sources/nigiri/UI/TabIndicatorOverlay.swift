import AppKit

// niri's tab indicator: a slim strip of segments, one per window in a
// tabbed column, drawn OUTSIDE the column - to its right, `gap` away - and
// taking NO space from the windows (niri only does that with
// `place-within-column`, which is off by default; wiki: Configuration ->
// Layout, defaults read there: position right, gap 5, gaps-between-tabs 2,
// corner-radius 8, length total-proportion 0.5).
//
// nigiri used to draw an opaque bar of window TITLES above the column and
// subtract its height from every window in it: a different object, which
// also made tabbed windows genuinely shorter than the same column in niri.
// Switching tabs is still focus-window-up/down - this is display only.
final class TabIndicators {
    private var overlays: [NSWindow] = []

    // niri's TabIndicator knobs (appearance.rs:459-499), applied from the
    // config on every reload - they used to be compiled-in constants.
    private var off = false
    private var hideWhenSingleTab = false
    private var placeWithinColumn = false
    private var gap: CGFloat = 5
    private var width: CGFloat = 4
    private var lengthProportion: CGFloat = 0.5
    private var position: NigiriConfig.TabPosition = .left
    private var gapBetweenTabs: CGFloat = 0
    private var cornerRadius: CGFloat = 0

    private var activeColor: NSColor = NSColor(
        calibratedRed: 127 / 255.0, green: 200 / 255.0, blue: 255 / 255.0, alpha: 1)
    private var inactiveColor: NSColor = NSColor(
        calibratedRed: 80 / 255.0, green: 80 / 255.0, blue: 80 / 255.0, alpha: 1)

    func applyStyle(
        active: NSColor, inactive: NSColor, off: Bool, hideWhenSingleTab: Bool,
        placeWithinColumn: Bool, gap: CGFloat, width: CGFloat, lengthProportion: CGFloat,
        position: NigiriConfig.TabPosition, gapsBetweenTabs: CGFloat, cornerRadius: CGFloat
    ) {
        activeColor = active
        inactiveColor = inactive
        self.off = off
        self.hideWhenSingleTab = hideWhenSingleTab
        self.placeWithinColumn = placeWithinColumn
        self.gap = gap
        self.width = width
        self.lengthProportion = lengthProportion
        self.position = position
        self.gapBetweenTabs = gapsBetweenTabs
        self.cornerRadius = cornerRadius
    }

    // `frame` is the COLUMN's frame in AX space. niri's position knob picks
    // the side (default Left, appearance.rs:488) and place-within-column
    // puts the strip INSIDE the edge instead of beside it.
    func update(bars: [(frame: CGRect, count: Int, active: Int)]) {
        while overlays.count < bars.count { overlays.append(Self.makeOverlay()) }
        for (i, overlay) in overlays.enumerated() {
            guard i < bars.count, bars[i].count > 0, !off,
                !(hideWhenSingleTab && bars[i].count == 1)
            else { overlay.orderOut(nil); continue }
            let bar = bars[i]
            let strip: CGRect
            switch position {
            case .left, .right:
                let stripHeight = bar.frame.height * lengthProportion
                let x =
                    position == .left
                    ? (placeWithinColumn ? bar.frame.minX + gap : bar.frame.minX - gap - width)
                    : (placeWithinColumn ? bar.frame.maxX - gap - width : bar.frame.maxX + gap)
                strip = CGRect(
                    x: x, y: bar.frame.midY - stripHeight / 2, width: width, height: stripHeight)
            case .top, .bottom:
                let stripWidth = bar.frame.width * lengthProportion
                let y =
                    position == .top
                    ? (placeWithinColumn ? bar.frame.minY + gap : bar.frame.minY - gap - width)
                    : (placeWithinColumn ? bar.frame.maxY - gap - width : bar.frame.maxY + gap)
                strip = CGRect(
                    x: bar.frame.midX - stripWidth / 2, y: y, width: stripWidth, height: width)
            }
            populate(overlay, count: bar.count, active: bar.active, size: strip.size)
            overlay.setFrame(ScreenGeometry.axFrameToAppKit(strip), display: true)
            overlay.orderFront(nil)
        }
    }

    func hideAll() {
        for overlay in overlays { overlay.orderOut(nil) }
    }

    private func populate(_ overlay: NSWindow, count: Int, active: Int, size: CGSize) {
        guard let content = overlay.contentView else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        guard count > 0 else { return }
        let horizontal = size.width > size.height
        let axis = horizontal ? size.width : size.height
        let totalGaps = gapBetweenTabs * CGFloat(count - 1)
        let segment = max(2, (axis - totalGaps) / CGFloat(count))
        for index in 0..<count {
            let frame: CGRect
            if horizontal {
                // The first window's segment is the LEFT one.
                let x = CGFloat(index) * (segment + gapBetweenTabs)
                frame = CGRect(x: x, y: 0, width: segment, height: size.height)
            } else {
                // The first window's segment is the TOP one: AX space runs
                // down, AppKit view coordinates run up, so it is mirrored.
                let y = size.height - CGFloat(index + 1) * segment - CGFloat(index) * gapBetweenTabs
                frame = CGRect(x: 0, y: y, width: size.width, height: segment)
            }
            let view = NSView(frame: frame)
            view.wantsLayer = true
            view.layer?.backgroundColor = (index == active ? activeColor : inactiveColor).cgColor
            view.layer?.cornerRadius = min(cornerRadius, min(frame.width, frame.height) / 2)
            content.addSubview(view)
        }
    }

    private static func makeOverlay() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.level = ChromeLevel.decoration
        window.collectionBehavior = [.stationary, .ignoresCycle]
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        window.contentView = view
        return window
    }
}

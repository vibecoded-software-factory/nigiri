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

    static let gap: CGFloat = 5
    static let width: CGFloat = 4
    // niri defaults (appearance.rs TabIndicator): gaps-between-tabs 0,
    // corner-radius 0. The old 2/8 were invented styling.
    static let gapBetweenTabs: CGFloat = 0
    static let cornerRadius: CGFloat = 0
    static let lengthProportion: CGFloat = 0.5

    private var activeColor: NSColor = NSColor(
        calibratedRed: 127 / 255.0, green: 200 / 255.0, blue: 255 / 255.0, alpha: 1)
    private var inactiveColor: NSColor = NSColor(
        calibratedRed: 80 / 255.0, green: 80 / 255.0, blue: 80 / 255.0, alpha: 1)

    // layout { tab-indicator { active-gradient / inactive-color } }
    func applyStyle(active: NSColor, inactive: NSColor) {
        activeColor = active
        inactiveColor = inactive
    }

    // `frame` is the COLUMN's frame in AX space; the strip is placed beside
    // it, never inside it.
    func update(bars: [(frame: CGRect, count: Int, active: Int)]) {
        while overlays.count < bars.count { overlays.append(Self.makeOverlay()) }
        for (i, overlay) in overlays.enumerated() {
            guard i < bars.count, bars[i].count > 0 else { overlay.orderOut(nil); continue }
            let bar = bars[i]
            let stripHeight = bar.frame.height * Self.lengthProportion
            // niri's default position is LEFT of the column
            // (appearance.rs:488, TabIndicatorPosition::Left); the right-
            // side placement was invented styling.
            let strip = CGRect(
                x: bar.frame.minX - Self.gap - Self.width,
                y: bar.frame.midY - stripHeight / 2,
                width: Self.width,
                height: stripHeight)
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
        let totalGaps = Self.gapBetweenTabs * CGFloat(count - 1)
        let segment = max(2, (size.height - totalGaps) / CGFloat(count))
        for index in 0..<count {
            // The first window's segment is the TOP one: AX space runs down,
            // AppKit view coordinates run up, so the index is mirrored here.
            let y = size.height - CGFloat(index + 1) * segment - CGFloat(index) * Self.gapBetweenTabs
            let view = NSView(frame: CGRect(x: 0, y: y, width: size.width, height: segment))
            view.wantsLayer = true
            view.layer?.backgroundColor = (index == active ? activeColor : inactiveColor).cgColor
            view.layer?.cornerRadius = min(Self.cornerRadius, size.width / 2)
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

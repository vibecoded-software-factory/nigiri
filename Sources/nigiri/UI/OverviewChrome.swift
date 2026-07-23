import AppKit

// The workspace labels for overview mode: one chip per row, pooled like
// every other overlay here. Display only - selection is the mouse tap's
// job (a click on a window in overview jumps to it).
final class OverviewChrome {
    private var chips: [NSWindow] = []

    func show(rows: [(y: CGFloat, label: String, active: Bool)]) {
        while chips.count < rows.count { chips.append(Self.makeChip()) }
        for (i, chip) in chips.enumerated() {
            guard i < rows.count else { chip.orderOut(nil); continue }
            let row = rows[i]
            if let label = chip.contentView?.subviews.first as? NSTextField {
                label.stringValue = row.label
                label.textColor = row.active ? .white : NSColor(calibratedWhite: 0.8, alpha: 1)
            }
            chip.contentView?.layer?.backgroundColor =
                (row.active
                ? NSColor(calibratedRed: 127 / 255.0, green: 200 / 255.0, blue: 255 / 255.0, alpha: 0.95)
                : NSColor(calibratedWhite: 0.15, alpha: 0.95)).cgColor
            let frame = CGRect(x: 8, y: row.y, width: 110, height: 26)
            chip.setFrame(ScreenGeometry.axFrameToAppKit(frame), display: true)
            chip.orderFrontRegardless()
        }
    }

    func hide() {
        for chip in chips { chip.orderOut(nil) }
    }

    private static func makeChip() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.level = ChromeLevel.panel
        window.collectionBehavior = [.stationary, .ignoresCycle]
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 110, height: 26))
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.alignment = .center
        label.frame = CGRect(x: 4, y: 4, width: 102, height: 17)
        view.addSubview(label)
        window.contentView = view
        return window
    }
}

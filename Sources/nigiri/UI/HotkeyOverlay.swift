import AppKit

// A borderless window is not key-eligible by default; this panel needs to
// be (it takes focus on open so its scroller and Escape work). LSUIElement
// keeps nigiri out of the Dock, but NSApp.activate + this override let the
// panel become key for as long as it's up.
private final class KeyablePanelWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// niri's hotkey-overlay (the "Important Hotkeys" panel behind
// show-hotkey-overlay): a floating cheat-sheet of the current bindings,
// toggled by the same action that opened it. The full bind list is far
// taller than any screen, so the panel is capped at 60% of screen height
// and SCROLLS - it takes focus on open (Escape closes it, arrows/wheel
// scroll it), unlike the click-through ring/border overlays. Accented
// with the focus-ring purple.
final class HotkeyOverlay {
    private let window: NSWindow
    private var keyMonitor: Any?

    var isVisible: Bool { window.isVisible }

    // An unbound action simply shows an empty combo column - the overlay
    // states, it never explains.
    init(bindings: [(combo: String, action: String)]) {
        let comboWidth = bindings.map { $0.combo.count }.max() ?? 0
        let text = bindings
            .map { $0.combo.padding(toLength: comboWidth + 3, withPad: " ", startingAt: 0) + $0.action }
            .joined(separator: "\n")

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .white
        label.lineBreakMode = .byClipping
        label.sizeToFit()
        let textSize = label.frame.size

        let textPad: CGFloat = 20       // padding inside the scrolled text
        let margin: CGFloat = 4         // gap so the purple border stays visible
        let screenHeight = NSScreen.screens.first?.visibleFrame.height ?? 800
        let maxHeight = screenHeight * 0.6   // compact - scroll for the rest
        let fullTextHeight = textSize.height + 2 * textPad
        let scrolls = fullTextHeight + 2 * margin > maxHeight
        let scrollerRoom: CGFloat = scrolls ? 16 : 0

        let panelWidth = textSize.width + 2 * textPad + 2 * margin + scrollerRoom
        let panelHeight = min(fullTextHeight + 2 * margin, maxHeight)

        // Background container - the dark card + purple border live here so
        // they always paint (an NSScrollView's own layer sits under its
        // clip view and never shows).
        let container = NSView(frame: CGRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.96).cgColor
        container.layer?.cornerRadius = 14
        container.layer?.borderWidth = 2
        // Neutral, deliberately NOT the focus-ring purple: this panel is
        // nigiri's own UI, never a focused window, and wearing the focus
        // colour made it read as permanently selected (reported live). Same
        // grey as the inactive-window border.
        container.layer?.borderColor = NSColor(calibratedRed: 0x58 / 255.0, green: 0x5B / 255.0, blue: 0x70 / 255.0, alpha: 1).cgColor
        container.layer?.masksToBounds = true

        let documentView = NSView(frame: CGRect(x: 0, y: 0, width: textSize.width + 2 * textPad, height: fullTextHeight))
        label.frame = CGRect(x: textPad, y: textPad, width: textSize.width, height: textSize.height)
        documentView.addSubview(label)

        let scrollView = NSScrollView(frame: CGRect(x: margin, y: margin, width: panelWidth - 2 * margin, height: panelHeight - 2 * margin))
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = scrolls
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.verticalScrollElasticity = .allowed
        container.addSubview(scrollView)

        window = KeyablePanelWindow(contentRect: CGRect(x: 0, y: 0, width: panelWidth, height: panelHeight), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // NOT click-through: the panel has to catch scroll-wheel events.
        window.ignoresMouseEvents = false
        window.level = ChromeLevel.panel
        window.collectionBehavior = [.stationary, .ignoresCycle]
        window.contentView = container
    }

    func toggle() {
        if window.isVisible { hide() } else { show() }
    }

    private func show() {
        window.center()
        // Start scrolled to the TOP (unflipped document: top is max-y)
        // rather than wherever the last frame left it.
        if let scroll = window.contentView?.subviews.compactMap({ $0 as? NSScrollView }).first,
           let doc = scroll.documentView {
            doc.scroll(NSPoint(x: 0, y: doc.frame.height))
        }
        // Take focus so Escape and the scroller keyboard keys work.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Escape closes; every other key falls through to the scroll view.
        // Local monitor (not global): only fires while OUR panel is key.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { self?.hide(); return nil } // Escape
            return event
        }
    }

    func hide() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor); keyMonitor = nil }
        window.orderOut(nil)
    }
}

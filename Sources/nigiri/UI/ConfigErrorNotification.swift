import AppKit

// niri's config error notification (src/ui/config_error_notification.rs):
// a banner at the top center of the screen - "Failed to parse the config
// file. Please run <validator> to see the errors." - shown on every failed
// reload (from scratch even if already showing, to bring attention),
// hidden on a successful one, and auto-hiding after 4 seconds (upstream's
// Shown duration). Padding 8, border 4, sans 14px, same as upstream's
// pango texture; the named command is nigiri's own validator. It used to
// be a single line in a log nobody watches (audit ACT-16).
@MainActor
final class ConfigErrorNotification {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    // config-notification { disable-failed } (misc.rs:87-102).
    var disableFailed = false

    func show(on screen: NSScreen?) {
        guard !disableFailed else { return }
        hideWork?.cancel()
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        guard let screen = screen ?? NSScreen.main else { return }
        let text = "Failed to parse the config file. Please run nigiri check-config to see the errors."
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 14)
        label.textColor = .white
        label.sizeToFit()
        let padding: CGFloat = 8
        let border: CGFloat = 4
        let size = CGSize(
            width: label.frame.width + 2 * (padding + border),
            height: label.frame.height + 2 * (padding + border))
        label.setFrameOrigin(CGPoint(x: padding + border, y: padding + border))
        guard let content = panel.contentView else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.95).cgColor
        content.layer?.borderColor = NSColor(calibratedRed: 0.75, green: 0.1, blue: 0.1, alpha: 1).cgColor
        content.layer?.borderWidth = border
        content.layer?.cornerRadius = 8
        content.addSubview(label)
        let origin = CGPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.maxY - size.height - 8)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 1
        }
        // Upstream stays Shown for 4 seconds, then hides on its own.
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup(
            { ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 0
            },
            completionHandler: { panel.orderOut(nil) })
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = ChromeLevel.panel
        panel.collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllSpaces]
        panel.animationBehavior = .none
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        panel.contentView = view
        return panel
    }
}

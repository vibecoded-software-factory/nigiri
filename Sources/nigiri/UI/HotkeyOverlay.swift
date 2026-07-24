import AppKit

// niri's hotkey overlay (src/ui/hotkey_overlay.rs): the "Important Hotkeys"
// panel behind show-hotkey-overlay. It shows a CURATED list of ~20 actions
// with friendly names and fallbacks - never the whole bind table - rendered
// at alpha 0.9, and it does NOT take keyboard focus (it is a compositor
// overlay upstream, not a window). The previous panel listed every bind
// plus the unbound action catalog, scrolled, and activated the app to
// become key - all invented (audit ACT-10). Escape closes it through a
// global observe-only monitor: without key status the event cannot be
// swallowed, so the focused app sees the Escape too - the one deviation,
// noted rather than hidden.
final class HotkeyOverlay {
    struct Entry: Equatable {
        let combo: String
        let title: String
    }

    private let window: NSWindow
    private var keyMonitor: Any?

    var isVisible: Bool { window.isVisible }

    // niri's collect_actions (hotkey_overlay.rs:197-300), action for action:
    // the fixed important set, the column/window -to-workspace fallbacks,
    // screenshot only if bound, binds with a custom hotkey-overlay-title,
    // and Mod+spawn binds - deduplicated, hidden binds excluded everywhere,
    // and hide-not-bound dropping anything without a key.
    static func curated(
        binds: [(combo: String, action: String, title: String?, hidden: Bool)],
        hideNotBound: Bool
    ) -> [Entry] {
        let visible = binds.filter { !$0.hidden }
        func bind(for action: String) -> (combo: String, action: String, title: String?, hidden: Bool)? {
            // Exact spelling first (Quit(false) preferred over Quit(true),
            // hotkey_overlay.rs:204-212), then the parameterized form.
            visible.first { $0.action == action } ?? visible.first { $0.action.hasPrefix(action + " ") }
        }
        var wanted: [(action: String, title: String)] = [
            ("show-hotkey-overlay", "Show Important Hotkeys"),
            ("quit", "Exit nigiri"),
            ("close-window", "Close Focused Window"),
            ("focus-column-left", "Focus Column to the Left"),
            ("focus-column-right", "Focus Column to the Right"),
            ("move-column-left", "Move Column Left"),
            ("move-column-right", "Move Column Right"),
            ("focus-workspace-down", "Switch Workspace Down"),
            ("focus-workspace-up", "Switch Workspace Up"),
        ]
        // Prefer the column -to-workspace moves, fall back to the window
        // variants when only those are bound (hotkey_overlay.rs:224-252).
        if bind(for: "move-column-to-workspace-down") != nil
            || bind(for: "move-window-to-workspace-down") == nil
        {
            wanted.append(("move-column-to-workspace-down", "Move Column to Workspace Down"))
        } else {
            wanted.append(("move-window-to-workspace-down", "Move Window to Workspace Down"))
        }
        if bind(for: "move-column-to-workspace-up") != nil
            || bind(for: "move-window-to-workspace-up") == nil
        {
            wanted.append(("move-column-to-workspace-up", "Move Column to Workspace Up"))
        } else {
            wanted.append(("move-window-to-workspace-up", "Move Window to Workspace Up"))
        }
        wanted += [
            ("switch-preset-column-width", "Switch Preset Column Widths"),
            ("maximize-column", "Maximize Column"),
            ("consume-or-expel-window-left", "Consume or Expel Window Left"),
            ("consume-or-expel-window-right", "Consume or Expel Window Right"),
            ("toggle-window-floating", "Move Window Between Floating and Tiling"),
            ("switch-focus-between-floating-and-tiling", "Switch Focus Between Floating and Tiling"),
            ("toggle-overview", "Open the Overview"),
        ]
        // Screenshot is not as important, omitted unless bound
        // (hotkey_overlay.rs:264-270).
        if bind(for: "screenshot") != nil {
            wanted.append(("screenshot", "Take a Screenshot"))
        }
        // Binds carrying a custom hotkey-overlay-title (271-278), avoiding
        // duplicate actions.
        for b in visible where b.title != nil {
            let already = wanted.contains { b.action == $0.action || b.action.hasPrefix($0.action + " ") }
            if !already { wanted.append((b.action, b.title!)) }
        }
        // Mod+spawn binds, one per distinct action, named after the command
        // (280-295; the Mod filter keeps volume keys and wheel binds out).
        for b in visible
        where (b.action.hasPrefix("spawn ") || b.action.hasPrefix("spawn-sh "))
            && b.combo.contains("Mod")
        {
            if !wanted.contains(where: { $0.action == b.action }) {
                let command = b.action.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                wanted.append((b.action, "Spawn \(command)"))
            }
        }
        var entries: [Entry] = []
        for w in wanted {
            let b = bind(for: w.action)
            if hideNotBound, b == nil { continue }
            // The bind's own hotkey-overlay-title wins over the friendly
            // name, exactly upstream's entry() (title.unwrap_or(action_name)).
            entries.append(Entry(combo: b?.combo ?? "", title: b?.title ?? w.title))
        }
        return entries
    }

    init(entries: [Entry]) {
        let comboWidth = entries.map { $0.combo.count }.max() ?? 0
        let body =
            entries
            .map { $0.combo.padding(toLength: comboWidth + 3, withPad: " ", startingAt: 0) + $0.title }
            .joined(separator: "\n")

        // The upstream texture: "Important Hotkeys" heading, then the rows;
        // padding 8, whole thing at alpha 0.9 (hotkey_overlay.rs:23-28,119).
        let title = NSTextField(labelWithString: "Important Hotkeys")
        title.font = NSFont.boldSystemFont(ofSize: 14)
        title.textColor = .white
        title.sizeToFit()
        let label = NSTextField(labelWithString: body)
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .white
        label.lineBreakMode = .byClipping
        label.sizeToFit()

        let pad: CGFloat = 16
        let titleGap: CGFloat = 10
        let width = max(title.frame.width, label.frame.width) + 2 * pad
        let height = title.frame.height + titleGap + label.frame.height + 2 * pad
        let container = NSView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
        container.layer?.cornerRadius = 14
        label.setFrameOrigin(CGPoint(x: pad, y: pad))
        title.setFrameOrigin(
            CGPoint(x: (width - title.frame.width) / 2, y: pad + label.frame.height + titleGap))
        container.addSubview(title)
        container.addSubview(label)

        window = NSWindow(
            contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // Never key, never interactive: niri's overlay is a render element,
        // not a focusable surface.
        window.ignoresMouseEvents = true
        window.level = ChromeLevel.panel
        window.collectionBehavior = [.stationary, .ignoresCycle]
        // Upstream composites the whole overlay at 0.9.
        window.alphaValue = 0.9
        window.contentView = container
    }

    func toggle() {
        if window.isVisible { hide() } else { show() }
    }

    private func show() {
        window.center()
        window.orderFront(nil)
        // Escape closes, like niri. Observe-only: without key status the
        // press cannot be swallowed, so the focused app receives it too.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { self?.hide() }
        }
    }

    func hide() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor); keyMonitor = nil }
        window.orderOut(nil)
    }
}

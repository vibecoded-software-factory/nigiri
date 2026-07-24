import AppKit

// Draws niri's focus-ring (see ~/dotfiles/.config/niri/.config/niri/layout.kdl):
// 4px, active gradient #7355a6 -> #cba6f7 at 45deg. macOS gives no hook to
// draw inside another process's window chrome, so this is a separate
// borderless, click-through, always-on-top window tracking a real window's
// frame - never an injected decoration.
// Matches niri's `focus-ring { width 4 }` by default - a var, not a let:
// the config file's focus-ring section rewrites it on live reload. Shared
// between the overlay window's expansion and RingView's stroke so they
// can't drift apart.
var focusRingWidth: CGFloat = 4

// nigiri's chrome is several borderless always-on-top windows, and macOS
// orders windows of the SAME level by when each was last ordered front.
// With everything at .floating that was a race the focus ring always won -
// it re-asserts orderFrontRegardless on every app activation - so it painted
// OVER nigiri's own panels (reported live: the keybindings panel with the
// ring sitting across it). Levels, not ordering luck, decide this:
enum ChromeLevel {
    // Decorations of NON-focused windows: under the ring, so a stack never
    // shows an inactive border crossing the focused window's ring.
    static let decoration = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
    // The focus ring: it decorates a window, so it belongs with the windows.
    static let focusRing = NSWindow.Level.floating
    // nigiri's own UI (hotkey overlay, overview panel and its chrome): these
    // are surfaces the user is looking AT, never decorations of something
    // else, so they sit above every decoration - and still below the system
    // UI (status bar, Spotlight, Mission Control).
    static let panel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
}

// macOS's own top-level window corner radius (points). The ring/border live
// in the gap OUTSIDE the window, so to hug it their inner edge must share
// this radius - otherwise the stroke cuts across (too small) or bulges away
// from (too big) the window's rounded corner.
//
// MEASURED, not guessed: focus-ring width 0, screenshot, walk the window's
// bare corner pixels row by row, then sweep the ring's radius against that
// profile. 19 traces it exactly - inner edge on the window's edge at every
// depth through the curve - while 15/16/17 leave a 2-7px gap that grows
// toward the top. The corner is a plain circular arc, NOT one of Apple's
// continuous/squircle corners: a squircle of the same extent would put the
// 45° point at 6px depth / 6px inset, an order off what the pixels say.
//
// The thin dark line that still reads as a "gap" at the corner is the
// WINDOW's own shadow, which is thicker there - not something the ring can
// close. A first pass measured that shadow instead of the window edge and
// "found" a 4-5px corner gap that does not exist; the honest comparison is
// always against a ring-less capture of the same window.
//
// Overridable live from the config (focus-ring { corner-radius }): macOS
// versions change this, and re-measuring beats waiting for a rebuild.
var macOSWindowCornerRadius: CGFloat = 19

final class FocusRingOverlay: NSObject {
    private let window: NSWindow
    private let ringView = RingView()

    override init() {
        window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // Rules out any default AppKit window-move animation too, not just
        // the layers'.
        window.animationBehavior = .none
        // .floating: above ordinary app windows (re-raised on every app
        // activation, below, so another regular window stealing focus can't
        // cover it) but BELOW system UI like Spotlight/Control
        // Center/Mission Control - a higher level (e.g. .screenSaver) would
        // render the ring on top of those instead.
        window.level = ChromeLevel.focusRing
        window.collectionBehavior = [.stationary, .ignoresCycle]
        window.contentView = ringView

        super.init()

        // Our own show()/updateRing() only fires on OUR events (focus,
        // maximize, relayout) - if some other app activates on its own
        // (the user just clicking over to it), nothing tells the ring to
        // stay on top, so it can end up covered until our next event.
        // Re-assert z-order on every app activation, system-wide - except
        // when Dock itself activates, which is what happens hosting Mission
        // Control/Launchpad/App Exposé on modern macOS: our ring has no
        // hook into that system compositor effect (windows shrinking into
        // an overview), so it would otherwise sit frozen mid-air over it;
        // hide instead, and it reappears via the next real relayout/focus
        // event once a normal window is frontmost again.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleAppActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )

        // Dock activation alone doesn't cover Mission Control entered via a
        // trackpad gesture or keyboard shortcut - that goes through the
        // WindowServer compositor directly without necessarily making Dock
        // the "active application" in NSWorkspace's terms. Tried the
        // "com.apple.expose.awake" distributed notification some tools use
        // for this too - neither notification fired reliably here. Poll the
        // actual current frontmost app instead: no notification to miss,
        // just the live state, checked a few times a second.
        // Started in show(), stopped in hide(): polling five times a second
        // for the whole session - including while the ring is not even on
        // screen - was the process's entire idle cost.
    }

    private var pollTimer: Timer?
    // True while hidden BECAUSE Dock (Mission Control/Launchpad/App Exposé)
    // is frontmost - distinguishes "hide until the overview closes" from an
    // ordinary hide (no focused window), which must not spuriously re-show.
    private var hiddenForSystemUI = false
    // Fired when the Dock overview that hid the ring is dismissed. The
    // overlay has no idea what frame the ring should take - only the layout
    // model does - so re-showing is the owner's job; without this hook the
    // ring stayed invisible after Mission Control until the next unrelated
    // focus/layout event happened to redraw it.
    var onSystemUIDismissed: (() -> Void)?
    // Borders and tab indicators are separate overlay windows with no poll of
    // their own; without this they float over Mission Control anchored to the
    // windows' pre-Exposé positions.
    var onSystemUIShown: (() -> Void)?

    private func pollFrontmostApp() {
        let dockIsFrontmost = NSWorkspace.shared.frontmostApplication?.localizedName == "Dock"
        if dockIsFrontmost {
            // One condition for both, and it has to be the LATCH's: the
            // callback used to fire on !hiddenForSystemUI alone while the
            // latch also demanded window.isVisible, so with the ring already
            // hidden the borders were told to turn off and nothing was ever
            // told to turn them back on - there was no latch to dismiss.
            if !hiddenForSystemUI, window.isVisible {
                hiddenForSystemUI = true
                onSystemUIShown?()
            }
            hide()
        } else if hiddenForSystemUI {
            hiddenForSystemUI = false
            onSystemUIDismissed?()
        }
    }

    @objc private func handleAppActivated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.localizedName == "Dock" {
            // Must set the re-show flag HERE too: this notification usually
            // beats the 0.2s poll, and the poll only latches the flag while
            // the ring is still visible - hiding first without the flag
            // meant the dismissal callback never fired.
            if !hiddenForSystemUI, window.isVisible {
                hiddenForSystemUI = true
                onSystemUIShown?()
            }
            hide()
            return
        }
        guard window.isVisible else { return }
        window.orderFrontRegardless()
    }

    // `frame` is in AX/CG space (top-left origin, Y down), matching what
    // WindowMover/ColumnLayoutEngine already use - convert once here so
    // every call site stays in that single space.
    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.pollFrontmostApp()
        }
    }
    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func show(around frame: CGRect) {
        startPolling()
        // Grow the overlay past the real window's edges by the ring's own
        // width, so the whole stroke sits in the gap outside the window
        // instead of being centered ON its edge (half overlapping the
        // window's own content, half in the gap) - see RingView.layout().
        let expanded = frame.insetBy(dx: -focusRingWidth, dy: -focusRingWidth)
        window.setFrame(ScreenGeometry.axFrameToAppKit(expanded), display: true)
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
        // Keep polling only while hidden BECAUSE of system UI - that is the
        // state whose end nobody else can detect.
        if !hiddenForSystemUI { stopPolling() }
    }

    // The config file's focus-ring knobs, applied on live reload. The
    // global width is set by the caller (it also drives the overlay
    // expansion in show); this just restyles the layers.
    func applyStyle(width: CGFloat, from: NSColor, to: NSColor, angle: CGFloat = 180) {
        ringView.applyStyle(width: width, from: from, to: to, angle: angle)
    }

    // niri's shadow section. macOS draws every window's own shadow and there
    // is no way to replace it, so these values drive the one shadow nigiri
    // actually renders: the focused window's ring glow.
    func applyShadow(on: Bool, softness: CGFloat, spread: CGFloat, offset: CGSize, color: NSColor) {
        ringView.applyShadow(on: on, softness: softness, spread: spread, offset: offset, color: color)
    }
}

private final class RingView: NSView {
    private var borderWidth: CGFloat = focusRingWidth
    private let gradientLayer = CAGradientLayer()
    private let maskLayer = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        // niri's default ring: solid rgb(127,200,255) (appearance.rs). A
        // configured active-gradient replaces this via applyStyle.
        gradientLayer.colors = [
            NSColor(calibratedRed: 127 / 255.0, green: 200 / 255.0, blue: 255 / 255.0, alpha: 1).cgColor,
            NSColor(calibratedRed: 127 / 255.0, green: 200 / 255.0, blue: 255 / 255.0, alpha: 1).cgColor,
        ]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = CGPoint(x: 1, y: 1)

        maskLayer.fillColor = nil
        maskLayer.strokeColor = NSColor.black.cgColor
        maskLayer.lineWidth = borderWidth
        gradientLayer.mask = maskLayer

        // niri ships shadow OFF by default (appearance.rs: on: false); a
        // configured layout { shadow } turns the glow on via applyShadow.
        // The glow-on-by-default came from the user's windowrules-custom.
        gradientLayer.shadowOpacity = 0

        layer?.addSublayer(gradientLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyShadow(on: Bool, softness: CGFloat, spread: CGFloat, offset: CGSize, color: NSColor) {
        shadowConfigured = on
        gradientLayer.shadowOpacity = on ? 1 : 0
        // CALayer has no true spread (CSS expands the outline); folding it
        // into the blur radius is the closest its shadow model offers.
        // Default 5, like niri's Shadow::default().spread - it used to be
        // parsed away entirely.
        gradientLayer.shadowRadius = (softness + spread) / 2
        gradientLayer.shadowOffset = offset
        gradientLayer.shadowColor = color.cgColor
    }
    private var shadowConfigured = false

    func applyStyle(width: CGFloat, from: NSColor, to: NSColor, angle: CGFloat = 180) {
        borderWidth = width
        gradientLayer.colors = [from.cgColor, to.cgColor]
        // niri's CSS gradient angle (default 180 = to bottom,
        // appearance.rs:92): 0 points up, 90 right. Mapped onto the layer's
        // y-up unit square; only 45 used to be accepted, and rejected at
        // the parser at that.
        let rad = angle * .pi / 180
        let dx = sin(rad) / 2
        let dy = cos(rad) / 2
        gradientLayer.startPoint = CGPoint(x: 0.5 - dx, y: 0.5 + dy)
        gradientLayer.endPoint = CGPoint(x: 0.5 + dx, y: 0.5 - dy)
        maskLayer.lineWidth = width
        // The glow keeps deriving from the ring's own start color, same
        // 0x77 alpha as the original niri rule it mirrors - unless shadow{}
        // set an explicit colour, which wins.
        if !shadowConfigured { gradientLayer.shadowColor = from.withAlphaComponent(0x77 / 255.0).cgColor }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // CALayer implicitly animates frame/path changes by default - every
        // reposition (focus change, a neighboring window closing and this
        // one growing to fill the gap, etc.) was visibly sliding into place
        // instead of snapping immediately. Disable actions for this update.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        // Concentric with the window corner: centerline radius = R + w/2, so
        // the inner stroke edge lands on radius R (hugging the window) and
        // the outer on R + w.
        let cornerRadius = macOSWindowCornerRadius + borderWidth / 2
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2), xRadius: cornerRadius,
            yRadius: cornerRadius
        ).cgPath
        maskLayer.path = path
        maskLayer.frame = bounds
        gradientLayer.shadowPath = path
        CATransaction.commit()
    }
}

// Internal (not private): the inactive-border overlay strokes the exact same
// path so its corners are the same clean arc as the ring's, instead of the
// squared-off corner a thick CALayer border draws.
extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &points) {
            case .moveTo: path.move(to: points[0])
            case .lineTo: path.addLine(to: points[0])
            case .curveTo, .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: path.addQuadCurve(to: points[1], control: points[0])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}

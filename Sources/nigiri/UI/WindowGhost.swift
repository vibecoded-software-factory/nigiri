import AppKit
import CoreVideo

// niri's `window-close` animation, as far as macOS actually allows.
//
// niri runs it as a shader over the closing window's own texture, which it
// still owns after the client is gone (the user's config dissolves it with
// per-channel glitch offsets and scanlines). No public macOS API hands us
// another process's surface, and by the time the window is GONE - which is
// when we learn about it, through AXUIElementDestroyedNotification - there is
// nothing left to capture.
//
// What is reachable: a snapshot taken while the window was still alive,
// replayed in our own borderless window at the frame the window last held,
// scaled down and faded out on the configured curve. The close is the viable
// half of the pair for exactly that reason - the open would need a texture of
// a window that does not exist yet, which is not a latency problem but a
// causality one.
//
// Without a snapshot (a window that closed before ever being focused) the
// ghost still plays, as a flat card in the same shape: the point of the
// animation is that the slot does not blink out while its neighbours slide
// into place.
@MainActor
final class WindowGhost {
    // Ghosts are transient and can overlap (closing two windows quickly), so
    // each play gets its own window, retained here only until it settles.
    private var inFlight: [NSWindow] = []
    // The pixel buffer behind each ghost's surface, held for exactly as long
    // as the ghost is on screen.
    private var retainedBuffers: [ObjectIdentifier: CVPixelBuffer] = [:]

    // `contents` is whatever a layer can show - an IOSurface from the
    // snapshot's pixel buffer, which is why `retaining` comes with it: the
    // buffer has to outlive the animation or the surface can be recycled
    // under the ghost.
    func play(contents: Any?, retaining buffer: CVPixelBuffer?, axFrame: CGRect, curve: AnimationCurve) {
        if case .off = curve { return }
        spawn(contents: contents, retaining: buffer, axFrame: axFrame, curve: curve)
    }

    private func spawn(
        contents: Any?, retaining buffer: CVPixelBuffer?, axFrame: CGRect, curve: AnimationCurve
    ) {
        guard axFrame.width > 2, axFrame.height > 2 else { return }
        let window = NSWindow(
            contentRect: ScreenGeometry.axFrameToAppKit(axFrame),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        // A decoration of a window, and of one that is on its way out: below
        // nigiri's own panels, and below the focus ring that is already
        // moving to whatever gets focused next.
        window.level = ChromeLevel.decoration
        window.collectionBehavior = [.stationary, .ignoresCycle]

        let view = NSView(frame: CGRect(origin: .zero, size: axFrame.size))
        view.wantsLayer = true
        view.layer?.cornerRadius = macOSWindowCornerRadius
        view.layer?.masksToBounds = true
        if let contents {
            view.layer?.contents = contents
            view.layer?.contentsGravity = .resize
        } else {
            view.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.9).cgColor
            view.layer?.borderWidth = 1
            view.layer?.borderColor = NSColor(calibratedWhite: 0.3, alpha: 1).cgColor
        }
        window.contentView = view
        window.orderFront(nil)
        inFlight.append(window)
        if let buffer { retainedBuffers[ObjectIdentifier(window)] = buffer }

        // Shrink slightly toward its own centre while fading: niri's built-in
        // close (the one without a custom shader) is a scale-down plus alpha,
        // and that is the part of it that ports.
        guard let layer = view.layer,
            let scale = curve.coreAnimation(keyPath: "transform"),
            let fade = curve.coreAnimation(keyPath: "opacity")
        else {
            finish(window)
            return
        }
        scale.fromValue = CATransform3DIdentity
        scale.toValue = CATransform3DMakeScale(0.85, 0.85, 1)
        scale.fillMode = .forwards
        scale.isRemovedOnCompletion = false
        fade.fromValue = 1
        fade.toValue = 0
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.finish(window) }
        }
        layer.add(scale, forKey: "nigiri.ghost.scale")
        layer.add(fade, forKey: "nigiri.ghost.fade")
        CATransaction.commit()
    }

    private func finish(_ window: NSWindow) {
        window.orderOut(nil)
        inFlight.removeAll { $0 === window }
        retainedBuffers.removeValue(forKey: ObjectIdentifier(window))
    }

}

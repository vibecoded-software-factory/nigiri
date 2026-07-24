import QuartzCore

// nigiri's configured curves (niri's `animations` section) as Core Animation
// ones, for the animations that move OUR OWN layers - the overview's zoom, a
// closing window's ghost. Those run on the render server, unlike the window
// animator, which has to write frames to other processes over AX and
// therefore drives itself from a timer.
//
// A spring maps exactly: niri's mass is 1, so its stiffness carries over
// as-is and its damping RATIO becomes CA's damping COEFFICIENT, c = 2ζ√k.
extension AnimationCurve {
    func coreAnimation(keyPath: String) -> CABasicAnimation? {
        switch self {
        case .off:
            return nil
        case .spring(let spring):
            let animation = CASpringAnimation(keyPath: keyPath)
            animation.mass = 1
            animation.stiffness = spring.omega0 * spring.omega0
            animation.damping = 2 * spring.dampingRatio * spring.omega0
            animation.duration = animation.settlingDuration
            return animation
        case .easing(let easing):
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.duration = max(1, easing.durationMs) / 1000
            switch easing.curve {
            case .linear:
                animation.timingFunction = CAMediaTimingFunction(name: .linear)
            case .cubicBezier(let x1, let y1, let x2, let y2):
                animation.timingFunction = CAMediaTimingFunction(
                    controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
            // The power curves have EXACT cubic-bezier forms (x controls
            // 1/3, 2/3 make x(u) = u; y controls match the polynomial), so
            // nothing is approximated - the generic .easeOut stand-in bent
            // them (audit ANI-10). Only expo has no cubic form; its
            // approximation is the standard one and says so.
            case .easeOutQuad:
                animation.timingFunction = CAMediaTimingFunction(
                    controlPoints: 1.0 / 3.0, 2.0 / 3.0, 2.0 / 3.0, 1)
            case .easeOutCubic:
                animation.timingFunction = CAMediaTimingFunction(
                    controlPoints: 1.0 / 3.0, 1, 2.0 / 3.0, 1)
            case .easeOutExpo:
                animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            }
            return animation
        }
    }
}

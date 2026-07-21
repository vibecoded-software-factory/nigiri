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
            case .easeOutQuad, .easeOutCubic, .easeOutExpo:
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            }
            return animation
        }
    }
}

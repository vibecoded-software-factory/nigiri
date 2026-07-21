import Foundation

// niri's animation/spring.rs, as a pure value: a damped harmonic oscillator
// released from rest (zero initial velocity), normalized so the remaining
// displacement goes 1 -> 0.
//
// Mass is 1, like niri's, so omega0 = sqrt(stiffness). The damping ratio
// picks the regime:
//   < 1  underdamped       - overshoots and rings (niri's own default is 1)
//   = 1  critically damped - fastest approach with no overshoot
//   > 1  overdamped        - slower, no overshoot
//
// Only the critically damped case used to exist here, so a configured
// damping-ratio of 0.9 was silently unreachable.
struct Spring {
    let omega0: Double
    let dampingRatio: Double
    // niri's epsilon: how close to the target counts as arrived.
    let epsilon: Double

    init(stiffness: Double, dampingRatio: Double = 1.0, epsilon: Double = 0.0001) {
        omega0 = stiffness.squareRoot()
        self.dampingRatio = max(0.05, dampingRatio)
        self.epsilon = max(1e-6, epsilon)
    }

    // Fraction of the original displacement still remaining at `elapsed`
    // seconds. A caller multiplies it by (start - target) to get the current
    // offset from the target. Underdamped this CAN go negative - that is the
    // overshoot, and it is the point of a ratio below 1.
    func remainingFraction(at elapsed: TimeInterval) -> Double {
        let t = max(0, elapsed)
        let z = dampingRatio
        if abs(z - 1) < 1e-6 {
            return (1 + omega0 * t) * exp(-omega0 * t)
        }
        if z < 1 {
            let wd = omega0 * (1 - z * z).squareRoot()
            return exp(-z * omega0 * t) * (cos(wd * t) + (z * omega0 / wd) * sin(wd * t))
        }
        // Overdamped: two real roots, weighted so x(0) = 1 and x'(0) = 0.
        let root = omega0 * (z * z - 1).squareRoot()
        let r1 = -z * omega0 + root
        let r2 = -z * omega0 - root
        let c1 = -r2 / (r1 - r2)
        let c2 = r1 / (r1 - r2)
        return c1 * exp(r1 * t) + c2 * exp(r2 * t)
    }

    // Settled when the motion's envelope has decayed past epsilon - the
    // value alone is not enough, since an underdamped spring passes through
    // zero on its way.
    func hasSettled(at elapsed: TimeInterval) -> Bool {
        exp(-dampingRatio * omega0 * max(0, elapsed)) < epsilon
    }
}

// niri's easing animations: a duration and a named curve (Configuration:
// Animations).
struct Easing {
    enum Curve: Equatable {
        case linear
        case easeOutQuad
        case easeOutCubic
        case easeOutExpo
        case cubicBezier(Double, Double, Double, Double)

        static func named(_ name: String) -> Curve? {
            switch name {
            case "linear": return .linear
            case "ease-out-quad": return .easeOutQuad
            case "ease-out-cubic": return .easeOutCubic
            case "ease-out-expo": return .easeOutExpo
            default: return nil
            }
        }
    }

    let durationMs: Double
    let curve: Curve

    // Same contract as Spring.remainingFraction: 1 at t=0, 0 once done.
    func remainingFraction(at elapsed: TimeInterval) -> Double {
        let duration = max(1, durationMs) / 1000
        let t = min(1, max(0, elapsed / duration))
        let progress: Double
        switch curve {
        case .linear: progress = t
        case .easeOutQuad: progress = 1 - (1 - t) * (1 - t)
        case .easeOutCubic: progress = 1 - pow(1 - t, 3)
        case .easeOutExpo: progress = t >= 1 ? 1 : 1 - pow(2, -10 * t)
        case .cubicBezier(_, let y1, _, let y2):
            // Solving the x-axis parameter is overkill for frame
            // interpolation; the control points' y values carry the shape.
            let u = 1 - t
            progress = 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t
        }
        return 1 - progress
    }

    func hasSettled(at elapsed: TimeInterval) -> Bool {
        elapsed >= max(1, durationMs) / 1000
    }
}

// One configured animation: niri lets each be a spring, an easing, or off.
enum AnimationCurve {
    case spring(Spring)
    case easing(Easing)
    case off

    func remainingFraction(at elapsed: TimeInterval) -> Double {
        switch self {
        case .spring(let s): return s.remainingFraction(at: elapsed)
        case .easing(let e): return e.remainingFraction(at: elapsed)
        case .off: return 0
        }
    }
    func hasSettled(at elapsed: TimeInterval) -> Bool {
        switch self {
        case .spring(let s): return s.hasSettled(at: elapsed)
        case .easing(let e): return e.hasSettled(at: elapsed)
        case .off: return true
        }
    }
}

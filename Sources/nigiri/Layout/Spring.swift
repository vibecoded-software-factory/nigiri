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
    // niri's initial_velocity, in normalized displacement per second (the
    // gesture trackers inject it upstream; zero everywhere until ANI-2).
    let initialVelocity: Double
    // Solved once at init - niri's Spring::duration() (spring.rs:47-106).
    let settleSeconds: Double

    init(stiffness: Double, dampingRatio: Double = 1.0, epsilon: Double = 0.0001, initialVelocity: Double = 0)
    {
        omega0 = stiffness.squareRoot()
        // Upstream clamps only at zero (SpringParams::new, spring.rs:20-23);
        // the RANGES are the config parser's job, like niri's. The old
        // floors (0.05 / 1e-6) were invented.
        self.dampingRatio = max(0, dampingRatio)
        self.epsilon = max(0, epsilon)
        self.initialVelocity = initialVelocity
        settleSeconds = Self.solveSettleTime(
            omega0: omega0, dampingRatio: self.dampingRatio, epsilon: self.epsilon,
            initialVelocity: initialVelocity)
    }

    // Fraction of the original displacement still remaining at `elapsed`
    // seconds - niri's oscillate() (spring.rs:139-177) normalized to
    // x0 = 1. A caller multiplies it by (start - target) to get the current
    // offset from the target. Underdamped this CAN go negative - that is the
    // overshoot, and it is the point of a ratio below 1.
    func remainingFraction(at elapsed: TimeInterval) -> Double {
        Self.oscillate(
            t: max(0, elapsed), omega0: omega0, dampingRatio: dampingRatio, v0: initialVelocity)
    }

    private static func oscillate(t: Double, omega0: Double, dampingRatio: Double, v0: Double) -> Double {
        let beta = dampingRatio * omega0
        let envelope = exp(-beta * t)
        if abs(beta - omega0) <= Double(Float.ulpOfOne) {
            // Critically damped.
            return envelope * (1 + (beta + v0) * t)
        }
        if beta < omega0 {
            // Underdamped.
            let omega1 = (omega0 * omega0 - beta * beta).squareRoot()
            return envelope * (cos(omega1 * t) + ((beta + v0) / omega1) * sin(omega1 * t))
        }
        // Overdamped - upstream's cosh/sinh form, v0 included.
        let omega2 = (beta * beta - omega0 * omega0).squareRoot()
        return envelope * (cosh(omega2 * t) + ((beta + v0) / omega2) * sinh(omega2 * t))
    }

    // niri's Spring::duration(): the envelope estimate for the critical and
    // underdamped regimes, and NEWTON iteration on the real oscillation for
    // the overdamped one - which decays much slower than its envelope, so
    // the envelope check ended those springs early (audit ANI-9).
    private static func solveSettleTime(
        omega0: Double, dampingRatio: Double, epsilon: Double, initialVelocity: Double
    ) -> Double {
        let beta = dampingRatio * omega0
        guard beta > .ulpOfOne, epsilon > 0 else { return .infinity }
        var x0 = -log(epsilon) / beta
        if abs(beta - omega0) <= Double(Float.ulpOfOne) || beta < omega0 { return x0 }
        let delta = 0.001
        func f(_ t: Double) -> Double {
            oscillate(t: t, omega0: omega0, dampingRatio: dampingRatio, v0: initialVelocity)
        }
        var y0 = f(x0)
        var m = (f(x0 + delta) - y0) / delta
        var x1 = (-y0 + m * x0) / m
        var y1 = f(x1)
        var i = 0
        while abs(y1) > epsilon {
            if i > 1000 { return 0 }
            x0 = x1
            y0 = y1
            m = (f(x0 + delta) - y0) / delta
            x1 = (-y0 + m * x0) / m
            y1 = f(x1)
            if !y1.isFinite { return x0 }
            i += 1
        }
        return x1
    }

    // niri's Spring::clamped_duration() (spring.rs:109-137): the first
    // moment the value REACHES the target side of epsilon, probed at 1ms
    // steps starting from 1 - nil past 3000ms, like upstream.
    func clampedSettleTime() -> Double? {
        let beta = dampingRatio * omega0
        guard beta > .ulpOfOne else { return .infinity }
        var i = 1
        var y = remainingFraction(at: Double(i) / 1000)
        while y > epsilon {
            if i > 3000 { return nil }
            i += 1
            y = remainingFraction(at: Double(i) / 1000)
        }
        return Double(i) / 1000
    }

    // Settled when the true oscillation has decayed past epsilon - solved
    // once at init; the per-tick check is a comparison.
    func hasSettled(at elapsed: TimeInterval) -> Bool {
        elapsed >= settleSeconds
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
        case .cubicBezier(let x1, let y1, let x2, let y2):
            // The CSS definition, like niri (src/animation/bezier.rs): t is
            // the PARAMETER, not the time - solve t for x by bisection, then
            // evaluate y. Evaluating y at the raw time (the old shortcut)
            // only matches when x1=1/3 and x2=2/3; any other bezier animated
            // a different curve than the one configured.
            progress = Easing.cubicBezierY(x1: x1, y1: y1, x2: x2, y2: y2, at: t)
        }
        return 1 - progress
    }

    // niri's CubicBezier::y (src/animation/bezier.rs:29-60, itself from
    // libadwaita): bisection over x_for_t, 31 iterations, then y_for_t.
    static func cubicBezierY(x1: Double, y1: Double, x2: Double, y2: Double, at x: Double) -> Double {
        if x <= .ulpOfOne { return 0 }
        if x >= 1 - .ulpOfOne { return 1 }
        func xForT(_ t: Double) -> Double {
            let omt = 1 - t
            return 3 * omt * omt * t * x1 + 3 * omt * t * t * x2 + t * t * t
        }
        var minT = 0.0
        var maxT = 1.0
        for _ in 0...30 {
            let guessT = (minT + maxT) / 2
            if x < xForT(guessT) { maxT = guessT } else { minT = guessT }
        }
        let t = (minT + maxT) / 2
        let omt = 1 - t
        return 3 * omt * omt * t * y1 + 3 * omt * t * t * y2 + t * t * t
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

    // niri's per-animation defaults, verbatim from each *Anim's Default
    // impl in niri-config/src/animations.rs:130-330. Lives here (pure
    // layer) because both the engine's curve resolution AND the config
    // parser need it: niri fills a half-specified easing from the
    // animation's own default (animations.rs:734-748).
    static let defaults: [String: AnimationCurve] = [
        "workspace-switch": .spring(Spring(stiffness: 1000)),
        "window-open": .easing(Easing(durationMs: 150, curve: .easeOutExpo)),
        "window-close": .easing(Easing(durationMs: 150, curve: .easeOutQuad)),
        "horizontal-view-movement": .spring(Spring(stiffness: 800)),
        "window-movement": .spring(Spring(stiffness: 800)),
        "window-resize": .spring(Spring(stiffness: 800)),
        "config-notification-open-close": .spring(
            Spring(stiffness: 1000, dampingRatio: 0.6, epsilon: 0.001)),
        "exit-confirmation-open-close": .spring(
            Spring(stiffness: 500, dampingRatio: 0.6, epsilon: 0.01)),
        "screenshot-ui-open": .easing(Easing(durationMs: 200, curve: .easeOutQuad)),
        "overview-open-close": .spring(Spring(stiffness: 800)),
        "recent-windows-close": .spring(Spring(stiffness: 800, dampingRatio: 1.0, epsilon: 0.001)),
    ]
}

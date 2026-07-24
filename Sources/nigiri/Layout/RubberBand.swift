import CoreGraphics

// niri's rubber_band.rs, function for function: the resistance curve that
// lets a gesture overshoot its bounds with diminishing returns instead of
// stopping dead. band() maps an out-of-bounds distance to a displacement
// that asymptotically approaches `limit`; derivative() is its slope (used
// to carry velocity across the boundary so the overshoot doesn't jerk);
// clamp() applies the band past either end of a range, and
// clampDerivative() the matching slope (1 inside the range).
//
// Consumers are the continuous gesture trackers (audit ANI-2: workspace
// switch, overview) and the interactive-move start threshold (audit ANI-5),
// with upstream's constants: WORKSPACE_GESTURE_RUBBER_BAND and
// OVERVIEW_GESTURE_RUBBER_BAND are both { stiffness: 0.5, limit: 0.05 }
// (monitor.rs:38-41, layout/mod.rs:105-108) - the workspace one has its
// limit divided by the overview zoom while zoomed out (monitor.rs:1865-1866)
// - and the interactive-move threshold band is { stiffness: 1.0, limit: 0.5 }
// (layout/mod.rs:3888-3892).
struct RubberBand {
    var stiffness: CGFloat
    var limit: CGFloat

    static let workspaceGesture = RubberBand(stiffness: 0.5, limit: 0.05)
    static let overviewGesture = RubberBand(stiffness: 0.5, limit: 0.05)
    static let interactiveMoveStart = RubberBand(stiffness: 1.0, limit: 0.5)

    func band(_ x: CGFloat) -> CGFloat {
        let c = stiffness
        let d = limit
        return (1 - (1 / (x * c / d + 1))) * d
    }

    func derivative(_ x: CGFloat) -> CGFloat {
        let c = stiffness
        let d = limit
        return c * d * d / pow(c * x + d, 2)
    }

    func clamp(_ min: CGFloat, _ max: CGFloat, _ x: CGFloat) -> CGFloat {
        let clamped = Swift.min(Swift.max(x, min), max)
        let sign: CGFloat = x < clamped ? -1 : 1
        let diff = abs(x - clamped)
        return clamped + sign * band(diff)
    }

    func clampDerivative(_ min: CGFloat, _ max: CGFloat, _ x: CGFloat) -> CGFloat {
        if min <= x && x <= max { return 1 }
        let clamped = Swift.min(Swift.max(x, min), max)
        let diff = abs(x - clamped)
        return derivative(diff)
    }
}

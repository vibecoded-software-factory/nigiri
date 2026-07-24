import CoreGraphics
import Foundation

// niri's input/swipe_tracker.rs, function for function: accumulates raw
// gesture deltas, answers the current position, the velocity over the last
// 150ms of history, and where the gesture would land after decelerating at
// the touchpad rate (0.997 per ms) - the number the end-of-gesture snapping
// runs on. Timestamps are seconds (upstream Durations), monotonically
// increasing; an out-of-order reading is dropped like upstream's trace path.
struct SwipeTracker {
    static let historyLimit: TimeInterval = 0.150
    static let decelerationTouchpad = 0.997

    private struct Event {
        let delta: CGFloat
        let timestamp: TimeInterval
    }
    private var history: [Event] = []
    private(set) var pos: CGFloat = 0

    mutating func push(_ delta: CGFloat, timestamp: TimeInterval) {
        if let last = history.last, timestamp < last.timestamp { return }
        history.append(Event(delta: delta, timestamp: timestamp))
        pos += delta
        trimHistory()
    }

    func velocity() -> CGFloat {
        guard let first = history.first, let last = history.last else { return 0 }
        let totalTime = last.timestamp - first.timestamp
        guard totalTime != 0 else { return 0 }
        let totalDelta = history.reduce(0) { $0 + $1.delta }
        return totalDelta / totalTime
    }

    // Upstream: pos - vel / (1000 * ln(0.997)). Velocity there is px/sec and
    // the deceleration rate is per millisecond, hence the 1000.
    func projectedEndPos() -> CGFloat {
        pos - velocity() / (1000 * log(Self.decelerationTouchpad))
    }

    private mutating func trimHistory() {
        guard let last = history.last else { return }
        while let first = history.first, last.timestamp > first.timestamp + Self.historyLimit {
            history.removeFirst()
        }
    }
}

// The constants every consumer shares, niri's names kept:
// monitor.rs:29-41 and layout/mod.rs:97-108.
enum GestureConstants {
    // A workspace switch takes 300px of (1000dpi-normalized) finger travel.
    static let workspaceGestureMovement: CGFloat = 300
    // A full working-area width of view scroll takes 1200px of travel
    // (scrolling.rs:31, VIEW_GESTURE_WORKING_AREA_MOVEMENT).
    static let viewGestureWorkingAreaMovement: CGFloat = 1200
    // The overview open/close gesture also spans 300px (layout/mod.rs:103).
    static let overviewGestureMovement: CGFloat = 300
    // The 3-finger axis lock: 16px of travel decides horizontal vs vertical
    // ("Threshold copied from GNOME Shell", input/mod.rs:3912).
    static let axisLockThreshold: CGFloat = 16
}

// monitor.rs WorkspaceSwitchGesture, the fields that exist here: the
// tracker plus where the gesture started. The visual mid-gesture slide
// cannot exist on macOS (other workspaces' windows are parked off-screen,
// AX cannot render them mid-flight), so only upstream's DECISION math runs:
// position, rubber-banded clamping, velocity projection and the final
// rounded index - the animated switch then plays through focusWorkspace.
struct WorkspaceSwitchGestureState {
    var tracker = SwipeTracker()
    let centerIdx: Int

    // min_max with is_clamped = true (monitor.rs:240-248): a touchpad
    // gesture outside the overview reaches at most one workspace either way.
    func minMax(workspaceCount: Int) -> (CGFloat, CGFloat) {
        (CGFloat(max(0, centerIdx - 1)), CGFloat(min(centerIdx + 1, max(0, workspaceCount - 1))))
    }

    // The rubber-banded current index (monitor.rs:1865-1880, zoom = 1).
    func currentIdx(workspaceCount: Int) -> CGFloat {
        let pos = tracker.pos / GestureConstants.workspaceGestureMovement
        let (lo, hi) = minMax(workspaceCount: workspaceCount)
        return RubberBand.workspaceGesture.clamp(lo, hi, CGFloat(centerIdx) + pos)
    }

    // The workspace the gesture lands on (monitor.rs workspace_switch_
    // gesture_end): projected end position, hard-clamped, rounded.
    func endIdx(workspaceCount: Int) -> Int {
        let pos = tracker.projectedEndPos() / GestureConstants.workspaceGestureMovement
        let (lo, hi) = minMax(workspaceCount: workspaceCount)
        let idx = min(max(CGFloat(centerIdx) + pos, lo), hi)
        return Int(idx.rounded())
    }
}

// scrolling.rs ViewGesture: the tracker plus the view offset the gesture
// started from. norm_factor scales finger travel so 1200px sweeps one
// working-area width (view_offset_gesture_update, scrolling.rs:3075-3078).
struct ViewGestureState {
    var tracker = SwipeTracker()
    let deltaFromTracker: CGFloat

    func currentViewOffset(usableWidth: CGFloat) -> CGFloat {
        let normFactor = usableWidth / GestureConstants.viewGestureWorkingAreaMovement
        return tracker.pos * normFactor + deltaFromTracker
    }

    func projectedViewOffset(usableWidth: CGFloat) -> CGFloat {
        let normFactor = usableWidth / GestureConstants.viewGestureWorkingAreaMovement
        return tracker.projectedEndPos() * normFactor + deltaFromTracker
    }
}

// The view-offset snapping of view_offset_gesture_end (scrolling.rs:
// 3197-3325), in nigiri's viewOffset space (offset = p.x aligns the column
// with the working area's left edge): each column contributes its left and
// right alignment, the target is clamped between the first column's left
// snap and the last column's right snap, and the nearest snap wins. Pure,
// so SelfTest can hold it to upstream's cases.
enum ViewGestureSnapping {
    struct Snap {
        let viewPos: CGFloat
        let colIdx: Int
    }

    static func snappingPoints(
        placements: [ColumnLayoutEngine.Placement], usableWidth: CGFloat
    )
        -> [Snap]
    {
        var points: [Snap] = []
        for (idx, p) in placements.enumerated() {
            points.append(Snap(viewPos: p.x, colIdx: idx))
            points.append(Snap(viewPos: p.x + p.width - usableWidth, colIdx: idx))
        }
        return points
    }

    static func snap(
        target: CGFloat, placements: [ColumnLayoutEngine.Placement], usableWidth: CGFloat
    )
        -> Snap?
    {
        let points = snappingPoints(placements: placements, usableWidth: usableWidth)
        guard let first = placements.first, let last = placements.last else { return nil }
        // "Prevent the gesture from snapping further than the first/last
        // column" (scrolling.rs:3302-3306). leftmost > rightmost is fine
        // when the columns total less than the view; min/max absorbs it.
        let leftmost = first.x
        let rightmost = last.x + last.width - usableWidth
        let clamped = min(max(target, min(leftmost, rightmost)), max(leftmost, rightmost))
        return points.min { abs($0.viewPos - clamped) < abs($1.viewPos - clamped) }
    }
}

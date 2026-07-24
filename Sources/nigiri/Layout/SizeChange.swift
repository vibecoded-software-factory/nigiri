import CoreGraphics

// niri's SizeChange (niri-ipc), the argument type of set-column-width /
// set-window-height / set-window-width. Four forms, and the distinction is
// load-bearing: an argument that STARTS with + or - adjusts the current
// value, anything else SETS it outright; a trailing % means a proportion of
// the working area, its absence means fixed pixels.
//
//   "50%"   -> setProportion(50)     make it half the working area
//   "+10%"  -> adjustProportion(10)  ten points wider than it is now
//   "1000"  -> setFixed(1000)        exactly 1000 px
//   "-100"  -> adjustFixed(-100)     100 px narrower than it is now
//
// nigiri used to strip the sign and the % and always adjust, so a config
// copied from niri would silently do something else - `set-column-width
// "50%"` GREW the column by half instead of setting it to half.
enum SizeChange {
    case setProportion(CGFloat)
    case adjustProportion(CGFloat)
    case setFixed(CGFloat)
    case adjustFixed(CGFloat)

    // niri's floating set_window_width/set_window_height, one axis
    // (src/layout/floating.rs:744-830): the SET forms are ABSOLUTE -
    // SetFixed is exact pixels, SetProportion that share of the WORKING
    // AREA - and only the Adjust forms are deltas (AdjustFixed in pixels,
    // AdjustProportion in points of proportion of the working area).
    // Result rounded and clamped to [1, 100000] exactly like upstream; the
    // min/max-size clamp niri applies next has no AX equivalent - the
    // window itself refuses, and the refusal is memoized at the boundary.
    //
    // This replaces `asFloatingDelta`, which collapsed all four forms into
    // one delta: `set-column-width "50%"` GREW a floating window by half
    // the screen instead of setting it to half - the exact bug the header
    // above records as fixed for the tiled path, reintroduced floating.
    func resolvedFloating(current: CGFloat, available: CGFloat) -> CGFloat {
        let maxPx: CGFloat = 100000
        let maxProp: CGFloat = 10000
        let value: CGFloat
        switch self {
        case .setFixed(let px):
            value = px
        case .setProportion(let p):
            value = available * min(max(p / 100, 0), maxProp)
        case .adjustFixed(let d):
            value = current + d
        case .adjustProportion(let d):
            let prop = min(max(current / available + d / 100, 0), maxProp)
            value = available * prop
        }
        return min(max(value.rounded(), 1), maxPx)
    }

}

extension SizeChange {
    // niri's four forms; nil when the argument is not a size at all.
    static func parse(_ raw: String) -> SizeChange? {
        let isAdjust = raw.hasPrefix("+") || raw.hasPrefix("-")
        let isProportion = raw.hasSuffix("%")
        let number = raw.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "+", with: "")
        guard let value = Double(number).map({ CGFloat($0) }) else { return nil }
        switch (isAdjust, isProportion) {
        case (true, true): return .adjustProportion(value)
        case (true, false): return .adjustFixed(value)
        case (false, true): return .setProportion(value)
        case (false, false): return .setFixed(value)
        }
    }
}

extension SizeChange: CustomStringConvertible {
    var description: String {
        switch self {
        case .setProportion(let p): return "\(Int(p))%"
        case .adjustProportion(let d): return "\(d > 0 ? "+" : "")\(Int(d))%"
        case .setFixed(let px): return "\(Int(px))px"
        case .adjustFixed(let px): return "\(px > 0 ? "+" : "")\(Int(px))px"
        }
    }
}

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

    // Floating windows are resized by a plain percentage delta of their own
    // current size (they have no column proportion to speak of), so the
    // absolute forms are interpreted as "go to that percentage".
    var asFloatingDelta: CGFloat {
        switch self {
        case .adjustProportion(let d), .setProportion(let d): return d
        case .adjustFixed(let px), .setFixed(let px): return px
        }
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

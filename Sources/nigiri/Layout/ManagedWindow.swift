import AppKit
import ApplicationServices

// One managed window: its AX element, title, and the layout bookkeeping
// (manual height, last requested/actual frame, stash, write-latency EMA).
// niri: layout/tile.rs.
final class ManagedWindow {
    let axElement: AXUIElement
    let pid: pid_t
    var title: String
    // nil = Auto (splits whatever height its column's Auto windows share,
    // matching niri's WindowHeight::Auto) - set by set-window-height, a
    // fixed pixel height like niri's WindowHeight::Fixed(px); cleared back
    // to nil by reset-window-height.
    var manualHeightPx: CGFloat? = nil
    // niri's WindowHeight::Auto { weight }: an Auto window takes its share
    // of the column IN PROPORTION to this, not an equal slice. Without it,
    // consuming or expelling a sibling re-equalized the whole stack and a
    // deliberately tall window silently lost its ratio.
    var heightWeight: CGFloat = 1
    // Probed once per relayout by collectCurrentAXWindows. The animator used
    // to re-ask AX on every write (a 0.046ms IPC round-trip, twice per window
    // per tick at 120Hz) for an answer that does not change.
    var positionSettable = true
    // When collectCurrentAXWindows last probed this window's shape (subrole,
    // close button, settable-ness) rather than taking the cached answer.
    var lastFullProbe = Date.distantPast
    // Latched so a window that refuses writes is reported once, not on every
    // animation tick.
    var warnedUnwritable = false
    // Consecutive position writes this window answered with "not settable".
    // A window CAN start settable and stop being it (an Open panel probed as
    // movable at adoption, then refused every write and held a column slot
    // forever - the ghost gap in the strip, reported live). Reset by the
    // first write it accepts, so only a persistent refusal counts.
    var positionRefusals = 0
    private var lastRefusalAt = Date.distantPast
    // A refusal only counts once per second. Three separate apps were seen
    // refusing a position write DURING a burst of width presses and then
    // accepting the next one - transient, not a window that cannot be moved.
    // Counting every refusal in a burst would demote an ordinary terminal to
    // the floating layer for being busy.
    func notePositionRefusal() {
        guard Date().timeIntervalSince(lastRefusalAt) > 1 else { return }
        lastRefusalAt = Date()
        positionRefusals += 1
    }
    // Where a FLOATING window lived before a fullscreen shoved it off to the
    // right edge. Its own slot, not stashedFrame: that one belongs to the
    // workspace switch, which overwrites it with wherever the window is NOW -
    // and during a fullscreen that is the 1px parking spot, so the real home
    // was lost and the window came back stranded at the screen edge. One slot
    // with two producers of different lifetimes is one too few.
    var fullscreenHome: CGRect? = nil
    // The last frame a layout/animation pass asked this window to take, and
    // the frame the app actually settled at in response. Not necessarily
    // equal: apps enforce their own minimum sizes, and macOS silently clamps
    // any position that would leave a window (nearly) fully off-screen -
    // both verified live. The pair lets every writer recognize "this exact
    // request was already made, and this is the app's answer" and skip
    // re-fighting a refusal it can never win. Without this, every layout
    // pass rewrites the same refused frame, generating a self-inflicted
    // moved/resized notification that triggers the next relayout - an
    // infinite loop - and every relayout re-animates off-screen windows
    // from their clamped position toward an unreachable target (visible as
    // partially-clamped windows endlessly "dancing").
    var lastRequestedFrame: CGRect? = nil {
        didSet { frameMemoEpoch = ColumnLayoutEngine.epoch }
    }
    var lastActualFrame: CGRect? = nil
    private(set) var frameMemoEpoch = 0
    // The pair is only trusted within the epoch that recorded it.
    var refusalMemo: (requested: CGRect, actual: CGRect)? {
        guard frameMemoEpoch == ColumnLayoutEngine.epoch,
              let requested = lastRequestedFrame, let actual = lastActualFrame else { return nil }
        return (requested, actual)
    }
    // True for windows adopted as dialogs (no close button, or fixed-size -
    // see CollectedKind). They live in the floating layer and can never be
    // moved INTO the tiled columns: tiling one means fighting a window that
    // refuses resizing/repositioning on every layout pass.
    var isDialog: Bool = false
    // True only when the dialog classification ALONE put this window in the
    // floating layer (no window-rule, no manual toggle-window-floating). The
    // probe behind that classification is a live AX read taken while the
    // window is still mapping, so a perfectly normal window can transiently
    // read as fixed-size / close-button-less and get latched as a dialog
    // forever - permanently floating, and toggle-window-floating refuses to
    // tile it back. This flag marks the ones a later, calmer probe is allowed
    // to reclassify; a window the USER floated must never be yanked back.
    var autoFloatedAsDialog: Bool = false
    // Where this window sat before being stashed to the screen corner by a
    // workspace switch - tiled windows get their position recomputed on
    // restore anyway, but floating windows have no other record of where
    // they belong.
    var stashedFrame: CGRect? = nil
    // Which preset this FLOATING window is currently sitting on, so
    // switch-preset-window-width cycles the list in order (niri's
    // preset_width_idx). Tiled windows use Column.presetWidthIndex.
    var presetWidthIndex: Int? = nil
    // Same idea for switch-preset-window-height (niri's preset_height_idx).
    var presetHeightIndex: Int? = nil
    // Consecutive relayouts in which this window was missing from its own
    // app's AX window list. A LIVE window can vanish from that list for a
    // scan - verified live: opening a second Alacritty window made the app
    // report only the new one for a beat, and the window running this very
    // session was purged from the model on that single miss (two windows on
    // screen, one column in the model, focus and titles pointing at the
    // wrong thing). Death now needs the miss to REPEAT; a dead process or an
    // .invalidUIElement answer is still immediate, no waiting.
    var absentFromAppListScans: Int = 0
    // Exponential moving average of how long this window's synchronous AX
    // frame writes take - a proxy for how heavy its app's event handling
    // is. The animator writes the slowest windows FIRST each tick, giving
    // their render pipeline the longest lead time, which reduces visible
    // phase lag between light and heavy windows moving together.
    var axWriteLatencyEMA: Double = 0

    // niri's stable window id: assigned once, never reused, and the only
    // handle an IPC client can hold onto (an AXUIElement is not sendable and
    // a pid is not unique per window).
    let id: UInt64 = { ManagedWindow.nextID += 1; return ManagedWindow.nextID }()
    nonisolated(unsafe) private static var nextID: UInt64 = 0

    init(axElement: AXUIElement, pid: pid_t, title: String) {
        self.axElement = axElement
        self.pid = pid
        self.title = title
    }
}

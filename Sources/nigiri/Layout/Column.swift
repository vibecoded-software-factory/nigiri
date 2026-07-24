import AppKit
import ApplicationServices

// A column: a vertical stack of windows sharing a width, with cached
// per-slot heights and the discovered minimum width. niri: the column in
// layout/scrolling.rs.
// niri's ColumnWidth (scrolling.rs:236-242).
enum ColumnWidth: Equatable {
    // Proportion of the current view width.
    case proportion(CGFloat)
    // Fixed width in logical pixels.
    case fixed(CGFloat)
}

extension ColumnWidth: CustomStringConvertible {
    var description: String {
        switch self {
        case .proportion(let p): return String(format: "%.0f%%", p * 100)
        case .fixed(let px): return "\(Int(px))px"
        }
    }
}

final class Column {
    // private(set) + mutators, for the same reason focusedWindowIndex is:
    // every membership change also has to drop cachedHeights (the per-slot
    // probe is indexed by the stack's shape) and re-clamp the row focus.
    // Both were hand-written at ~25 call sites, and the ones that forgot
    // left a stale height cache or a focus past the end - which is how the
    // overview's drop lost the focused window.
    private(set) var windows: [ManagedWindow] = []

    // Every mutation funnels here: cache dropped, focus re-clamped.
    private func mutate(_ body: (inout [ManagedWindow]) -> Void) {
        body(&windows)
        cachedHeights = nil
        clampFocus()
    }

    // A tile ENTERS a column as auto_1 (niri's add_tile, scrolling.rs:
    // 4297-4312): whatever manual height or weight it carried in its old
    // column does not travel. Without this an expelled window kept its
    // fixed height and would not fill its fresh single-window column, and
    // a consumed one kept a stale weight. Existing members' weights are
    // untouched - upstream does NOT re-equalize on membership changes.
    private func enterAsAuto(_ window: ManagedWindow) {
        window.manualHeightPx = nil
        window.heightWeight = 1
        window.presetHeightIndex = nil
    }

    func setWindows(_ new: [ManagedWindow]) {
        mutate {
            new.forEach(enterAsAuto)
            $0 = new
        }
    }
    func add(_ window: ManagedWindow) {
        enterAsAuto(window)
        mutate { $0.append(window) }
    }
    func insert(_ window: ManagedWindow, at index: Int) {
        enterAsAuto(window)
        mutate { $0.insert(window, at: min(max(0, index), $0.count)) }
    }
    // An IN-COLUMN reorder: the window never left, so its height data
    // travels with it - upstream's move_window_up/down swaps the data
    // entries alongside the tiles, resetting nothing.
    func reinsert(_ window: ManagedWindow, at index: Int) {
        mutate { $0.insert(window, at: min(max(0, index), $0.count)) }
    }
    @discardableResult
    func removeWindow(at index: Int) -> ManagedWindow? {
        guard windows.indices.contains(index) else { return nil }
        var removed: ManagedWindow?
        mutate { removed = $0.remove(at: index) }
        return removed
    }
    @discardableResult
    func remove(_ window: ManagedWindow) -> Bool {
        guard let index = windows.firstIndex(where: { $0 === window }) else { return false }
        removeWindow(at: index)
        return true
    }
    // Returns what left, and runs the predicate EXACTLY once per window.
    // It used to run through contains(where:) and then again through
    // removeAll(where:), which is only equivalent for a pure predicate - and
    // two call sites are not: the demotion collected into an array (so the
    // first match was appended twice, ending up tiled AND floating), and the
    // purge's isWindowDead bumps a consecutive-miss counter (so a window
    // could be declared dead in fewer passes than the counter claims).
    // Returning the removed windows is what lets those call sites keep their
    // predicate pure.
    @discardableResult
    func removeWindows(where predicate: (ManagedWindow) -> Bool) -> [ManagedWindow] {
        // Only touch the cache if something actually left: this runs on
        // every relayout, and dropping the heights each time would re-probe
        // a converged stack forever.
        let doomed = windows.filter(predicate)
        guard !doomed.isEmpty else { return [] }
        let leaving = Set(doomed.map(ObjectIdentifier.init))
        mutate { $0.removeAll { leaving.contains(ObjectIdentifier($0)) } }
        return doomed
    }
    func swapWindows(_ i: Int, _ j: Int) {
        guard windows.indices.contains(i), windows.indices.contains(j) else { return }
        mutate { $0.swapAt(i, j) }
    }
    func replaceWindow(at index: Int, with window: ManagedWindow) {
        guard windows.indices.contains(index) else { return }
        mutate { $0[index] = window }
    }
    // Which window in this column's vertical stack is focused - meaningful
    // once a column holds more than one window (consume-window-left/right).
    // private(set): every call site used to re-derive the same clamp by
    // hand (min(max(0, ...))), and the ones that forgot left focus pointing
    // past the end - focusedManagedWindow() then returns nil and every
    // action routed through it silently does nothing.
    private(set) var focusedWindowIndex: Int = 0

    // The only way to move it: always lands inside the array, or on 0 when
    // the column is empty.
    func focus(row: Int) {
        focusedWindowIndex = windows.isEmpty ? 0 : min(max(0, row), windows.count - 1)
    }
    func moveFocus(by delta: Int) { focus(row: focusedWindowIndex + delta) }
    var focusedWindow: ManagedWindow? {
        windows.indices.contains(focusedWindowIndex) ? windows[focusedWindowIndex] : nil
    }
    // After any mutation of `windows`.
    func clampFocus() { focus(row: focusedWindowIndex) }
    @discardableResult
    func focus(window: ManagedWindow) -> Bool {
        guard let idx = windows.firstIndex(where: { $0 === window }) else { return false }
        focus(row: idx)
        return true
    }
    // niri's toggle-column-tabbed-display: instead of a vertical stack, the
    // column shows ONE window (focusedWindowIndex) at full height under a
    // tab-bar overlay; the rest rest as 1px corner lines - the exact
    // workspace-stash technique, reused per-column.
    // layout { default-column-display "tabbed" }: the mode a fresh column
    // starts in. Static because columns are created in a dozen places that
    // have no config in hand.
    nonisolated(unsafe) static var defaultTabbed = false
    var isTabbed: Bool = Column.defaultTabbed
    // Per-slot heights from the last stack probe within this column - same
    // idea as ColumnLayoutEngine's viewOffset caching below: only ever
    // recomputed when this column's window count or order changes, not on
    // every relayout, so a converged stack doesn't get nudged back to a
    // naive equal share on every pass. Every site that invalidates this is
    // a stack-membership/order change, which also invalidates the probed
    // minimum width below - the didSet keeps the two in sync without every
    // call site having to remember both.
    var cachedHeights: [CGFloat]? = nil {
        didSet { if cachedHeights == nil { cachedMinWidth = nil } }
    }
    // The width this column requests, matching niri's ColumnWidth
    // (scrolling.rs:236-242): a proportion of the view, or FIXED logical
    // pixels - fixed survives gap and monitor changes instead of drifting
    // with them (audit LAY-6; px used to degrade to a proportion here).
    // Mutated by switch-preset-column-width and set-column-width.
    // Deliberately does NOT invalidate cachedMinWidth: the minimum is a
    // property of the WINDOWS (Discord's 800px floor exists no matter what
    // width is requested), so wiping it on every resize keypress made each
    // shrink re-fight the app's clamp from scratch - and until the
    // re-discovery settled, placements packed every neighbor against the
    // phantom requested width, overlapping the clamped window (verified
    // live).
    var width: ColumnWidth = .proportion(ColumnLayoutEngine.defaultColumnWidth)
    // niri's is_full_width (scrolling.rs:170): full width is a flag OF THE
    // COLUMN, so several columns can hold it at once and it travels with
    // the column through moves - the per-workspace maximizedIndex it
    // replaces allowed exactly one and needed re-anchoring in every
    // mutator (audit LAY-5).
    var isFullWidth = false
    // niri's is_pending_fullscreen / is_pending_maximized (scrolling.rs:
    // 171-175): fullscreen (raw output) and maximize-to-edges (working
    // area) are states OF THE COLUMN - they travel with it through moves
    // and workspace changes, and they die with it, where the per-workspace
    // window reference they replace had to be cancelled by hand in every
    // mutator (audit LAY-4). A tabbed column fullscreens whatever tab is
    // current, like upstream rendering the column's active tile.
    var isPendingFullscreen = false
    var isPendingMaximized = false
    // Index into ColumnLayoutEngine.presetColumnSizes if the width
    // currently matches a preset exactly (niri's preset_width_idx) - nil
    // once a manual ±10% adjustment moves it off a preset value.
    var presetWidthIndex: Int? = nil
    // The narrowest width this column's windows actually accept, discovered
    // by layout() when a window clamps itself wider than the width it was
    // asked to take (no AX attribute exposes an app's minimum size - it can
    // only be observed by asking and reading back). columnPlacements honors
    // it the way niri honors a window's min-width: the column widens to fit,
    // extending the scrollable strip, instead of overlapping its neighbor
    // and re-fighting the app's clamp on every pass, which never converges.
    var cachedMinWidth: CGFloat? = nil {
        didSet { cachedMinWidthEpoch = ColumnLayoutEngine.epoch }
    }
    private(set) var cachedMinWidthEpoch = 0
    // The floor is only believed within the epoch that measured it.
    var validMinWidth: CGFloat? {
        cachedMinWidthEpoch == ColumnLayoutEngine.epoch ? cachedMinWidth : nil
    }
    // From a window-rule's max-width (px): caps how wide set/preset-column-
    // width can grow this column. nil = no cap.
    var maxWidthPx: CGFloat? = nil
}

import AppKit
import ApplicationServices

// A workspace: a scrollable strip of columns plus a floating layer, with
// the camera (viewOffset), focus, and maximize state. Structural mutations
// funnel through insert/remove/swapColumn so maximizedIndex tracks along.
// niri: layout/workspace.rs.
final class Workspace {
    // Stable across reordering: move-workspace-up/down shuffles the array,
    // so the index is not an identity an IPC client can track.
    let id: UInt64 = {
        Workspace.nextID += 1; return Workspace.nextID
    }()
    nonisolated(unsafe) private static var nextID: UInt64 = 0

    // private(set): the structural mutators below keep focusedIndex pointing
    // at the SAME column across inserts and removals. It used to slide -
    // inserting before the focused column silently moved focus to its
    // neighbour, and removing one could leave the index past the end - which
    // is what made the overview's drop come out focused on a column the user
    // never picked.
    private(set) var columns: [Column] = []
    private(set) var focusedIndex: Int = 0
    func focus(column: Int) {
        // An explicit focus move cancels the pending "go back left": niri
        // clears the flag on the same events. Re-anchoring (clampFocus) is
        // NOT an explicit move, so it goes straight to the setter - through
        // here it would have cleared the flag one line after insertColumn set
        // it, since insert ends by re-anchoring.
        activatePreviousOnRemoval = false
        previousViewOffset = nil
        setFocusedIndex(column)
    }
    private func setFocusedIndex(_ index: Int) {
        focusedIndex = columns.isEmpty ? 0 : min(max(0, index), columns.count - 1)
    }
    func moveColumnFocus(by delta: Int) { focus(column: focusedIndex + delta) }
    // Take a window OUT of the tiled side: out of its column, collapsing the
    // column if it emptied, and cancelling fullscreen if it was the
    // fullscreen one. That last part is the invariant: `fullscreenWindow` and
    // membership of `floatingWindows` are two pieces of state nobody was
    // cross-checking, so Mod+F then Mod+V left a window that was BOTH - and
    // from then on every reflow took the fullscreen branch, failed to find it
    // among the tiled targets, appended it at raw screen size and shoved
    // every other window to the parking spot. The reactive cleanup elsewhere
    // could not catch it either: it fires on the window leaving the workspace,
    // and this one never left. niri cancels fullscreen the same way when a
    // window goes floating.
    @discardableResult
    func detachFromTiling(_ window: ManagedWindow) -> Bool {
        guard let ci = columns.firstIndex(where: { $0.windows.contains { $0 === window } }) else {
            return false
        }
        columns[ci].removeWindows { $0 === window }
        if columns[ci].windows.isEmpty { removeColumn(at: ci) }
        if fullscreenWindow === window { fullscreenWindow = nil }
        clampFocus()
        return true
    }

    func clampFocus() {
        setFocusedIndex(focusedIndex)
        for c in columns { c.clampFocus() }
        floatingFocusedIndex =
            floatingWindows.isEmpty ? 0 : min(max(0, floatingFocusedIndex), floatingWindows.count - 1)
        if floatingWindows.isEmpty { isFloatingActive = false }
    }
    @discardableResult
    func focus(column window: ManagedWindow) -> Bool {
        guard let ci = columns.firstIndex(where: { $0.windows.contains { $0 === window } }) else {
            return false
        }
        focus(column: ci)
        columns[ci].focus(window: window)
        isFloatingActive = false
        return true
    }
    // niri's named workspaces: a config-declared name (`workspace "chat"`)
    // that focus-workspace/move-column-to-workspace/open-on-workspace can
    // target by name as well as by number. nil for unnamed workspaces.
    var name: String? = nil

    // Every structural mutation of `columns` funnels through these three so
    // maximizedIndex shifts along with the column it refers to - raw
    // insert/remove/swapAt at each call site silently left it pointing at
    // whatever column slid into the old position (maximize column 2, move
    // it left, and suddenly column 2 - a different column - is the
    // maximized one). Callers keep their own focusedIndex bookkeeping:
    // focus semantics genuinely differ per action (follow the moved column,
    // stay on the source, jump to the new one), so centralizing that too
    // would just move every special case behind a flag parameter.
    // niri's activate_prev_column_on_removal: a column inserted RIGHT of the
    // focused one - which is where a newly opened window goes - remembers
    // that its removal should hand focus back to the LEFT, not to whatever
    // slid into its index. Without it, closing the window you just opened
    // left the ring on the column to the right and scrolled the strip there:
    // [A, N, B] with N focused, close N, focus stayed at index 1 which is now
    // B. niri stores the previous view offset there too; we only need the
    // "activate the previous one" half, since the camera follows focus.
    private var activatePreviousOnRemoval: Bool = false
    // The other half of niri's activate_prev_column_on_removal: the view
    // offset AS IT WAS before the new column opened, restored with the
    // focus so the camera lands exactly where the user left it instead of
    // wherever fitOffset re-derives from the restored focus. Valid with
    // absolute strip coordinates because the columns LEFT of the restored
    // focus keep their x when the removed column (to its right) leaves.
    private var previousViewOffset: CGFloat? = nil

    // `activating`: the caller is inserting a column AND focusing it, which
    // is what opening a window does. Passing it here rather than calling
    // focus() afterwards is what lets the "go back left on removal" memory
    // survive - an explicit focus move is exactly what clears it.
    func insertColumn(_ column: Column, at index: Int, activating: Bool = false) {
        let at = min(max(0, index), columns.count)
        let rightOfFocus = (at == focusedIndex + 1 && !columns.isEmpty)
        columns.insert(column, at: at)
        if let mi = maximizedIndex, mi >= at { maximizedIndex = mi + 1 }
        // Inserting at or before the focused column pushes it right; focus
        // travels with the column, not with the index.
        if at <= focusedIndex, columns.count > 1 { focus(column: focusedIndex + 1) }
        clampFocus()
        if activating {
            setFocusedIndex(at)
            activatePreviousOnRemoval = rightOfFocus
            if rightOfFocus { previousViewOffset = viewOffset }
        }
    }
    func appendColumn(_ column: Column) { insertColumn(column, at: columns.count) }
    @discardableResult
    func removeColumn(at index: Int) -> Column? {
        guard columns.indices.contains(index) else { return nil }
        if let mi = maximizedIndex {
            if mi == index { maximizedIndex = nil } else if mi > index { maximizedIndex = mi - 1 }
        }
        let removed = columns.remove(at: index)
        // Removing a column BEFORE the focused one keeps the same column
        // focused; removing the FOCUSED one lands on whatever slid into its
        // place - unless it was opened right of the previous focus, in which
        // case focus goes back where it came from (niri's
        // activate_prev_column_on_removal).
        if index < focusedIndex {
            focus(column: focusedIndex - 1)
        } else if index == focusedIndex, activatePreviousOnRemoval, index > 0 {
            let restored = previousViewOffset
            focus(column: index - 1)
            if let restored { viewOffset = restored }
        }
        activatePreviousOnRemoval = false
        previousViewOffset = nil
        clampFocus()
        return removed
    }
    // Every column left empty by a purge, in one pass.
    func removeEmptyColumns() {
        for index in columns.indices.reversed() where columns[index].windows.isEmpty {
            removeColumn(at: index)
        }
    }
    func swapColumns(_ i: Int, _ j: Int) {
        guard columns.indices.contains(i), columns.indices.contains(j) else { return }
        columns.swapAt(i, j)
        if maximizedIndex == i { maximizedIndex = j } else if maximizedIndex == j { maximizedIndex = i }
        if focusedIndex == i { focus(column: j) } else if focusedIndex == j { focus(column: i) }
    }
    // Set while a column is maximized: that column takes the full usable
    // screen width for this layout pass (ignoring its own widthProportion);
    // the others keep their normal virtual position and width, so they
    // naturally scroll out of view rather than needing any special-casing.
    var maximizedIndex: Int? = nil
    // niri's windowed fullscreen: the window covering the whole screen on
    // THIS workspace, if any. Per-workspace, like maximizedIndex - engine-
    // global state made a switch apply the leaving workspace's fullscreen to
    // the one being entered.
    var fullscreenWindow: ManagedWindow? = nil
    // niri keeps fullscreen and maximize-to-edges as SEPARATE states
    // (SizingMode::Fullscreen vs ::Maximized): fullscreen fills the raw
    // output, maximize-to-edges fills the working area. Same machinery
    // here, different target frame; reset when fullscreen ends.
    var fullscreenToEdges = false
    // Horizontal scroll position (camera) in the same virtual coordinate
    // space as ColumnLayoutEngine.columnPlacements - niri's infinite
    // scrollable strip. Column 0 starts at virtual x=0; later columns sit at
    // the cumulative width+gap of everything before them, with no
    // requirement that the whole row fit on screen at once. Updated only via
    // ColumnLayoutEngine.scrollOffset, which matches niri's
    // center-focused-column "never" (layout.kdl): scroll the minimum amount
    // to bring the focused column fully into view, never center it.
    var viewOffset: CGFloat = 0
    // niri's floating space: windows here are never touched by
    // ColumnLayoutEngine at all - they keep whatever position/size they
    // already have. Real mouse dragging/resizing still works completely
    // normally on them, same as any ordinary macOS window, since nigiri
    // never overrides a floating window's frame.
    var floatingWindows: [ManagedWindow] = []

    // Every window this workspace holds, tiled and floating. Spelled out by
    // hand in 15 places across 7 files before this existed, and one of them
    // (the "no windows found yet" log) left the floating ones out and
    // reported an occupied workspace as empty.
    var allWindows: [ManagedWindow] { columns.flatMap { $0.windows } + floatingWindows }
    // Only the tiled ones. A separate name because several call sites DO mean
    // this - the tiling pass never touches the floating layer - and reading
    // `allWindows` there would be a silent bug.
    var tiledWindows: [ManagedWindow] { columns.flatMap { $0.windows } }
    private(set) var floatingFocusedIndex: Int = 0
    func focus(floating index: Int) {
        floatingFocusedIndex = floatingWindows.isEmpty ? 0 : min(max(0, index), floatingWindows.count - 1)
    }
    func moveFloatingFocus(by delta: Int) { focus(floating: floatingFocusedIndex + delta) }
    @discardableResult
    func focus(floating window: ManagedWindow) -> Bool {
        guard let fi = floatingWindows.firstIndex(where: { $0 === window }) else { return false }
        focus(floating: fi)
        isFloatingActive = true
        return true
    }
    // Which group - the floating windows, or the tiled columns - currently
    // receives focus navigation and the other column/window hotkeys (niri's
    // floating_is_active).
    var isFloatingActive: Bool = false
}

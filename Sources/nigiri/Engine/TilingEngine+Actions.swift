import AppKit
import Foundation
import ApplicationServices

// Window/column/stack/floating actions - focus, move, resize, consume/expel, presets, floating toggle.
extension TilingEngine {
    // `delta` is -1 (left/up) or +1 (right/down) throughout this section -
    // every action below is a mirror image of itself depending on direction,
    // so each is written once, parameterized, instead of as a pair of
    // separate near-duplicate closures.

    // While the floating group has focus, arrow-key column navigation just
    // steps through floatingWindows as a plain ordered list instead - real
    // niri does direction-aware geometric floating navigation, which needs
    // mouse-driven positions we don't have any equivalent of here.
    func focusColumn(delta: Int) {
        if workspace.isFloatingActive {
            // niri's focus_left/right in the floating space is the axial
            // pick, not the next entry of an arbitrary list (workspace.rs
            // routes to floating.focus_left/right).
            focusFloatingGeometric(dx: delta, dy: 0)
            return
        }
        guard !workspace.columns.isEmpty else { return }
        let before = workspace.focusedIndex
        workspace.moveColumnFocus(by: delta)
        // niri's scrolling.focus_left/right returns false at the edge and the
        // caller does nothing (mod.rs focus_column_left/right just discard it).
        // Without this guard a press into the wall still re-ran the full
        // focus: focusCurrentColumn re-activated the same window and, through
        // raiseFloatingLayer, lifted the floating layer every time - so
        // holding Right at the end of the strip kept poking the floating
        // window to the front, which read as focus crossing into it. The
        // floating group is only ever reached by an explicit action
        // (switch-focus-between-floating-and-tiling), never by walking off the
        // edge, exactly as in niri.
        guard workspace.focusedIndex != before else { return }
        // Scrolls the strip to keep the newly-focused column in view, and
        // keeps the ring in sync on every animation step.
        reflow()
        focusCurrentColumn()
        print(
            "focus-column-\(delta < 0 ? "left" : "right") -> column \(workspace.focusedIndex) (\(describeFocus()))"
        )
    }
    func focusColumnEdge(first: Bool) {
        if workspace.isFloatingActive {
            // niri: focus-column-first/last in the floating space are the
            // GEOMETRIC leftmost/rightmost (workspace.rs:924-938), not the
            // ends of the list order.
            focusFloatingExtreme(first ? .leftmost : .rightmost)
            return
        }
        guard !workspace.columns.isEmpty else { return }
        let before = workspace.focusedIndex
        workspace.focus(column: first ? 0 : workspace.columns.count - 1)
        // Same as the edge guard above: focus-column-first/last while already
        // on that column must not re-activate and re-raise the floating layer.
        guard workspace.focusedIndex != before else { return }
        reflow()
        focusCurrentColumn()
        print(
            "focus-column-\(first ? "first" : "last") -> column \(workspace.focusedIndex) (\(describeFocus()))"
        )
    }
    // Focus a specific window by its id, wherever it lives - niri's
    // FocusWindow, and the action a taskbar or window switcher needs. Points
    // the model at the window inside its workspace, then either reflows in
    // place (same workspace) or animates a switch to the workspace it is on,
    // which lands on this window because the focus was set first.
    func focusWindowByID(_ id: UInt64) {
        guard let w = windowWithID(id), let location = locate(w) else {
            print("focus-window-by-id: no window \(id)")
            return
        }
        let targetWorkspace = location.workspaceIndex
        focusInModel(w, activateWorkspace: false)
        if targetWorkspace == activeWorkspaceIndex {
            reflow()
            focusCurrentColumn()
        } else {
            focusWorkspace(targetWorkspace + 1)
        }
        print("focus-window-by-id \(id) -> \(describeFocus())")
    }

    // Navigates WITHIN the focused column's vertical stack - a no-op while
    // that column only has one window, which is still the common case until
    // consume-or-expel is used.
    func focusWindowInStack(delta: Int) {
        guard let column = focusedColumn() else { return }
        column.moveFocus(by: delta)
        focusCurrentColumn()
        updateRing()
        print("focus-window-\(delta < 0 ? "up" : "down") -> \(describeFocus())")
    }

    // niri's move-window on a floating window: a fixed 50px step per press
    // (DIRECTIONAL_MOVE_PX in src/layout/floating.rs), animated like every
    // other movement. The same move keys drive this or the column/stack
    // moves depending on which group holds focus - exactly niri's dispatch.
    func moveFloatingWindow(dx: CGFloat, dy: CGFloat, of window: ManagedWindow? = nil) {
        guard let w = window ?? focusedFloatingWindow() else { return }
        guard let frame = settledFrame(of: w) else { return }
        animateFrames([(window: w, frame: frame.offsetBy(dx: dx, dy: dy))]) { _ in }
        print("move-floating-window (\(Int(dx)),\(Int(dy))) -> \(w.title)")
    }

    // niri's move-floating-window (MoveFloatingWindow { x, y }): each axis
    // is a PositionChange - SetFixed places within the working area,
    // AdjustFixed nudges (floating.rs move_to/move_by). The proportion
    // spellings are not part of that type.
    func moveFloatingWindowPosition(x: SizeChange, y: SizeChange, of window: ManagedWindow? = nil) -> Bool {
        guard let w = window ?? focusedFloatingWindow() else { return true }
        guard let frame = settledFrame(of: w) else { return true }
        let area = usableScreen().frame
        var origin = frame.origin
        switch x {
        case .setFixed(let v): origin.x = area.minX + v
        case .adjustFixed(let d): origin.x += d
        default:
            print("[action] move-floating-window takes fixed positions, not percentages")
            return false
        }
        switch y {
        case .setFixed(let v): origin.y = area.minY + v
        case .adjustFixed(let d): origin.y += d
        default:
            print("[action] move-floating-window takes fixed positions, not percentages")
            return false
        }
        animateFrames([(window: w, frame: CGRect(origin: origin, size: frame.size))]) { _ in }
        print("move-floating-window -> (\(Int(origin.x)),\(Int(origin.y)))")
        return true
    }

    // niri's set-window-width/height on a floating window (src/layout/
    // floating.rs:744-830): each SizeChange form resolved against the
    // WORKING AREA (not the raw screen - niri sizes against
    // working_area.size), one axis at a time - driven by the same keys as
    // tiled sizing, dispatched by which group holds focus. A fixed-size
    // dialog just refuses the write (logged once, then the refusal is
    // remembered - see ManagedWindow.lastRequestedFrame).
    func resizeFloatingWindow(
        width: SizeChange? = nil, height: SizeChange? = nil, of window: ManagedWindow? = nil
    ) {
        guard let w = window ?? focusedFloatingWindow() else { return }
        guard let frame = settledFrame(of: w) else { return }
        let area = usableScreen().frame
        var target = frame
        if let width {
            target.size.width = width.resolvedFloating(current: frame.width, available: area.width)
        }
        if let height {
            target.size.height = height.resolvedFloating(current: frame.height, available: area.height)
        }
        animateFrames([(window: w, frame: target)]) { _ in }
        print(
            "resize-floating-window \((width ?? height).map(String.init(describing:)) ?? "?") -> \(w.title)")
    }

    // Swaps the focused column's position with its neighbor (niri's
    // move-column-left/right) - no-op at either edge.
    func moveColumn(delta: Int) {
        guard !workspace.isFloatingActive else {
            print("move-column: focus is on the floating layer (Mod+Shift+V to go back to the tiled ones)")
            return
        }
        let newIndex = workspace.focusedIndex + delta
        guard workspace.columns.indices.contains(workspace.focusedIndex) else { return }
        guard workspace.columns.indices.contains(newIndex) else {
            print("move-column: already at the \(delta < 0 ? "left" : "right") edge")
            return
        }
        workspace.swapColumns(workspace.focusedIndex, newIndex)
        workspace.focus(column: newIndex)
        reflow()
        print("move-column-\(delta < 0 ? "left" : "right") -> now at column \(workspace.focusedIndex)")
    }
    // Relocates the focused column to the front/back of the row (niri's
    // move-column-to-first/last) - a real remove-then-insert, not a swap:
    // every column in between shifts by one position, matching niri's own
    // move_column_to (a plain adjacent swap is only equivalent to that when
    // moving exactly one slot, which is all moveColumn(delta:) above does).
    func moveColumnToEdge(first: Bool) {
        guard !workspace.isFloatingActive, workspace.columns.indices.contains(workspace.focusedIndex) else {
            return
        }
        let newIndex = first ? 0 : workspace.columns.count - 1
        guard newIndex != workspace.focusedIndex else { return }
        guard let column = workspace.removeColumn(at: workspace.focusedIndex) else { return }
        workspace.insertColumn(column, at: newIndex)
        workspace.focus(column: newIndex)
        reflow()
        print("move-column-to-\(first ? "first" : "last") -> now at column \(workspace.focusedIndex)")
    }
    // Swaps the focused window's position within its column's stack (niri's
    // move-window-up/down) - no-op at either end of the stack. Column widths
    // are untouched by a within-stack reorder, but the per-slot height cache
    // is invalidated: a window swapped into a slot may not accept the height
    // its old neighbor did.
    func moveWindowInStack(delta: Int) {
        guard let column = focusedColumn() else { return }
        let idx = column.focusedWindowIndex
        let newIdx = idx + delta
        guard column.windows.indices.contains(idx), column.windows.indices.contains(newIdx) else { return }
        column.swapWindows(idx, newIdx)
        column.focus(row: newIdx)
        column.cachedHeights = nil
        reflow()
        print("move-window-\(delta < 0 ? "up" : "down") -> \(describeFocus())")
    }

    // Bidirectional, matching niri's consume_or_expel_window_{left,right}: a
    // column with only one window gets CONSUMED into the neighboring
    // column's stack (the now-empty column is removed); a window inside a
    // multi-window stack gets EXPELLED out into a brand-new column right
    // next to it instead.
    // No AX attribute exposes a window's minimum height - whether a stack
    // fits can only be observed AFTER the authoritative settle pass probes
    // it (the same ask-and-read-back reality as column widths). So a
    // consume commits optimistically, and this runs at settle: if the
    // probed stack needs more vertical space than the column has (two
    // 500px-minimum windows in a 902px column overlap, there's no vertical
    // scrolling to absorb them), the consumed window is expelled back out
    // to its own column - a visible bounce-back, which honestly reports
    // "these two can't stack" instead of leaving them silently overlapped.
    func expelBackIfStackOverflows(_ column: Column, consumed window: ManagedWindow) {
        guard let heights = column.cachedHeights, heights.count == column.windows.count,
            column.windows.contains(where: { $0 === window }),
            let columnIndex = workspace.columns.firstIndex(where: { $0 === column })
        else { return }
        let available = usableScreen().frame.height - 2 * ColumnLayoutEngine.gap
        let total = heights.reduce(0, +) + CGFloat(heights.count - 1) * ColumnLayoutEngine.gap
        guard total > available + 2 else { return }
        guard let windowIndex = column.windows.firstIndex(where: { $0 === window }) else { return }
        column.removeWindow(at: windowIndex)
        column.clampFocus()
        column.cachedHeights = nil
        let newColumn = Column()
        newColumn.setWindows([window])
        // The expelled tile keeps its width (niri's RemovedTile carries it,
        // scrolling.rs:1994-2030) - a tile's width IS its column's.
        newColumn.width = column.width
        workspace.insertColumn(newColumn, at: columnIndex + 1)
        workspace.focus(column: columnIndex + 1)
        print(
            "consume-or-expel: stack needs \(Int(total))px but the column has \(Int(available))px - expelled back out"
        )
        reflow()
        focusCurrentColumn()
    }

    // niri's convert_heights_to_auto (scrolling.rs:5070-5083): EVERY height
    // in the column - fixed ones included - becomes Auto, weighted to
    // preserve the apparent heights, centered so the median window gets
    // weight 1. Runs only inside a height-resize on an Auto window (and
    // toggle_window_height), NEVER on membership changes: a comment here
    // used to cite this function to justify freezing weights on every
    // consume/expel, which upstream does not do (audit LAY-3) - there, the
    // arriving tile enters as auto_1 and the rest keep their weights.
    func convertHeightsToAuto(_ column: Column) {
        let heights = column.windows.map { WindowMover.currentFrame($0.axElement)?.height ?? 0 }
        for (w, weight) in zip(column.windows, ColumnLayoutEngine.autoWeights(preserving: heights)) {
            w.heightWeight = weight
            w.manualHeightPx = nil
            w.presetHeightIndex = nil
        }
    }

    func consumeOrExpel(delta: Int, id: UInt64? = nil) {
        guard let t = windowTarget(id: id, action: "consume-or-expel") else { return }
        // Only tiled windows consume/expel; a floating target is upstream's
        // no-op (the scrolling space doesn't hold it).
        guard case .tiled(let wi, let sourceIndex, let row) = t.location else { return }
        let ws = workspaces[wi]
        let source = ws.columns[sourceIndex]
        // Focus follows only when the target IS the focused window - an
        // id-addressed action on any other window leaves focus alone.
        let follow = targetIsFocused(t)
        let neighborIndex = sourceIndex + delta
        var verifyFits: (() -> Void)?

        if source.windows.count == 1 {
            guard ws.columns.indices.contains(neighborIndex) else { return }
            guard let window = source.removeWindow(at: 0) else { return }
            let target = ws.columns[neighborIndex]
            target.add(window)
            // The consumed tile becomes the column's ACTIVE row only when
            // it was the focused window (add_tile_to_column's activate =
            // source_tile_was_active, scrolling.rs:1830/911-916) - an
            // id-addressed consume must not steal the target column's focus.
            if follow { target.focus(row: target.windows.count - 1) }
            ws.removeColumn(at: sourceIndex)
            // Removing sourceIndex shifts every later index down by one - if
            // the target was to the right (delta > 0) it lands back at
            // sourceIndex; if it was to the left (delta < 0), unaffected,
            // still at sourceIndex - 1.
            if follow { ws.focus(column: delta < 0 ? sourceIndex - 1 : sourceIndex) }
            verifyFits = { self.expelBackIfStackOverflows(target, consumed: window) }
        } else {
            guard let window = source.removeWindow(at: row) else { return }
            let newColumn = Column()
            newColumn.setWindows([window])
            // niri: the expelled tile's new column inherits its width
            // (scrolling.rs:1848-1855, 1942-1949), not default-column-width.
            newColumn.width = source.width
            let insertAt = delta < 0 ? sourceIndex : sourceIndex + 1
            ws.insertColumn(newColumn, at: insertAt)
            if follow { ws.focus(column: insertAt) }
        }
        reflow(onSettled: verifyFits)
        if follow { focusCurrentColumn() }
        print(
            "consume-or-expel-\(delta < 0 ? "left" : "right") -> \(ws.columns.count) column(s)"
        )
    }

    // niri's expel-window-from-column: unconditionally pulls the LAST window
    // in the stack (not necessarily the focused one) out into a new column
    // right after the current one - a no-op on a column with only one
    // window. Unlike consume-or-expel, focus does not follow the expelled
    // window; it stays on the source column.
    func expelFromColumn() {
        guard let column = focusedColumn(), column.windows.count > 1 else { return }
        guard let window = column.removeWindow(at: column.windows.count - 1) else { return }
        let newColumn = Column()
        newColumn.setWindows([window])
        // Same width inheritance as consume-or-expel (scrolling.rs:2016-2023).
        newColumn.width = column.width
        workspace.insertColumn(newColumn, at: workspace.focusedIndex + 1)
        reflow()
        print("expel-window-from-column -> \(workspace.columns.count) column(s)")
    }

    // niri's preset-column-widths takes both `proportion` and `fixed <px>`.
    // For the comparison seed each preset resolves to PIXELS (upstream's
    // resolve_preset_width, scrolling.rs:4813-4818): proportions through the
    // width formula, fixed presets are already pixels.
    func resolvedPresetWidths() -> [CGFloat] {
        let usableWidth = usableScreen().usableWidth
        // In the DECLARED order: this list is the cycle Mod+R walks.
        return ColumnLayoutEngine.presetColumnSizes.map { size in
            switch size {
            case .proportion(let p):
                return ColumnLayoutEngine.width(forProportion: p, usableWidth: usableWidth)
            case .fixed(let px): return px
            }
        }
    }

    // A preset applies through set-column-width, exactly upstream's
    // `SizeChange::from(preset)` (scrolling.rs:4842).
    private func sizeChange(from preset: NigiriConfig.PresetSize) -> SizeChange {
        switch preset {
        case .proportion(let p): return .setProportion(p * 100)
        case .fixed(let px): return .setFixed(px)
        }
    }

    // niri's switch-preset-column-width (Mod+R): cycles the focused column
    // through preset-column-widths (layout.kdl: 1/3, 1/2, 2/3), wrapping.
    // `delta` +1 cycles forward (niri's switch-preset-column-width), -1
    // backward (switch-preset-column-width-back). The INDEX advances by the
    // requested preset even when the width clamps (Discord's 800px floor
    // swallows both 1/3 and 1/2): keying the cycle off the clamped result
    // would loop forever on the first preset and never reach the ones the
    // column can actually take.
    func switchPresetColumnWidth(delta: Int = 1, column targetColumn: Column? = nil) {
        // niri's toggle_width with the floating layer active cycles the
        // FLOATING window's width presets (workspace.rs:1177-1183); this
        // was a silent no-op here. An explicit target column (the id= form
        // of switch-preset-window-width) skips the layer routing.
        if targetColumn == nil, workspace.isFloatingActive {
            switchPresetWindowWidth(delta: delta)
            return
        }
        // niri clears is_full_width on toggle_width too (scrolling.rs:4906),
        // and while full-width/maximized it BYPASSES the stored preset index
        // (4799-4803): the comparison then runs against the REAL width the
        // user sees - the full working area - not against a stale index.
        guard let column = targetColumn ?? focusedColumn() else { return }
        let wasMaximized = column.isFullWidth
        let knownFloor = column.validMinWidth
        ColumnLayoutEngine.newEpoch()
        let presets = ColumnLayoutEngine.presetColumnSizes
        guard !presets.isEmpty else { return }
        let usableWidth = usableScreen().usableWidth
        // The comparison seed runs against the width the user actually SEES:
        // full working area while maximized, the resolved width otherwise.
        let currentPx =
            wasMaximized
            ? usableWidth
            : ColumnLayoutEngine.resolveColumnWidth(column.width, usableWidth: usableWidth)
        guard
            let nextIndex = ColumnLayoutEngine.presetIndex(
                after: currentPx, in: resolvedPresetWidths(),
                delta: delta, from: wasMaximized ? nil : column.presetWidthIndex)
        else { return }
        // Upstream applies the preset THROUGH set_column_width (which clears
        // the index and full-width) and re-stamps the index after
        // (scrolling.rs:4842-4845).
        let applied = applyColumnWidth(
            sizeChange(from: presets[nextIndex]), to: column, knownFloor: knownFloor)
        column.presetWidthIndex = nextIndex
        reflow()
        print(
            "switch-preset-column-width\(delta < 0 ? "-back" : "") -> \(applied)"
        )
    }

    // niri's switch-preset-window-width, the width counterpart of
    // switch-preset-window-height. In the tiled strip a window's width IS
    // its column's, so this just cycles the column preset there; a floating
    // window gets its own width cycled through the presets (as fractions of
    // the usable width), the frame animated like every other floating move.
    func switchPresetWindowWidth(delta: Int = 1, id: UInt64? = nil) {
        guard let t = windowTarget(id: id, action: "switch-preset-window-width") else { return }
        // A tiled target cycles its COLUMN's presets (a tiled window's
        // width is its column's); a floating one cycles its own.
        if case .tiled(let wi, let ci, _) = t.location {
            switchPresetColumnWidth(delta: delta, column: workspaces[wi].columns[ci])
            return
        }
        let w = t.window
        guard let frame = settledFrame(of: w) else { return }
        let presets = resolvedPresetWidths()
        guard !presets.isEmpty else { return }
        // niri's two-tier resolution (floating.rs toggle_width): the stored
        // preset index advances by one when there is one; off-preset (hand
        // dragged, app-clamped) the COMPARISON seeds it - forward is the
        // first preset strictly wider (or the first), backward the LAST
        // strictly narrower (or the last). The old seed here (firstWider-1,
        // then +delta) walked backward one preset too far - between 1/3 and
        // 1/2, back gave 2/3 where niri gives 1/3 - under a comment that
        // claimed niri does not use the comparison at all (audit LAY-7).
        guard
            let nextIndex = ColumnLayoutEngine.presetIndex(
                after: frame.width, in: presets, delta: delta, from: w.presetWidthIndex)
        else { return }
        w.presetWidthIndex = nextIndex
        let next = presets[nextIndex]
        var target = frame
        target.size.width = next
        animateFrames([(window: w, frame: target)]) { _ in }
        print("switch-preset-window-width (floating) -> \(Int(next))px")
    }

    // niri: most window actions carry an optional `id` targeting that
    // window WHEREVER it lives, WITHOUT moving focus - each upstream
    // handler routes to the workspace holding it (e.g. Layout::
    // set_window_height finds it via workspaces_mut) and acts there. nil
    // falls back to the focused window, upstream's unwrap_or(active).
    struct WindowTarget {
        let window: ManagedWindow
        let location: WindowLocation
        var workspaceIndex: Int { location.workspaceIndex }
    }
    // The focused floating window, or nil - the guard every floating
    // helper used to spell out by hand.
    func focusedFloatingWindow() -> ManagedWindow? {
        workspace.floatingWindows.indices.contains(workspace.floatingFocusedIndex)
            ? workspace.floatingWindows[workspace.floatingFocusedIndex] : nil
    }
    func windowTarget(id: UInt64?, action: String) -> WindowTarget? {
        if let id {
            guard let w = windowWithID(id), let loc = locate(w) else {
                print("\(action): no window with id \(id)")
                return nil
            }
            return WindowTarget(window: w, location: loc)
        }
        guard let w = focusedManagedWindow(), let loc = locate(w) else { return nil }
        return WindowTarget(window: w, location: loc)
    }
    // Whether acting on this target should move focus and the camera: only
    // when it IS the focused window - an id-addressed action on any other
    // window leaves focus alone, like upstream.
    func targetIsFocused(_ t: WindowTarget) -> Bool {
        t.workspaceIndex == activeWorkspaceIndex && t.window === focusedManagedWindow()
    }

    // niri's close-window: press the window's own close button through AX -
    // the app runs its normal close path (save prompts and all). A
    // chrome-less window has no button to press; AX offers no other
    // close verb and nigiri never synthesizes keyboard input, so that's an
    // honest refusal, not a silent one. niri's CloseWindow carries an
    // optional id (a taskbar closes windows that are not focused); nil means
    // the focused window, like niri.
    func closeWindow(id: UInt64? = nil) {
        let target = id.flatMap { windowWithID($0) } ?? focusedManagedWindow()
        guard let w = target else {
            if let id { print("close-window: no window \(id)") }
            return
        }
        guard let closeButton = AX.element(w.axElement, kAXCloseButtonAttribute as String) else {
            print("close-window: \(w.title) has no close button (chrome-less window)")
            return
        }
        AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
        print("close-window -> \(w.title)")
    }

    // niri's fullscreen-window, mapped onto macOS native fullscreen. Note
    // macOS moves the window to its own Space - it leaves the strip until
    // toggled back, exactly like any window the user fullscreens by hand.
    // niri's fullscreen-window: the window covers the output but STAYS in
    // the layout - leaving it is one keypress and the strip is untouched
    // underneath. macOS's own AXFullScreen does something else entirely: it
    // banishes the window to its own Space, out of the strip, out of the
    // model's reach (and drags a 700ms system animation along). So the
    // niri-shaped action is the windowed one, and the native Space is
    // available separately as native-fullscreen for whoever wants it.
    func fullscreenWindow(id: UInt64? = nil) {
        setWindowedFullscreen(toEdges: false, id: id)
    }

    // Fullscreen and maximize-to-edges share the machinery but are niri's
    // two distinct states (SizingMode::Fullscreen / ::Maximized): raw
    // output vs working area. Same-mode repeat toggles off; the other mode
    // switches in place.
    func setWindowedFullscreen(toEdges: Bool, id: UInt64? = nil) {
        guard let t = windowTarget(id: id, action: "fullscreen-window") else { return }
        let ws = workspaces[t.workspaceIndex]
        if let col = ws.fullscreenColumn {
            if ws.fullscreenToEdges == toEdges {
                toggleWindowedFullscreen(id: id)
            } else {
                // Mode switch in place: flip the column's pending flags
                // (fullscreen = raw output, maximized = working area).
                col.isPendingFullscreen = !toEdges
                col.isPendingMaximized = toEdges
                print("windowed-fullscreen: \(toEdges ? "to edges" : "full output")")
                if t.workspaceIndex == activeWorkspaceIndex { reflow() }
            }
        } else {
            // niri EXTRACTS first: set_fullscreen on a window in a
            // multi-window, non-tabbed column runs
            // consume_or_expel_window_right, so the window fullscreens in
            // its OWN column - a permanent restructuring that survives
            // leaving fullscreen (scrolling.rs:2840-2845). The window used
            // to stay in its stack and return to it on exit.
            if case .tiled(_, let ci, _) = t.location {
                let column = ws.columns[ci]
                if column.windows.count > 1, !column.isTabbed {
                    consumeOrExpel(delta: 1, id: t.window.id)
                }
            }
            toggleWindowedFullscreen(id: id, toEdges: toEdges)
        }
    }

    // The target the current fullscreen mode fills: niri's Maximized stops
    // at the working area (bar and struts respected), Fullscreen covers the
    // raw output.
    func currentFullscreenFrame() -> CGRect {
        workspace.fullscreenToEdges ? usableScreen().frame : currentRawScreenFrame()
    }

    // The real macOS fullscreen Space, kept as its own action precisely
    // because it takes the window OUT of the tiling model.
    func nativeFullscreenWindow() {
        guard let w = focusedManagedWindow() else { return }
        let isFullscreen: Bool = AX.attribute(w.axElement, "AXFullScreen") ?? false
        AXUIElementSetAttributeValue(w.axElement, "AXFullScreen" as CFString, (!isFullscreen) as CFBoolean)
        print("native-fullscreen -> \(isFullscreen ? "exit" : "enter") (\(w.title))")
    }

    // niri's toggle-windowed-fullscreen: fake fullscreen inside the
    // workspace - the focused WINDOW covers the raw screen frame, gaps and
    // all, and the layout under it is preserved.
    func toggleWindowedFullscreen(id: UInt64? = nil, toEdges: Bool = false) {
        guard let t = windowTarget(id: id, action: "toggle-windowed-fullscreen") else { return }
        let ws = workspaces[t.workspaceIndex]
        let active = t.workspaceIndex == activeWorkspaceIndex
        // Exiting is checked BEFORE the tiled guard: the target may be the
        // floating layer's focus while the workspace is fullscreen, which
        // otherwise made the toggle a silent no-op and left the workspace
        // stuck in fullscreen.
        if let col = ws.fullscreenColumn {
            let current = col.focusedWindow
            col.isPendingFullscreen = false
            col.isPendingMaximized = false
            col.cachedHeights = nil
            col.cachedMinWidth = nil
            current?.lastRequestedFrame = nil
            current?.lastActualFrame = nil
            current?.refusalCandidate = nil
            // Floating windows were shoved out of view and are not part of
            // the tiling pass: put them back where they were.
            for w in ws.floatingWindows {
                guard let home = w.fullscreenHome else { continue }
                w.fullscreenHome = nil
                _ = ColumnLayoutEngine.applyFrame(w, target: home)
            }
            print("windowed-fullscreen: off")
            if active {
                reflow()
                updateRingImmediate()
            }
            return
        }
        guard case .tiled(_, let ci, _) = t.location else { return }
        let column = ws.columns[ci]
        let window = t.window
        column.isPendingFullscreen = !toEdges
        column.isPendingMaximized = toEdges
        column.cachedHeights = nil
        column.cachedMinWidth = nil
        // Immediately, not at settle: the per-tick decoration update is
        // skipped while fullscreen, so the borders would otherwise sit frozen
        // in place for the whole animation and only vanish at the end.
        if active {
            ring.hide()
            borders.hideAll()
            tabIndicators.hideAll()
        }
        print("windowed-fullscreen: \(window.title)")
        if active { reflow() }
    }

    // niri's maximize-window-to-edges: fake fullscreen - the focused column
    // covers the raw screen frame, gaps and all, without macOS's real
    // fullscreen Space. Toggles off on repeat; plain maximize-column
    // resets the edges variant.
    // niri's maximize-window-to-edges acts on the focused WINDOW, not on
    // its whole column - with a stack of three, the other two stay where
    // they are. nigiri used to set a workspace-wide flag that blew up the
    // entire column to the screen edges.
    func maximizeWindowToEdges(id: UInt64? = nil) {
        setWindowedFullscreen(toEdges: true, id: id)
    }

    // niri's consume-window-into-column (Mod+Comma): swallow the FIRST
    // window of the column to the right into the focused column's stack.
    // Focus stays where it is - unlike consume-or-expel, nothing moves out.
    func consumeWindowIntoColumn() {
        guard let column = focusedColumn() else { return }
        let neighborIndex = workspace.focusedIndex + 1
        guard workspace.columns.indices.contains(neighborIndex) else { return }
        let neighbor = workspace.columns[neighborIndex]
        guard !neighbor.windows.isEmpty else { return }
        guard let window = neighbor.removeWindow(at: 0) else { return }
        column.add(window)
        if neighbor.windows.isEmpty {
            workspace.removeColumn(at: neighborIndex)
        }
        // Same physical-fit verification as consume-or-expel: no AX
        // attribute exposes minimum heights, so commit optimistically and
        // bounce back at settle if the stack can't hold both.
        reflow(onSettled: { self.expelBackIfStackOverflows(column, consumed: window) })
        print(
            "consume-window-into-column -> \(column.windows.count) window(s) in column \(workspace.focusedIndex)"
        )
    }

    // niri's focus-workspace-previous: bounce between the current and the
    // last-visited workspace (updated inside focusWorkspace).
    func focusWorkspacePrevious() {
        focusWorkspace(previousWorkspaceIndex + 1)
    }

    // niri's move-workspace-down/up: swap the active workspace with its
    // neighbor in the numbering. Pure bookkeeping - the visible windows
    // don't move, their workspace NUMBER does (and focus-workspace N now
    // reaches them under the new number).
    func moveWorkspace(delta: Int) {
        let target = activeWorkspaceIndex + delta
        guard workspaces.indices.contains(target) else { return }
        workspaces.swapAt(activeWorkspaceIndex, target)
        if previousWorkspaceIndex == target {
            previousWorkspaceIndex = activeWorkspaceIndex
        } else if previousWorkspaceIndex == activeWorkspaceIndex {
            previousWorkspaceIndex = target
        }
        activeWorkspaceIndex = target
        // niri restores the invariants IN THE ACT (monitor.rs:1242-1292):
        // the trailing empty workspace, empty-above-first, and the cleanup
        // all run right after the swap - waiting for the next unrelated
        // relayout left "the last workspace is always empty" broken.
        compactWorkspaces()
        reflow()
        emitWorkspacesChanged()
        print("move-workspace-\(delta < 0 ? "up" : "down") -> now workspace \(activeWorkspaceIndex + 1)")
    }

    // niri's set-column-width "±10%": adjusts the focused column's own width
    // proportion directly by 10 percentage points of the screen (matching
    // niri's AdjustProportion - a fixed jump, not "10% of its current
    // width"), and drops off any preset it was sitting on.
    // The one place a requested column proportion becomes what the model
    // keeps. Floor: the column can never actually get narrower than its
    // most resize-refusing window (Discord's 800px floor defines its whole
    // stack) - placements already widen the SLOT to cachedMinWidth, but a
    // model keeping an impossible number meant the ring framed a phantom
    // width and shrink presses accumulated invisible debt that grow presses
    // had to pay back before anything moved. A shrink below a
    // not-yet-discovered minimum still goes through (nothing known to clamp
    // against); the refusal it provokes populates cachedMinWidth for every
    // press after it. Ceiling: nothing past the full usable width is ever
    // visible at once, so growth past 100% was the same debt mirrored.
    // Every proportion writer (±10%, presets) must come through here -
    // presets were the door the phantom snuck back in through.
    // `knownFloor` exists because every width action starts by bumping the
    // epoch ("the user asking for a width IS the signal to re-measure"), and
    // the epoch is exactly what makes column.validMinWidth answer nil. Read
    // from the column here, the floor was therefore ALWAYS nil in every width
    // action - the branch below was dead code, and the message it prints had
    // never once been seen. The action captures the floor before the bump and
    // hands it in: clamp against what we already learned, while still
    // re-probing on the write that follows.
    func clampedProportion(_ proportion: CGFloat, for column: Column, knownFloor: CGFloat? = nil) -> CGFloat {
        let usableWidth = usableScreen().usableWidth
        let minWidth = knownFloor ?? column.validMinWidth
        let p = ColumnLayoutEngine.clampProportion(
            proportion, minWidth: minWidth,
            maxWidth: column.maxWidthPx, usableWidth: usableWidth)
        if let minWidth, usableWidth > 0,
            p > min(1.0, max(0.05, proportion)) + 0.0001
        {
            // Said out loud: a silent floor is why "set-column-width -10%
            // does nothing" was impossible to diagnose from the outside.
            print(
                "[layout] \(Int(proportion * 100))% asked for, but the app won't go below \(Int(minWidth))px - re-measuring"
            )
        }
        return p
    }

    // `knownFloor`: a caller that already bumped the epoch (resize-edge)
    // captured the floor before doing so and hands it in, since by now the
    // column itself can only answer nil.
    func setColumnWidth(_ change: SizeChange, knownFloor: CGFloat? = nil) {
        guard let column = focusedColumn() else { return }
        // The user asking for a width IS the signal to re-measure: the app
        // may well answer differently than it did the last time. The floor
        // it discovered last time is read BEFORE that, though - the epoch
        // bump is what hides it.
        let knownFloor = knownFloor ?? column.validMinWidth
        ColumnLayoutEngine.newEpoch()
        let applied = applyColumnWidth(change, to: column, knownFloor: knownFloor)
        reflow()
        print("set-column-width \(change) -> \(applied)")
    }

    // niri's Column::set_column_width, match arm for match arm
    // (scrolling.rs:4851-4909): the SET forms pick their own kind, the
    // ADJUST forms keep pixels fixed and convert a fixed width to a
    // proportion before adjusting proportionally. Clears the preset index
    // and is_full_width, exactly like upstream (4906-4908) - resizing a
    // maximized column used to visibly do nothing, since the maximize
    // override kept winning.
    @discardableResult
    func applyColumnWidth(_ change: SizeChange, to column: Column, knownFloor: CGFloat? = nil) -> ColumnWidth
    {
        let usableWidth = usableScreen().usableWidth
        // Full-width reads as proportion 1 (scrolling.rs:4852-4856).
        let current: ColumnWidth = column.isFullWidth ? .proportion(1) : column.width
        let currentPx = ColumnLayoutEngine.resolveColumnWidth(current, usableWidth: usableWidth)
        // Upstream's overflow guards (FIXME there: "fix overflows then
        // remove limits").
        let maxPx: CGFloat = 100000
        let maxProp: CGFloat = 10000
        var width: ColumnWidth
        switch (current, change) {
        case (_, .setFixed(let px)):
            // Upstream computes the FIXED width so the window itself gets
            // the asked-for pixels (tile_width_for_window_width) - the tile
            // and the window are the same rectangle here (decorations are
            // overlays), so that conversion is the identity.
            width = .fixed(min(max(px, 1), maxPx))
        case (_, .setProportion(let p)):
            width = .proportion(min(max(p / 100, 0), maxProp))
        case (_, .adjustFixed(let d)):
            width = .fixed(min(max(currentPx + d, 1), maxPx))
        case (.proportion(let cur), .adjustProportion(let d)):
            width = .proportion(min(max(cur + d / 100, 0), maxProp))
        case (.fixed, .adjustProportion(let d)):
            let cur = ColumnLayoutEngine.proportion(forWidth: currentPx, usableWidth: usableWidth)
            width = .proportion(min(max(cur + d / 100, 0), maxProp))
        }
        // macOS deviation, same one clampedProportion documents: the model
        // never keeps a width the column's windows have refused.
        width = clampedWidth(width, for: column, knownFloor: knownFloor)
        column.width = width
        column.presetWidthIndex = nil
        column.isFullWidth = false
        return width
    }

    // niri's SetWindowWidth (scrolling.rs:2607), the window-addressed
    // spelling: a tiled window's width IS its column's, and a floating
    // target resizes the window itself - with an optional id, wherever the
    // window lives, without moving focus.
    func setWindowWidth(_ change: SizeChange, id: UInt64? = nil) {
        guard let t = windowTarget(id: id, action: "set-window-width") else { return }
        switch t.location {
        case .floating:
            resizeFloatingWindow(width: change, of: t.window)
        case .tiled(let wi, let ci, _):
            let column = workspaces[wi].columns[ci]
            let knownFloor = column.validMinWidth
            ColumnLayoutEngine.newEpoch()
            let applied = applyColumnWidth(change, to: column, knownFloor: knownFloor)
            reflow()
            print("set-window-width \(change) -> \(applied)")
        }
    }

    // The ColumnWidth face of clampedProportion below: both kinds clamp
    // against the same discovered floor and rule ceiling.
    func clampedWidth(_ width: ColumnWidth, for column: Column, knownFloor: CGFloat? = nil) -> ColumnWidth {
        switch width {
        case .proportion(let p):
            return .proportion(clampedProportion(p, for: column, knownFloor: knownFloor))
        case .fixed(let px):
            let minWidth = knownFloor ?? column.validMinWidth
            var v = px
            if let mx = column.maxWidthPx { v = min(v, mx) }
            if let minWidth, minWidth > v {
                v = minWidth
                // Said out loud, like the proportion path: a silent floor is
                // undiagnosable from the outside.
                print(
                    "[layout] \(Int(px))px asked for, but the app won't go below \(Int(minWidth))px - re-measuring"
                )
            }
            return .fixed(v)
        }
    }

    // niri's set_window_height, formula for formula (scrolling.rs:
    // 4917-4991), with extra_size 0 (decorations are overlays here, so
    // tile height == window height). The old version had its own math
    // (SetProportion as a share of columnHeight, invented 20px floors and
    // per-sibling 20px ceilings) and let several windows hold a manual
    // height at once, against upstream's documented invariant.
    func setWindowHeight(_ change: SizeChange, id: UInt64? = nil) {
        guard let t = windowTarget(id: id, action: "set-window-height") else { return }
        // A floating target takes the floating path, exactly upstream's
        // routing (layout/mod.rs set_window_height -> workspace -> floating).
        if case .floating = t.location {
            resizeFloatingWindow(height: change, of: t.window)
            return
        }
        guard case .tiled(let wi, let ci, let row) = t.location else { return }
        let column = workspaces[wi].columns[ci]
        let window = t.window
        let working = usableScreen().frame.height
        let gap = ColumnLayoutEngine.gap
        // height(forProportion:) references usable = working - 2*gap; with
        // that, (usable + gap)*p - gap == (working - gap)*p - gap, which IS
        // upstream's tile height for SetProportion.
        let columnHeight = working - 2 * gap
        // "Every window but one in a column must be Auto" (scrolling.rs:
        // 244-247): resizing an Auto window first converts every height to
        // Auto, preserving apparent heights; a window already Fixed skips
        // the conversion, which also restores the old weights when a resize
        // bottomed out its siblings and came back.
        if window.manualHeightPx == nil { convertHeightsToAuto(column) }
        let current =
            window.manualHeightPx ?? (WindowMover.currentFrame(window.axElement)?.height ?? columnHeight)
        let full = working - gap
        let currentProp = full == 0 ? 1 : (current + gap) / full
        let requested: CGFloat
        switch change {
        case .setFixed(let px): requested = px
        case .setProportion(let p):
            requested = ColumnLayoutEngine.height(forProportion: p / 100, usableHeight: columnHeight)
        case .adjustFixed(let px): requested = current + px
        case .adjustProportion(let d):
            requested = ColumnLayoutEngine.height(
                forProportion: currentProp + d / 100, usableHeight: columnHeight)
        }
        // Ceiling from the siblings' minimums (scrolling.rs:4961-4974): an
        // unknown minimum counts as 1, exactly upstream's max(1., min_size);
        // AX only reveals a real minimum once a window refuses (fixedSize),
        // and the probe pass absorbs those refusals at apply time. Tabbed
        // columns take no vertical space from each other. (The audit's LAY-2
        // rewrite supersedes the older 20px-floor ceiling and the flat
        // sibling reset - convertHeightsToAuto above keeps their weights.)
        let minTaken: CGFloat =
            column.isTabbed
            ? 0
            : column.windows.enumerated()
                .filter { $0.offset != row }
                .reduce(0) { $0 + max(1, $1.element.fixedSize?.height ?? 1) + gap }
        let heightLeft = max(1, working - gap - minTaken - gap)
        window.setFixedHeight(min(100000, max(1, min(heightLeft, requested))))
        column.cachedHeights = nil
        reflow()
        print("set-window-height \(change) -> \(window.title)")
    }

    // niri's reset-window-height: back to Auto, splitting whatever's left
    // among the column's other Auto windows again.
    func resetWindowHeight(id: UInt64? = nil) {
        guard let t = windowTarget(id: id, action: "reset-window-height") else { return }
        guard case .tiled(let wi, let ci, _) = t.location else { return }
        let column = workspaces[wi].columns[ci]
        let window = t.window
        window.manualHeightPx = nil
        window.presetHeightIndex = nil
        // Back to an equal Auto share: a weight frozen by an earlier
        // resize would otherwise keep the window disproportionate.
        window.heightWeight = 1
        column.cachedHeights = nil
        reflow()
        print("reset-window-height -> \(window.title)")
    }

    // niri's expand-column-to-available-width: grows the focused column to
    // absorb whatever room is left in the CURRENT view that isn't occupied
    // by other columns already fully visible there - if it's the only one
    // visible, it just takes the full width instead.
    func expandColumnToAvailableWidth() {
        ColumnLayoutEngine.newEpoch()
        guard focusedColumn() != nil else { return }
        // Already full-width: a no-op, like upstream's is_full_width guard
        // (scrolling.rs:2733-2735).
        guard focusedColumn()?.isFullWidth != true else { return }
        // Always-centered mode cannot control the active window's position,
        // so upstream just toggles full width (scrolling.rs:2737-2747).
        if ColumnLayoutEngine.centerPolicy == .always
            || (ColumnLayoutEngine.alwaysCenterSingleColumn && workspace.columns.count == 1)
        {
            maximizeColumnToggle()
            return
        }
        let usableWidth = usableScreen().usableWidth
        let placements = ColumnLayoutEngine.columnPlacements(
            columns: workspace.columns, usableWidth: usableWidth)
        let activeIndex = workspace.focusedIndex

        func fullyVisible(_ p: ColumnLayoutEngine.Placement) -> Bool {
            p.x >= workspace.viewOffset - 0.5
                && (p.x + p.width) <= workspace.viewOffset + usableWidth + 0.5
        }
        // The active column must itself be fully on screen, or there is
        // nothing meaningful to expand into (scrolling.rs:2788-2791).
        guard placements.indices.contains(activeIndex), fullyVisible(placements[activeIndex]) else {
            return
        }
        var otherVisibleWidth: CGFloat = 0
        var anyOtherVisible = false
        var leftmostVisibleX: CGFloat?
        for (idx, p) in placements.enumerated() where fullyVisible(p) {
            if leftmostVisibleX == nil || p.x < leftmostVisibleX! { leftmostVisibleX = p.x }
            if idx != activeIndex {
                otherVisibleWidth += p.width + ColumnLayoutEngine.gap
                anyOtherVisible = true
            }
        }
        guard anyOtherVisible else {
            // Only the active column is fully on-screen: upstream goes
            // through toggle_full_width so backing out is intuitive
            // (scrolling.rs:2803-2808) - a raw 100% width undid differently.
            maximizeColumnToggle()
            return
        }
        // What is left once the other fully-visible columns have taken
        // theirs - that IS the active column's new width. Adding its current
        // width on top double-counted it and overflowed the strip, pushing
        // the very columns this measured out of view.
        let newWidth = usableWidth - otherVisibleWidth
        guard newWidth > 0 else { return }
        // Stored as FIXED pixels, like upstream (scrolling.rs:2812-2814):
        // the expanded width is an absolute answer to "what space is left",
        // not a share to re-derive when gaps or the monitor change.
        workspace.columns[activeIndex].width = .fixed(newWidth)
        workspace.columns[activeIndex].presetWidthIndex = nil
        workspace.columns[activeIndex].isFullWidth = false
        // Keep the leftmost visible column in view (scrolling.rs:2817-2819):
        // the expansion grows rightward from it, never shoves it off.
        if let leftmostVisibleX {
            reflow(explicitViewOffset: leftmostVisibleX)
        } else {
            reflow()
        }
        print("expand-column-to-available-width -> \(Int(newWidth))px")
    }

    // niri's center-column: an explicit, on-demand recentering of the
    // focused column - distinct from center-focused-column "never" (the
    // passive auto-follow policy every other action already respects).
    func centerColumn() {
        // niri's center_column with the floating layer active centers the
        // floating window (workspace.rs:1152-1160); it was a no-op here.
        if workspace.isFloatingActive {
            centerFloatingWindow()
            return
        }
        guard focusedColumn() != nil else { return }
        let usableWidth = usableScreen().usableWidth
        let placements = ColumnLayoutEngine.columnPlacements(
            columns: workspace.columns, usableWidth: usableWidth)
        let p = placements[workspace.focusedIndex]
        reflow(explicitViewOffset: p.x + p.width / 2 - usableWidth / 2)
        print("center-column")
    }

    // niri's center-visible-columns: keeps the same set of columns visible,
    // but recenters that whole group as a block within the view instead of
    // sitting flush against whichever edge they happened to scroll to.
    func centerVisibleColumns() {
        guard !workspace.isFloatingActive, !workspace.columns.isEmpty else { return }
        // Upstream's guards (scrolling.rs:2241-2243, 2278-2281): a no-op in
        // always-centered mode, and a no-op when the active column is not
        // itself fully visible.
        if ColumnLayoutEngine.centerPolicy == .always
            || (ColumnLayoutEngine.alwaysCenterSingleColumn && workspace.columns.count == 1)
        {
            return
        }
        let usableWidth = usableScreen().usableWidth
        let placements = ColumnLayoutEngine.columnPlacements(
            columns: workspace.columns, usableWidth: usableWidth)
        func fullyVisible(_ p: ColumnLayoutEngine.Placement) -> Bool {
            p.x >= workspace.viewOffset - 0.5
                && (p.x + p.width) <= workspace.viewOffset + usableWidth + 0.5
        }
        guard placements.indices.contains(workspace.focusedIndex),
            fullyVisible(placements[workspace.focusedIndex])
        else { return }
        let visible = placements.filter(fullyVisible)
        guard let first = visible.first, let last = visible.last else { return }
        let visibleSpan = (last.x + last.width) - first.x
        let slack = usableWidth - visibleSpan
        guard slack > 0 else { return }
        reflow(explicitViewOffset: first.x - slack / 2)
        print("center-visible-columns")
    }

    // niri's toggle-window-floating: moves the focused window between the
    // tiled columns and the floating group. Floating here just means
    // EXCLUDED from ColumnLayoutEngine entirely - real mouse dragging/
    // resizing still works completely normally on it afterward, same as any
    // other macOS window, since nothing here ever overrides its frame again.
    func toggleWindowFloating(id: UInt64? = nil) {
        guard let t = windowTarget(id: id, action: "toggle-window-floating") else { return }
        let ws = workspaces[t.workspaceIndex]
        let follow = targetIsFocused(t)
        if case .floating(_, let fi) = t.location {
            // niri's toggle_window_floating moves ANY window either way
            // (workspace.rs) - the dialog veto here was invented policy. A
            // dialog that cannot resize is no longer a fight: the layout
            // clamps its column to the fixed size (see ManagedWindow
            // .fixedSize), exactly like niri bending to the client.
            let window = ws.floatingWindows.remove(at: fi)
            // niri remembers the float position across the round-trip
            // (floating.rs, stored_or_default_tile_pos).
            window.lastFloatingFrame = WindowMover.currentFrame(window.axElement)
            // Re-clamp whichever floating slot was focused now that one left.
            ws.focus(
                floating: ws.floatingFocusedIndex > fi ? ws.floatingFocusedIndex - 1 : ws.floatingFocusedIndex
            )
            let newColumn = Column()
            newColumn.setWindows([window])
            // niri tiles a floating window at its CURRENT width
            // (ColumnWidth::Fixed(tile width), floating.rs:536 via
            // workspace.rs:1403-1410), not at default-column-width.
            if let width = window.lastFloatingFrame?.width {
                newColumn.width = .fixed(min(max(width, 1), 100000))
            }
            let insertAt =
                ws.columns.isEmpty ? 0 : min(ws.focusedIndex + 1, ws.columns.count)
            ws.insertColumn(newColumn, at: insertAt)
            if follow {
                ws.focus(column: insertAt)
                // Unconditionally on the followed path: the window that just
                // got tiled is the one the user is acting on, so focus has to
                // follow it into the columns. Clearing this only when the
                // floating layer emptied left focus reading through
                // isFloatingActive at some OTHER floating window, so the
                // freshly-tiled one got neither focus nor the ring.
                ws.isFloatingActive = false
            }
            reflow()
            if follow { focusCurrentColumn() }
            print("toggle-window-floating -> tiled, column \(insertAt)")
        } else {
            guard case .tiled = t.location else { return }
            let window = t.window
            // One operation, with the fullscreen invariant inside it.
            ws.detachFromTiling(window)
            // niri's stored_or_default_tile_pos (floating.rs): a window
            // that floated before goes back exactly there; only a first
            // float gets the default current frame + (50,50), clamped on
            // screen.
            if let stored = window.lastFloatingFrame {
                _ = ColumnLayoutEngine.applyFrame(window, target: stored)
            } else if let currentFrame = WindowMover.currentFrame(window.axElement) {
                let screenFrame = currentRawScreenFrame()
                var newOrigin = CGPoint(x: currentFrame.origin.x + 50, y: currentFrame.origin.y + 50)
                newOrigin.x = min(newOrigin.x, screenFrame.maxX - currentFrame.width)
                newOrigin.y = min(newOrigin.y, screenFrame.maxY - currentFrame.height)
                try? WindowMover.setFrame(
                    window.axElement, to: CGRect(origin: newOrigin, size: currentFrame.size))
            }
            ws.floatingWindows.append(window)
            if follow {
                ws.focus(floating: ws.floatingWindows.count - 1)
                ws.isFloatingActive = true
            }
            reflow()
            if follow { focusCurrentColumn() }
            print("toggle-window-floating -> floating")
        }
    }

    // niri's switch-focus-between-floating-and-tiling: no-op if either group
    // is empty (focus just stays where it already is).
    func switchFocusBetweenFloatingAndTiling() {
        guard !workspace.floatingWindows.isEmpty, !workspace.columns.isEmpty else { return }
        workspace.isFloatingActive.toggle()
        focusCurrentColumn()
        updateRing()
        print(
            "switch-focus-between-floating-and-tiling -> \(workspace.isFloatingActive ? "floating" : "tiling") (\(describeFocus()))"
        )
    }
}

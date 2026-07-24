import AppKit
import Foundation

// The fine-grained navigation half of niri's action list: the wrapping and
// "or-" variants, addressing by index, the explicit floating/tiling moves,
// and the geometric floating navigation. All of it is model-level - no new
// AX surface, no new geometry - which is why it was the last thing missing.
extension TilingEngine {
    // MARK: - focus

    // niri's focus-column-right-or-first / -left-or-last: the strip is not a
    // ring, but these two actions wrap deliberately.
    func focusColumnWrapping(delta: Int) {
        if workspace.isFloatingActive {
            // niri: focus-column-right-or-first is focus_right, falling to
            // focus_column_first - in the floating space the axial pick,
            // wrapping to the geometric leftmost/rightmost
            // (workspace.rs:940-950). This was a silent no-op here.
            if !focusFloatingGeometric(dx: delta, dy: 0) {
                focusFloatingExtreme(delta > 0 ? .leftmost : .rightmost)
            }
            return
        }
        guard !workspace.columns.isEmpty else { return }
        let next = workspace.focusedIndex + delta
        let wrapped = next < 0 ? workspace.columns.count - 1 : (next >= workspace.columns.count ? 0 : next)
        workspace.focus(column: wrapped)
        reflow()
        focusCurrentColumn()
        print(
            "focus-column-\(delta < 0 ? "left-or-last" : "right-or-first") -> column \(workspace.focusedIndex)"
        )
    }

    // niri's focus-column <index>, 1-based like every other numbered action.
    func focusColumn(index: Int) {
        guard !workspace.columns.isEmpty else { return }
        // niri's focus_column(index) switches to the tiling layer first when
        // the floating layer holds focus (workspace.rs:952-957); leaving the
        // flag set kept the focus reading through the floating window.
        workspace.isFloatingActive = false
        workspace.focus(column: index - 1)
        reflow()
        focusCurrentColumn()
        print("focus-column \(index) -> \(describeFocus())")
    }

    // niri's focus-window-top / -bottom, within the focused column's stack.
    func focusWindowEdge(top: Bool) {
        if workspace.isFloatingActive {
            // niri: focus-window-top/bottom in the floating space are the
            // geometric topmost/bottommost (workspace.rs:1014-1028).
            focusFloatingExtreme(top ? .topmost : .bottommost)
            return
        }
        guard let column = focusedColumn(), !column.windows.isEmpty else { return }
        column.focus(row: top ? 0 : column.windows.count - 1)
        focusCurrentColumn()
        updateRing()
        print("focus-window-\(top ? "top" : "bottom") -> \(describeFocus())")
    }

    // niri's focus-window-down-or-top / -up-or-bottom: wrap inside the stack.
    func focusWindowWrapping(delta: Int) {
        if workspace.isFloatingActive {
            // niri: focus-window-down-or-top is focus_down falling to
            // focus_window_top (workspace.rs:1030-1040) - axial move,
            // wrapping to the geometric extreme.
            if !focusFloatingGeometric(dx: 0, dy: delta) {
                focusFloatingExtreme(delta > 0 ? .topmost : .bottommost)
            }
            return
        }
        guard let column = focusedColumn(), !column.windows.isEmpty else { return }
        let next = column.focusedWindowIndex + delta
        let wrapped = next < 0 ? column.windows.count - 1 : (next >= column.windows.count ? 0 : next)
        column.focus(row: wrapped)
        focusCurrentColumn()
        updateRing()
        print("focus-window-\(delta > 0 ? "down-or-top" : "up-or-bottom") -> \(describeFocus())")
    }

    // niri's focus-window-previous: the most recently focused window before
    // this one, wherever it lives.
    func focusWindowPrevious() {
        guard let previous = previouslyFocusedWindow, locate(previous) != nil else {
            print("focus-window-previous: no previous window")
            return
        }
        guard let location = focusInModel(previous, activateWorkspace: false) else { return }
        if location.workspaceIndex == activeWorkspaceIndex {
            reflow()
            focusCurrentColumn()
        } else {
            focusWorkspace(location.workspaceIndex + 1)
        }
        print("focus-window-previous -> \(previous.title)")
    }

    // niri's focus-floating / focus-tiling: explicit, unlike the toggle.
    func focusLayer(floating: Bool) {
        if floating {
            guard !workspace.floatingWindows.isEmpty else {
                print("focus-floating: no floating windows")
                return
            }
            workspace.isFloatingActive = true
        } else {
            guard !workspace.columns.isEmpty else {
                print("focus-tiling: no tiled windows")
                return
            }
            workspace.isFloatingActive = false
        }
        focusCurrentColumn()
        updateRing()
        print("focus-\(floating ? "floating" : "tiling") -> \(describeFocus())")
    }

    // MARK: - compound focus (niri's -or- actions)

    // niri's focus_down/up report whether the focus MOVED (scrolling.rs:
    // 4738-4747 return false at the stack's edge); every -or- action pivots
    // on that answer. The floating layer answers through the axial pick.
    @discardableResult
    func focusWindowMoved(delta: Int) -> Bool {
        if workspace.isFloatingActive { return focusFloatingGeometric(dx: 0, dy: delta) }
        guard let column = focusedColumn() else { return false }
        let before = column.focusedWindowIndex
        column.moveFocus(by: delta)
        guard column.focusedWindowIndex != before else { return false }
        focusCurrentColumn()
        updateRing()
        return true
    }

    @discardableResult
    func focusColumnMoved(delta: Int) -> Bool {
        if workspace.isFloatingActive { return focusFloatingGeometric(dx: delta, dy: 0) }
        guard !workspace.columns.isEmpty else { return false }
        let before = workspace.focusedIndex
        workspace.moveColumnFocus(by: delta)
        guard workspace.focusedIndex != before else { return false }
        reflow()
        focusCurrentColumn()
        return true
    }

    // niri's focus-window-in-column <n>: the nth window of the focused
    // column, 1-based and clamped; a no-op with the floating layer active
    // (workspace.rs:959-964).
    func focusWindowInColumn(_ index: Int) {
        guard !workspace.isFloatingActive, let column = focusedColumn(), !column.windows.isEmpty
        else { return }
        column.focus(row: min(max(0, index - 1), column.windows.count - 1))
        focusCurrentColumn()
        updateRing()
        print("focus-window-in-column \(index) -> \(describeFocus())")
    }

    // niri's focus-window-down-or-column-left family (workspace.rs:982-1012):
    // move within the stack; at the edge, cross to the column. The floating
    // layer only does the vertical half - upstream has no fallback there.
    func focusWindowOrColumn(deltaY: Int, columnDelta: Int) {
        if workspace.isFloatingActive {
            focusFloatingGeometric(dx: 0, dy: deltaY)
            return
        }
        if !focusWindowMoved(delta: deltaY) { _ = focusColumnMoved(delta: columnDelta) }
        print("focus-window-or-column -> \(describeFocus())")
    }

    // niri's focus-window-or-workspace-up/down (monitor.rs:773-783): within
    // the stack; at the edge, the adjacent workspace.
    func focusWindowOrWorkspace(delta: Int) {
        if !focusWindowMoved(delta: delta) { focusWorkspaceRelative(delta: delta) }
    }

    // niri's focus-column-or-monitor-left/right and focus-window-or-monitor-
    // up/down (mod.rs:1975-2012): the inner move, falling to the output in
    // that direction when it did not move.
    func focusColumnOrMonitor(delta: Int, direction: MonitorDirection) {
        if !focusColumnMoved(delta: delta) { focusMonitor(direction) }
    }
    func focusWindowOrMonitor(delta: Int, direction: MonitorDirection) {
        if !focusWindowMoved(delta: delta) { focusMonitor(direction) }
    }

    // niri's move-window-down-or-to-workspace-down / up (window moves within
    // the stack; at the edge it travels to the adjacent workspace).
    func moveWindowOrToWorkspace(delta: Int) {
        guard !workspace.isFloatingActive, let column = focusedColumn() else { return }
        let target = column.focusedWindowIndex + delta
        if column.windows.indices.contains(target) {
            moveWindowInStack(delta: delta)
        } else {
            moveWindowToWorkspace(activeWorkspaceIndex + 1 + delta)
        }
    }

    // niri's move-column-left-or-to-monitor-left / right: the column moves
    // within the strip; at the edge it travels to the output.
    func moveColumnOrToMonitor(delta: Int, direction: MonitorDirection) {
        guard !workspace.isFloatingActive, !workspace.columns.isEmpty else { return }
        let target = workspace.focusedIndex + delta
        if workspace.columns.indices.contains(target) {
            moveColumn(delta: delta)
        } else {
            moveColumnToMonitor(direction)
        }
    }

    // MARK: - movement

    // niri's swap-window-left/right: exchanges the focused WINDOW with its
    // neighbour, which is not the same as moving its whole column.
    func swapWindow(delta: Int) {
        guard !workspace.isFloatingActive, let column = focusedColumn() else { return }
        let neighbourIndex = workspace.focusedIndex + delta
        guard workspace.columns.indices.contains(neighbourIndex) else {
            print("swap-window: already at the edge")
            return
        }
        let neighbour = workspace.columns[neighbourIndex]
        guard let mine = focusedStackWindow(), let theirs = neighbour.focusedWindow else { return }
        guard let myRow = column.windows.firstIndex(where: { $0 === mine }),
            let theirRow = neighbour.windows.firstIndex(where: { $0 === theirs })
        else { return }
        column.replaceWindow(at: myRow, with: theirs)
        neighbour.replaceWindow(at: theirRow, with: mine)
        workspace.focus(column: neighbourIndex)
        neighbour.focus(window: mine)
        reflow()
        focusCurrentColumn()
        print("swap-window-\(delta < 0 ? "left" : "right") -> \(describeFocus())")
    }

    // niri's move-column-to-index / move-workspace-to-index, both 1-based.
    func moveColumnToIndex(_ index: Int) {
        guard !workspace.isFloatingActive, workspace.columns.indices.contains(workspace.focusedIndex) else {
            return
        }
        let target = min(max(0, index - 1), workspace.columns.count - 1)
        guard target != workspace.focusedIndex else { return }
        guard let column = workspace.removeColumn(at: workspace.focusedIndex) else { return }
        workspace.insertColumn(column, at: target)
        workspace.focus(column: target)
        reflow()
        print("move-column-to-index \(index)")
    }

    // Where an index ends up after an element moves from `from` to `to` in
    // an array (remove + insert). Everything between the two shifts by one,
    // which is why this cannot be skipped for previousWorkspaceIndex: after
    // a move it pointed at a workspace the user had never been on - or at the
    // active one, which makes focus-workspace-previous a silent no-op.
    // moveWorkspace(delta:) already remaps across its swap; this one did not.
    static func indexAfterMove(_ index: Int, from: Int, to: Int) -> Int {
        if index == from { return to }
        if from < to { return (index > from && index <= to) ? index - 1 : index }
        return (index >= to && index < from) ? index + 1 : index
    }

    func moveWorkspaceToIndex(_ index: Int) {
        let target = min(max(0, index - 1), workspaces.count - 1)
        guard target != activeWorkspaceIndex else { return }
        let from = activeWorkspaceIndex
        let moved = workspaces.remove(at: from)
        workspaces.insert(moved, at: target)
        activeWorkspaceIndex = target
        previousWorkspaceIndex = TilingEngine.indexAfterMove(previousWorkspaceIndex, from: from, to: target)
        // Same in-the-act invariant restore as move-workspace-up/down
        // (monitor.rs:1294-1343).
        compactWorkspaces()
        reflow()
        emitWorkspacesChanged()
        print("move-workspace-to-index \(index)")
    }

    // Where a window lands on the workspace it is moved to. A dialog counts
    // even when the floating layer is not the active one: it refuses the
    // writes a column would make, so tiling it is a fight with no winner.
    static func landsFloating(floatingLayerActive: Bool, isDialog: Bool, inFloatingList: Bool) -> Bool {
        floatingLayerActive || isDialog || inFloatingList
    }

    // niri's move-window-to-workspace: just this window, not its column.
    func moveWindowToWorkspace(_ number: Int, focus: Bool = true, id: UInt64? = nil) {
        // niri's MoveWindowToWorkspace { window_id, reference, focus }: the
        // window may live anywhere; it detaches from ITS workspace, not the
        // active one.
        guard let t = windowTarget(id: id, action: "move-window-to-workspace") else { return }
        let window = t.window
        let source = workspaces[t.workspaceIndex]
        let targetIndex = min(max(0, number - 1), max(0, workspaces.count - 1))
        guard targetIndex != t.workspaceIndex else { return }
        let sourceIsFloating: Bool
        if case .floating = t.location { sourceIsFloating = true } else { sourceIsFloating = false }
        // Captured before the detach below: the moved tile keeps its
        // column's width on arrival (niri's RemovedTile.width).
        var sourceWidth: ColumnWidth? = nil
        if case .tiled(_, let ci, _) = t.location { sourceWidth = source.columns[ci].width }
        let screenFrame = currentRawScreenFrame()
        // Where it lives decides where it lands: a floating window (or a
        // dialog, which can never be tiled - it refuses the writes) went into
        // a COLUMN on the other workspace, which is the invariant
        // toggleWindowFloating is careful to protect. From then on the tiling
        // pass fought a window that cannot be moved.
        let wasFloating = TilingEngine.landsFloating(
            floatingLayerActive: sourceIsFloating,
            isDialog: window.isDialog,
            inFloatingList: sourceIsFloating)
        // Detach from wherever it lives now.
        if sourceIsFloating {
            source.floatingWindows.removeAll { $0 === window }
        } else {
            if case .tiled(_, let ci, _) = t.location { source.columns[ci].cachedHeights = nil }
            // Same invariant as toggle-window-floating: a window that leaves
            // the tiled side cannot stay the workspace's fullscreen one.
            source.detachFromTiling(window)
        }
        source.clampFocus()
        let target = workspaces[targetIndex]
        if wasFloating {
            target.floatingWindows.append(window)
            // With focus=false the target workspace's focus and active
            // layer stay untouched (niri's ActivateWindow::No).
            if focus {
                target.focus(floating: target.floatingWindows.count - 1)
                target.isFloatingActive = true
            }
        } else {
            let newColumn = Column()
            newColumn.setWindows([window])
            if let sourceWidth { newColumn.width = sourceWidth }
            // Next to the target's active column, not at the end (niri's
            // add_tile/add_column default, scrolling.rs:972-978); activated
            // only when the focus follows (audit ACT-4). Without the layer
            // reset a tiled window landed with the floating layer in front
            // and the focus went to a dialog instead.
            let insertAt = target.columns.isEmpty ? 0 : min(target.focusedIndex + 1, target.columns.count)
            target.insertColumn(newColumn, at: insertAt, activating: focus)
            if focus { target.isFloatingActive = false }
        }
        if let frame = WindowMover.currentFrame(window.axElement) {
            window.stashedFrame = frame
            _ = ColumnLayoutEngine.applyFrame(
                window, target: parkedOffScreen(frame, screenFrame: screenFrame))
        }
        print("move-window-to-workspace \(number)")
        if focus { focusWorkspace(targetIndex + 1) } else { reflow() }
    }

    // niri's move-window-to-floating / -to-tiling: the explicit halves of
    // the toggle, so a bind can be idempotent.
    func moveWindow(toFloating: Bool, id: UInt64? = nil) {
        guard let t = windowTarget(id: id, action: "move-window-to-\(toFloating ? "floating" : "tiling")")
        else { return }
        let isFloating: Bool
        if case .floating = t.location { isFloating = true } else { isFloating = false }
        guard isFloating != toFloating else {
            print("move-window-to-\(toFloating ? "floating" : "tiling"): already there")
            return
        }
        toggleWindowFloating(id: id)
    }

    // niri's center-window (CenterWindow { id }): the target window's
    // column centred - by id wherever it lives, without moving focus; a
    // floating target centres the window itself, like center_column's
    // floating path.
    func centerWindow(id: UInt64? = nil) {
        guard let t = windowTarget(id: id, action: "center-window") else { return }
        switch t.location {
        case .floating:
            centerFloatingWindow(t.window)
        case .tiled(let wi, let ci, _):
            let ws = workspaces[wi]
            let usableWidth = usableScreen().usableWidth
            let placements = ColumnLayoutEngine.columnPlacements(
                columns: ws.columns, usableWidth: usableWidth)
            guard placements.indices.contains(ci) else { return }
            let p = placements[ci]
            let offset = p.x + p.width / 2 - usableWidth / 2
            if wi == activeWorkspaceIndex {
                reflow(explicitViewOffset: offset)
            } else {
                // A stashed workspace only stores its camera; it applies
                // when the workspace is entered.
                ws.viewOffset = offset
            }
            print("center-window")
        }
    }

    // MARK: - column display

    // niri's set-column-display "tabbed"/"normal", next to the toggle.
    func setColumnDisplay(tabbed: Bool) {
        guard let column = focusedColumn() else { return }
        guard column.isTabbed != tabbed else { return }
        toggleColumnTabbedDisplay()
    }

    // MARK: - workspace names

    // niri's set-workspace-name / unset-workspace-name, at runtime.
    func setWorkspaceName(_ name: String?) {
        workspace.name = name
        if let name {
            print("set-workspace-name -> \(name)")
        } else {
            print("unset-workspace-name")
        }
        msgServer.broadcastLegacy("{\"event\":\"workspaces\"}")
        emitWorkspacesChanged()
    }

    // MARK: - floating navigation

    // niri's floating focus_directional (floating.rs:839-877): the signed
    // AXIAL distance between window centers - nothing else. No axis
    // dominance, no euclidean tiebreak (the old version had both, so it
    // picked different windows than niri whenever candidates were
    // diagonal). Every other floating window with axial distance > 0 in
    // the asked direction competes; the smallest wins. Returns whether a
    // candidate existed, which is what the -or- variants wrap on.
    @discardableResult
    func focusFloatingGeometric(dx: Int, dy: Int) -> Bool {
        let windows = workspace.floatingWindows
        guard windows.indices.contains(workspace.floatingFocusedIndex),
            let current = WindowMover.currentFrame(windows[workspace.floatingFocusedIndex].axElement)
        else { return false }
        var best: (index: Int, distance: CGFloat)?
        for (i, w) in windows.enumerated() where i != workspace.floatingFocusedIndex {
            guard let frame = WindowMover.currentFrame(w.axElement) else { continue }
            let distance =
                dx != 0
                ? (dx > 0 ? frame.midX - current.midX : current.midX - frame.midX)
                : (dy > 0 ? frame.midY - current.midY : current.midY - frame.midY)
            guard distance > 0 else { continue }
            if best == nil || distance < best!.distance { best = (i, distance) }
        }
        guard let best else { return false }
        workspace.focus(floating: best.index)
        focusCurrentColumn()
        updateRing()
        print("focus-floating -> \(describeFocus())")
        return true
    }

    // niri's focus_leftmost/rightmost/topmost/bottommost (floating.rs:
    // 879-917): min/max by the tile's POSITION (origin), not its center.
    enum FloatingExtreme { case leftmost, rightmost, topmost, bottommost }
    func focusFloatingExtreme(_ extreme: FloatingExtreme) {
        let windows = workspace.floatingWindows
        guard !windows.isEmpty else { return }
        var best: (index: Int, key: CGFloat)?
        for (i, w) in windows.enumerated() {
            guard let frame = WindowMover.currentFrame(w.axElement) else { continue }
            let key: CGFloat
            switch extreme {
            case .leftmost: key = frame.origin.x
            case .rightmost: key = -frame.origin.x
            case .topmost: key = frame.origin.y
            case .bottommost: key = -frame.origin.y
            }
            if best == nil || key < best!.key { best = (i, key) }
        }
        guard let best else { return }
        workspace.focus(floating: best.index)
        focusCurrentColumn()
        updateRing()
        print("focus-floating-\(extreme) -> \(describeFocus())")
    }

    // niri's floating center_window (floating.rs:1005-1013):
    // center_preferring_top_left_in_area - centered in the working area,
    // and a window LARGER than the area pins its top-left corner into view
    // (the offset clamps at 0 per axis, utils/mod.rs:525-535).
    func centerFloatingWindow(_ window: ManagedWindow? = nil) {
        guard let w = window ?? focusedFloatingWindow() else { return }
        guard let frame = settledFrame(of: w) else { return }
        let area = usableScreen().frame
        let x = area.minX + max(0, (area.width - frame.width) / 2)
        let y = area.minY + max(0, (area.height - frame.height) / 2)
        animateFrames([(window: w, frame: CGRect(origin: CGPoint(x: x, y: y), size: frame.size))]) {
            _ in
        }
        print("center-window (floating) -> \(w.title)")
    }
}

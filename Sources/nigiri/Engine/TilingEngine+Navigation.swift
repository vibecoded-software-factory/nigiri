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
        guard !workspace.isFloatingActive, !workspace.columns.isEmpty else { return }
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
        workspace.focus(column: index - 1)
        reflow()
        focusCurrentColumn()
        print("focus-column \(index) -> \(describeFocus())")
    }

    // niri's focus-window-top / -bottom, within the focused column's stack.
    func focusWindowEdge(top: Bool) {
        guard let column = focusedColumn(), !column.windows.isEmpty else { return }
        column.focus(row: top ? 0 : column.windows.count - 1)
        focusCurrentColumn()
        updateRing()
        print("focus-window-\(top ? "top" : "bottom") -> \(describeFocus())")
    }

    // niri's focus-window-down-or-top / -up-or-bottom: wrap inside the stack.
    func focusWindowWrapping(delta: Int) {
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
        print("move-workspace-to-index \(index)")
    }

    // Where a window lands on the workspace it is moved to. A dialog counts
    // even when the floating layer is not the active one: it refuses the
    // writes a column would make, so tiling it is a fight with no winner.
    static func landsFloating(floatingLayerActive: Bool, isDialog: Bool, inFloatingList: Bool) -> Bool {
        floatingLayerActive || isDialog || inFloatingList
    }

    // niri's move-window-to-workspace: just this window, not its column.
    func moveWindowToWorkspace(_ number: Int, focus: Bool = true) {
        guard let window = focusedManagedWindow() else { return }
        let targetIndex = min(max(0, number - 1), max(0, workspaces.count - 1))
        guard targetIndex != activeWorkspaceIndex else { return }
        while workspaces.count <= targetIndex { workspaces.append(Workspace()) }
        let screenFrame = currentRawScreenFrame()
        // Where it lives decides where it lands: a floating window (or a
        // dialog, which can never be tiled - it refuses the writes) went into
        // a COLUMN on the other workspace, which is the invariant
        // toggleWindowFloating is careful to protect. From then on the tiling
        // pass fought a window that cannot be moved.
        let wasFloating = TilingEngine.landsFloating(
            floatingLayerActive: workspace.isFloatingActive,
            isDialog: window.isDialog,
            inFloatingList: workspace.floatingWindows.contains { $0 === window })
        // Detach from wherever it lives now.
        if workspace.isFloatingActive {
            workspace.floatingWindows.removeAll { $0 === window }
        } else {
            focusedColumn()?.cachedHeights = nil
            // Same invariant as toggle-window-floating: a window that leaves
            // the tiled side cannot stay the workspace's fullscreen one.
            workspace.detachFromTiling(window)
        }
        workspace.clampFocus()
        let target = workspaces[targetIndex]
        if wasFloating {
            target.floatingWindows.append(window)
            target.focus(floating: target.floatingWindows.count - 1)
            target.isFloatingActive = true
        } else {
            let newColumn = Column()
            newColumn.setWindows([window])
            target.appendColumn(newColumn)
            target.focus(column: target.columns.count - 1)
            // Without this the arriving workspace kept whatever layer was
            // active last, so a tiled window landed with the floating layer
            // in front and the focus went to a dialog instead.
            target.isFloatingActive = false
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
    func moveWindow(toFloating: Bool) {
        guard workspace.isFloatingActive != toFloating else {
            print("move-window-to-\(toFloating ? "floating" : "tiling"): already there")
            return
        }
        toggleWindowFloating()
    }

    // niri's center-window: only the focused window's column, centred.
    func centerWindow() { centerColumn() }

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
        msgServer.broadcast("{\"event\":\"workspaces\"}")
        emitWorkspacesChanged()
    }

    // MARK: - floating navigation

    // niri's floating space navigates GEOMETRICALLY (src/layout/floating.rs):
    // the nearest window in the direction asked for, not the next entry in an
    // arbitrary list - which is what nigiri did, so "focus right" could jump
    // to a window on the left.
    func focusFloatingGeometric(dx: Int, dy: Int) {
        guard workspace.isFloatingActive, workspace.floatingWindows.count > 1 else {
            focusColumn(delta: dx != 0 ? dx : dy)
            return
        }
        let windows = workspace.floatingWindows
        guard windows.indices.contains(workspace.floatingFocusedIndex),
            let current = WindowMover.currentFrame(windows[workspace.floatingFocusedIndex].axElement)
        else { return }
        var best: (index: Int, distance: CGFloat)?
        for (i, w) in windows.enumerated() where i != workspace.floatingFocusedIndex {
            guard let frame = WindowMover.currentFrame(w.axElement) else { continue }
            let ddx = frame.midX - current.midX
            let ddy = frame.midY - current.midY
            // Must genuinely lie in the requested direction, and that axis
            // must dominate - otherwise "right" picks something below.
            if dx != 0 {
                guard (dx > 0 ? ddx > 1 : ddx < -1), abs(ddx) >= abs(ddy) else { continue }
            } else {
                guard (dy > 0 ? ddy > 1 : ddy < -1), abs(ddy) >= abs(ddx) else { continue }
            }
            let distance = (ddx * ddx + ddy * ddy).squareRoot()
            if best == nil || distance < best!.distance { best = (i, distance) }
        }
        guard let best else {
            print("focus-floating: no window in that direction")
            return
        }
        workspace.focus(floating: best.index)
        focusCurrentColumn()
        updateRing()
        print("focus-floating (geometrico) -> \(describeFocus())")
    }
}

import AppKit
import Foundation

enum MonitorDirection { case left, right, up, down }

// Multi-monitor: reconciling the Output set against the live displays, laying
// out every output (not just the focused one), and the focus/move-to-monitor
// navigation. niri's model - each output owns its workspaces, one output is
// focused, and windows tile against the output they live on.
extension TilingEngine {
    // The full frame of an output in AX/CG top-left space (the whole display,
    // menu bar and Dock included) - used to decide which monitor a window sits
    // on. The Y flip is against the primary's height, like every other AX
    // conversion here.
    func outputFullFrameAX(_ output: Output) -> CGRect {
        guard let screen = output.screen, let primary = NSScreen.screens.first else { return .zero }
        let f = screen.frame
        let flippedY = primary.frame.height - f.origin.y - f.height
        return CGRect(x: f.origin.x, y: flippedY, width: f.width, height: f.height)
    }

    // The output a window frame belongs to: the one whose display contains the
    // frame's centre, else the one it overlaps most, else nil.
    func outputContaining(_ frame: CGRect?) -> Output? {
        guard let frame else { return nil }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        if let hit = outputs.first(where: { outputFullFrameAX($0).contains(centre) }) { return hit }
        func overlap(_ o: Output) -> CGFloat {
            let r = outputFullFrameAX(o).intersection(frame)
            return r.isNull ? 0 : r.width * r.height
        }
        return outputs.max { overlap($0) < overlap($1) }
    }

    // Reconcile `outputs` against NSScreen.screens, keyed by the stable display
    // id. Displays are returned primary-first. A newly-attached display gets a
    // fresh single-workspace Output; a detached one hands its windows to the
    // primary's active workspace so nothing is orphaned off-screen. Focus is
    // preserved by identity where possible.
    func syncOutputs() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }  // keep what we have if asked mid-teardown

        let focusedID = focusedOutput.displayID
        var byID: [CGDirectDisplayID: Output] = [:]
        for o in outputs { byID[o.displayID] = o }

        var rebuilt: [Output] = []
        var seen = Set<CGDirectDisplayID>()
        for screen in screens {
            guard let id = Output.displayID(of: screen) else { continue }
            seen.insert(id)
            if let existing = byID[id] {
                existing.screen = screen
                existing.name = TilingEngine.outputName(screen) ?? existing.name
                rebuilt.append(existing)
            } else {
                let output = Output(
                    displayID: id, name: TilingEngine.outputName(screen) ?? "display-\(id)",
                    screen: screen)
                rebuilt.append(output)
                print("[output] attached: \(output.name)")
            }
        }
        guard !rebuilt.isEmpty else { return }

        // Detached displays: migrate their windows onto the first surviving
        // output's active workspace rather than leaving them stranded.
        let survivor = rebuilt[0].activeWorkspace
        for old in outputs where !seen.contains(old.displayID) {
            print("[output] detached: \(old.name) - migrating its windows")
            for ws in old.workspaces {
                for column in ws.columns { survivor.appendColumn(column) }
                for floating in ws.floatingWindows { survivor.floatingWindows.append(floating) }
            }
        }

        outputs = rebuilt
        focusedOutputIndex = rebuilt.firstIndex { $0.displayID == focusedID } ?? 0
    }

    // Lay out a specific output's active workspace against its own frame. The
    // focused output is handled by the normal relayout/reflow path; this is for
    // every OTHER output, whose windows must still sit correctly on their
    // monitor even though the user is working elsewhere.
    func layoutOutput(_ output: Output) {
        let ws = output.activeWorkspace
        let frame = usableScreen(for: output).frame
        watcher.applyingLayout {
            _ = ColumnLayoutEngine.layout(
                columns: ws.columns, in: frame,
                viewOffset: ws.viewOffset, skipping: ws.fullscreenWindow)
        }
    }

    func layoutAllOutputs() {
        for output in outputs where output !== focusedOutput { layoutOutput(output) }
    }

    // Which output and workspace a window element lives on, searched across
    // every output - used by focus-follows-window to move the focus to the
    // monitor a clicked window is on.
    func locateWindow(_ element: AXUIElement) -> (output: Int, workspace: Int)? {
        for (oi, output) in outputs.enumerated() {
            for (wi, ws) in output.workspaces.enumerated()
            where ws.allWindows.contains(where: { CFEqual($0.axElement, element) }) {
                return (oi, wi)
            }
        }
        return nil
    }

    // Make `output` the focused one and bring its active workspace to the fore:
    // relayout now targets it (the proxies follow the focus), and its focused
    // column is raised.
    func focusOutput(_ index: Int) {
        guard outputs.indices.contains(index), index != focusedOutputIndex else { return }
        focusedOutputIndex = index
        print("focus-monitor -> \(focusedOutput.name) (\(focusedOutput.workspaces.count) workspace(s))")
        relayout()
        focusCurrentColumn()
        emitWorkspacesChanged()
        emitWindowFocusChanged(focusedManagedWindow())
    }

    // The output in a given direction from the focused one, by display centre -
    // niri's focus-monitor-left/right/up/down.
    func outputIndex(inDirection direction: MonitorDirection) -> Int? {
        let from = outputFullFrameAX(focusedOutput)
        let origin = CGPoint(x: from.midX, y: from.midY)
        var best: (index: Int, distance: CGFloat)?
        for (i, output) in outputs.enumerated() where i != focusedOutputIndex {
            let frame = outputFullFrameAX(output)
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            let dx = centre.x - origin.x
            let dy = centre.y - origin.y
            let matches: Bool
            switch direction {
            case .left: matches = dx < 0 && abs(dx) >= abs(dy)
            case .right: matches = dx > 0 && abs(dx) >= abs(dy)
            case .up: matches = dy < 0 && abs(dy) > abs(dx)
            case .down: matches = dy > 0 && abs(dy) > abs(dx)
            }
            guard matches else { continue }
            let distance = dx * dx + dy * dy
            if best == nil || distance < best!.distance { best = (i, distance) }
        }
        return best?.index
    }

    // niri's focus-monitor-next/previous: cycle the outputs in order.
    func focusMonitorRelative(_ delta: Int) {
        guard outputs.count > 1 else { return }
        focusOutput((focusedOutputIndex + delta + outputs.count) % outputs.count)
    }

    // niri's move-column-to-monitor-next/previous, reusing the directional
    // move's machinery with a cycled target.
    func moveColumnToMonitorRelative(_ delta: Int) {
        guard outputs.count > 1 else { return }
        moveColumnToMonitor(outputIndex: (focusedOutputIndex + delta + outputs.count) % outputs.count)
    }

    // niri's move-workspace-to-monitor: the ACTIVE workspace relocates to
    // the target output (focus follows), and both outputs re-settle their
    // dynamic-workspace invariants. NOTE: exercised only on a single output
    // so far (guarded no-op there); the multi-monitor path follows the same
    // stash/restore dance as move-column-to-monitor.
    func moveWorkspaceToMonitor(outputIndex: Int) {
        guard outputs.indices.contains(outputIndex), outputIndex != focusedOutputIndex else { return }
        let source = outputs[focusedOutputIndex]
        let target = outputs[outputIndex]
        let ws = source.workspaces[source.activeWorkspaceIndex]
        source.workspaces.remove(at: source.activeWorkspaceIndex)
        if source.workspaces.isEmpty { source.workspaces = [Workspace()] }
        source.activeWorkspaceIndex = min(source.activeWorkspaceIndex, source.workspaces.count - 1)
        source.previousWorkspaceIndex = min(source.previousWorkspaceIndex, source.workspaces.count - 1)
        // In front of the target's trailing empty workspace, like a moved
        // column's arrival.
        let insertAt = max(0, target.workspaces.count - 1)
        target.workspaces.insert(ws, at: insertAt)
        target.activeWorkspaceIndex = insertAt
        focusOutput(outputIndex)
        compactWorkspaces()
        reflow()
        emitWorkspacesChanged()
        print("move-workspace-to-monitor -> \(target.name)")
    }

    func moveWorkspaceToMonitor(_ direction: MonitorDirection) {
        guard let index = outputIndex(inDirection: direction) else {
            print("move-workspace-to-monitor \(direction): no monitor there")
            return
        }
        moveWorkspaceToMonitor(outputIndex: index)
    }

    func moveWorkspaceToMonitorRelative(_ delta: Int) {
        guard outputs.count > 1 else { return }
        moveWorkspaceToMonitor(outputIndex: (focusedOutputIndex + delta + outputs.count) % outputs.count)
    }

    func focusMonitor(_ direction: MonitorDirection) {
        guard let index = outputIndex(inDirection: direction) else {
            print("focus-monitor \(direction): no monitor there")
            return
        }
        focusOutput(index)
    }

    // niri's move-column-to-monitor: relocate the focused column to the monitor
    // in the given direction, following the focus there.
    func moveColumnToMonitor(_ direction: MonitorDirection) {
        guard let index = outputIndex(inDirection: direction) else {
            print("move-column-to-monitor \(direction): no monitor there")
            return
        }
        moveColumnToMonitor(outputIndex: index)
    }

    func moveColumnToMonitor(outputIndex index: Int) {
        guard outputs.indices.contains(index), index != focusedOutputIndex else { return }
        guard !workspace.isFloatingActive,
            workspace.columns.indices.contains(workspace.focusedIndex),
            let column = workspace.removeColumn(at: workspace.focusedIndex)
        else { return }
        // Fullscreen rides the column to the other monitor (per-column
        // flag, audit LAY-4) - upstream keeps it too.
        workspace.focus(column: nearestVisiblyOccupiedColumnIndex(from: workspace.focusedIndex))
        let target = outputs[index]
        target.activeWorkspace.appendColumn(column)
        target.activeWorkspace.focus(column: target.activeWorkspace.columns.count - 1)
        target.activeWorkspace.isFloatingActive = false
        print("move-column-to-monitor -> \(target.name)")
        reflow()  // the output the column left
        focusOutput(index)  // follow it, and lay the target out
    }
}

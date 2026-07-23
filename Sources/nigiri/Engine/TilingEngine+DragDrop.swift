import AppKit
import Foundation

// niri's interactive move inside the layout: the dragged WINDOW (not its
// whole column) lands wherever the insert hint says - a new column between
// two columns, or a slot inside a column's stack. The rule that picks
// between the two is niri's own (scrolling.rs, insert_position): whichever
// GAP is closest to the cursor wins, ties to a new column.
extension TilingEngine {
    // The current on-screen frames, grouped per column, in column order.
    // Built from the layout's own targets so the hint matches where the
    // windows actually are - including a column mid-animation.
    func currentColumnFrames() -> [[CGRect]] {
        let (screenFrame, _) = usableScreen()
        // Without the parked ones: in a TABBED column they sit at maxX-1, and
        // this list is consumed as "the frames of each column" - so the first
        // entry of a tabbed column was the parking spot instead of the window
        // on screen. Consequences: insertPosition measured the gap against
        // the right screen edge (so the hint appeared there and the window
        // landed on the wrong side) and `.inColumn` was unreachable over a
        // tabbed column - it could not be dropped in as a tab at all.
        let targets = ColumnLayoutEngine.targetFrames(
            columns: workspace.columns, in: screenFrame,
            maximizedIndex: workspace.maximizedIndex, viewOffset: workspace.viewOffset,
            includingParked: false)
        var byWindow: [ObjectIdentifier: CGRect] = [:]
        for (window, frame) in targets { byWindow[ObjectIdentifier(window)] = frame }
        return workspace.columns.map { column in
            column.windows.compactMap { byWindow[ObjectIdentifier($0)] }
        }
    }

    // Where the drag would drop right now, and the slab to paint for it.
    func insertPreview(at point: CGPoint) -> (position: ColumnLayoutEngine.InsertPosition, hint: CGRect)? {
        let (screenFrame, usableWidth) = usableScreen()
        let frames = currentColumnFrames()
        guard !frames.isEmpty else { return nil }
        let position = ColumnLayoutEngine.insertPosition(
            columnFrames: frames, point: point, screenFrame: screenFrame,
            tabbed: workspace.columns.map { $0.isTabbed ? $0.focusedWindowIndex : nil })
        let gap = ColumnLayoutEngine.gap
        switch position {
        case .newColumn(let index):
            // niri's insert hint slab is a FIXED 300px wide (scrolling.rs:
            // 2436), not the would-be column width - the hint marks the
            // slot, it does not preview the size.
            let width: CGFloat = 300
            let x: CGFloat
            if index < frames.count, let first = frames[index].first {
                x = first.minX - gap / 2 - width / 2
            } else if let last = frames.last?.first {
                x = last.maxX + gap / 2 - width / 2
            } else {
                x = screenFrame.minX + gap
            }
            return (
                position,
                CGRect(
                    x: x, y: screenFrame.minY + gap,
                    width: width, height: screenFrame.height - 2 * gap)
            )
        case .inColumn(let columnIndex, let row):
            let columnFrames = frames[columnIndex]
            guard let reference = columnFrames.first else { return nil }
            // niri's in-column band is a FIXED 150px tall (scrolling.rs:
            // 2436-2516), not a computed tile share.
            let height: CGFloat = 150
            let y: CGFloat
            if row < columnFrames.count {
                y = columnFrames[row].minY - gap / 2 - height / 2
            } else {
                y = (columnFrames.last?.maxY ?? reference.maxY) + gap / 2 - height / 2
            }
            return (position, CGRect(x: reference.minX, y: y, width: reference.width, height: height))
        }
    }

    // Applies the drop. Returns whether the model changed.
    @discardableResult
    func dropWindow(_ window: ManagedWindow, at position: ColumnLayoutEngine.InsertPosition) -> Bool {
        guard
            let sourceColumnIndex = workspace.columns.firstIndex(where: {
                $0.windows.contains { $0 === window }
            }),
            let sourceRow = workspace.columns[sourceColumnIndex].windows.firstIndex(where: { $0 === window })
        else { return false }
        let source = workspace.columns[sourceColumnIndex]

        switch position {
        case .newColumn(var index):
            // Already alone in a column that is exactly there: nothing to do.
            if source.windows.count == 1, index == sourceColumnIndex || index == sourceColumnIndex + 1 {
                return false
            }
            source.removeWindow(at: sourceRow)
            source.cachedHeights = nil
            if source.windows.isEmpty {
                workspace.removeColumn(at: sourceColumnIndex)
                if index > sourceColumnIndex { index -= 1 }
            }
            let column = Column()
            column.setWindows([window])
            // The new column inherits the width the source had: a drag is a
            // move, not a resize.
            column.widthProportion = source.widthProportion
            workspace.insertColumn(column, at: min(max(0, index), workspace.columns.count))
            workspace.focus(column: min(max(0, index), workspace.columns.count - 1))
        case .inColumn(let columnIndex, let row):
            guard workspace.columns.indices.contains(columnIndex) else { return false }
            let target = workspace.columns[columnIndex]
            if target === source {
                // Same stack: a reorder. The removal shifts every later row.
                let clamped = min(max(0, row), source.windows.count)
                if clamped == sourceRow || clamped == sourceRow + 1 { return false }
                source.removeWindow(at: sourceRow)
                source.insert(window, at: clamped > sourceRow ? clamped - 1 : clamped)
                source.cachedHeights = nil
                source.focus(window: window)
                workspace.focus(column: columnIndex)
                break
            }
            source.removeWindow(at: sourceRow)
            source.cachedHeights = nil
            var targetIndex = columnIndex
            if source.windows.isEmpty {
                workspace.removeColumn(at: sourceColumnIndex)
                if targetIndex > sourceColumnIndex { targetIndex -= 1 }
            }
            let landing = workspace.columns[targetIndex]
            landing.insert(window, at: min(max(0, row), landing.windows.count))
            landing.cachedHeights = nil
            landing.focus(window: window)
            workspace.focus(column: targetIndex)
        }
        workspace.clampFocus()
        ColumnLayoutEngine.newEpoch()
        return true
    }
}

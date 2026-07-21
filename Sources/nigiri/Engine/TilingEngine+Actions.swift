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
            guard !workspace.floatingWindows.isEmpty else { return }
            workspace.moveFloatingFocus(by: delta)
            focusCurrentColumn()
            updateRing()
            print("focus-floating-\(delta < 0 ? "prev" : "next") -> \(describeFocus())")
            return
        }
        guard !workspace.columns.isEmpty else { return }
        workspace.moveColumnFocus(by: delta)
        reflow()  // scrolls the strip to keep the newly-focused column in view; keeps the ring in sync every animation step
        focusCurrentColumn()
        print(
            "focus-column-\(delta < 0 ? "left" : "right") -> column \(workspace.focusedIndex) (\(describeFocus()))"
        )
    }
    func focusColumnEdge(first: Bool) {
        if workspace.isFloatingActive {
            guard !workspace.floatingWindows.isEmpty else { return }
            workspace.focus(floating: first ? 0 : workspace.floatingWindows.count - 1)
            focusCurrentColumn()
            updateRing()
            print("focus-floating-\(first ? "first" : "last") -> \(describeFocus())")
            return
        }
        guard !workspace.columns.isEmpty else { return }
        workspace.focus(column: first ? 0 : workspace.columns.count - 1)
        reflow()
        focusCurrentColumn()
        print(
            "focus-column-\(first ? "first" : "last") -> column \(workspace.focusedIndex) (\(describeFocus()))"
        )
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
    func moveFloatingWindow(dx: CGFloat, dy: CGFloat) {
        guard workspace.floatingWindows.indices.contains(workspace.floatingFocusedIndex) else { return }
        let w = workspace.floatingWindows[workspace.floatingFocusedIndex]
        guard let frame = settledFrame(of: w) else { return }
        animateFrames([(window: w, frame: frame.offsetBy(dx: dx, dy: dy))]) { _ in }
        print("move-floating-window (\(Int(dx)),\(Int(dy))) -> \(w.title)")
    }

    // niri's set-window-width/height on a floating window (src/layout/
    // floating.rs): the delta is a percentage of the working area applied
    // to the window's own size, resizing in place - driven by the same
    // ±10% keys as tiled sizing, dispatched by which group holds focus.
    // A fixed-size dialog just refuses the write (logged once, then the
    // refusal is remembered - see ManagedWindow.lastRequestedFrame).
    func resizeFloatingWindow(widthDeltaPercent: CGFloat = 0, heightDeltaPercent: CGFloat = 0) {
        guard workspace.floatingWindows.indices.contains(workspace.floatingFocusedIndex) else { return }
        let w = workspace.floatingWindows[workspace.floatingFocusedIndex]
        guard let frame = settledFrame(of: w) else { return }
        let screenFrame = ScreenGeometry.primaryScreenVisibleFrameInAXSpace()
        var target = frame
        target.size.width = max(50, frame.width + screenFrame.width * widthDeltaPercent / 100)
        target.size.height = max(50, frame.height + screenFrame.height * heightDeltaPercent / 100)
        animateFrames([(window: w, frame: target)]) { _ in }
        print(
            "resize-floating-window \(Int(widthDeltaPercent != 0 ? widthDeltaPercent : heightDeltaPercent))% -> \(w.title)"
        )
    }

    // Edge-addressed resize for a floating window: the NAMED edge moves,
    // the opposite edge stays pinned. resizeFloatingWindow only ever moved
    // the bottom/right edges (origin pinned by AX convention), so
    // "shrink this from the top" or "grow it out to the left" were simply
    // impossible. Positive delta always grows outward through that edge,
    // negative shrinks inward from it - the delta is a percentage of the
    // screen's matching axis, like every other resize here.
    func resizeFloatingWindowEdge(_ edge: String, deltaPercent: CGFloat) {
        guard workspace.floatingWindows.indices.contains(workspace.floatingFocusedIndex) else { return }
        let w = workspace.floatingWindows[workspace.floatingFocusedIndex]
        guard let frame = settledFrame(of: w) else { return }
        let screen = usableScreen().frame
        var target = frame
        switch edge {
        case "left":
            let newWidth = max(50, frame.width + screen.width * deltaPercent / 100)
            target.origin.x = frame.maxX - newWidth  // right edge pinned
            target.size.width = newWidth
        case "right":
            target.size.width = max(50, frame.width + screen.width * deltaPercent / 100)
        case "top":
            let newHeight = max(50, frame.height + screen.height * deltaPercent / 100)
            target.origin.y = frame.maxY - newHeight  // bottom edge pinned
            target.size.height = newHeight
        case "bottom":
            target.size.height = max(50, frame.height + screen.height * deltaPercent / 100)
        default:
            print("resize-edge: unknown edge \"\(edge)\" (left/right/top/bottom)")
            return
        }
        animateFrames([(window: w, frame: target)]) { _ in }
        print("resize-edge \(edge) \(deltaPercent > 0 ? "+" : "")\(Int(deltaPercent))% -> \(w.title)")
    }

    // Edge-addressed resize for TILED windows: splitter semantics. The
    // named edge is a boundary shared with the neighbor on that side, and
    // moving it TRANSFERS space across it - my window changes by the delta,
    // the neighbor absorbs the exact opposite, and the opposite edge stays
    // where the user is looking. (A first cut collapsed every edge onto
    // plain width/height, which made "shrink from the top" and "shrink
    // from the bottom" visually identical - not what touching an edge
    // means.) Positive delta always grows the focused window through that
    // edge, negative shrinks it from that edge, matching the floating
    // variant.
    func resizeTiledEdge(_ edge: String, deltaPercent: CGFloat) {
        guard let column = focusedColumn() else { return }
        // The discovered floors are read BEFORE the epoch is bumped, and the
        // bump comes after - same shape as setColumnWidth and
        // switchPresetColumnWidth. This site was left out when item 7 was
        // fixed (it lists three, the commit touched two), so here the floor
        // went back to being nil for everything downstream: the "right"
        // branch handed setColumnWidth a column whose validMinWidth answered
        // nil, and the "left" branch traded in raw proportions - with a
        // column resting on its 800px floor the reflow clamped it back while
        // the neighbour did shrink, and the pair's untouched right edge
        // drifted. Which is precisely the drift the comment below says was
        // caught live by measurement.
        let myFloor = column.validMinWidth
        let neighborFloor =
            workspace.focusedIndex > 0
            ? workspace.columns[workspace.focusedIndex - 1].validMinWidth : nil
        ColumnLayoutEngine.newEpoch()
        switch edge {
        case "right":
            // My right edge IS the strip boundary the plain width action
            // already moves (columns pack left-to-right, so the left edge
            // stays put and later columns shift): no neighbor transfer.
            setColumnWidth(.adjustProportion(deltaPercent), knownFloor: myFloor)

        case "left":
            // Boundary with the left-neighbor column: it absorbs whatever I
            // give up (or yields what I take), so in virtual coordinates my
            // right edge - the sum of both widths plus everything before -
            // does not move. The trade happens in EFFECTIVE PIXELS, not
            // proportions: a column resting on its minimum floor (Discord
            // at 800px with a 710px proportion) has an effective width its
            // proportion doesn't describe, and trading proportions there
            // changed the pair's real total - the untouched right edge
            // visibly drifted (caught live by measurement).
            let idx = workspace.focusedIndex
            guard idx > 0 else {
                print("resize-edge left: no column to the left to trade space with")
                return
            }
            let neighbor = workspace.columns[idx - 1]
            let usableWidth = usableScreen().usableWidth
            guard usableWidth > 0 else { return }
            // The floors captured above, not c.validMinWidth: the epoch was
            // bumped, so asking the column now always answers nil.
            func floor(_ c: Column) -> CGFloat { (c === column ? myFloor : neighborFloor) ?? 0 }
            func effectivePx(_ c: Column) -> CGFloat {
                max(
                    ColumnLayoutEngine.width(forProportion: c.widthProportion, usableWidth: usableWidth),
                    floor(c))
            }
            func clampPx(_ px: CGFloat, for c: Column) -> CGFloat {
                min(usableWidth, max(max(usableWidth * 0.05, floor(c)), px))
            }
            let deltaPx = usableWidth * deltaPercent / 100
            let myOldPx = effectivePx(column)
            let myApplied = clampPx(myOldPx + deltaPx, for: column) - myOldPx
            let neighborOldPx = effectivePx(neighbor)
            let neighborNewPx = clampPx(neighborOldPx - myApplied, for: neighbor)
            let absorbedPx = neighborOldPx - neighborNewPx
            // Only trade what the neighbor can actually absorb/yield, so
            // the pair's total stays constant to the pixel.
            column.widthProportion = ColumnLayoutEngine.proportion(
                forWidth: myOldPx + absorbedPx, usableWidth: usableWidth)
            neighbor.widthProportion = ColumnLayoutEngine.proportion(
                forWidth: neighborNewPx, usableWidth: usableWidth)
            column.presetWidthIndex = nil
            neighbor.presetWidthIndex = nil
            reflow()
            print(
                "resize-edge left \(deltaPercent > 0 ? "+" : "")\(Int(deltaPercent))% -> \(Int(myOldPx + absorbedPx))px (neighbor \(Int(neighborNewPx))px)"
            )

        case "top", "bottom":
            // Boundary with the stack neighbor above/below: both sides
            // become manually-sized at their current heights, then the
            // boundary moves by the delta - clamped so neither side drops
            // under the 20px floor. The screen edges (top of the first
            // window, bottom of the last) are not boundaries - there is no
            // neighbor to trade with and no vertical scrolling to absorb it.
            guard column.windows.indices.contains(column.focusedWindowIndex) else { return }
            let k = column.focusedWindowIndex
            let neighborIndex = edge == "top" ? k - 1 : k + 1
            guard column.windows.indices.contains(neighborIndex) else {
                print("resize-edge \(edge): that edge is the screen, not a window boundary")
                return
            }
            let w = column.windows[k]
            let neighbor = column.windows[neighborIndex]
            guard let wFrame = WindowMover.currentFrame(w.axElement),
                let nFrame = WindowMover.currentFrame(neighbor.axElement)
            else { return }
            let wH = w.manualHeightPx ?? wFrame.height
            let nH = neighbor.manualHeightPx ?? nFrame.height
            let columnHeight = usableScreen().frame.height - 2 * ColumnLayoutEngine.gap
            let d = columnHeight * deltaPercent / 100
            let dClamped = max(min(d, nH - 20), 20 - wH)
            w.manualHeightPx = wH + dClamped
            neighbor.manualHeightPx = nH - dClamped
            column.cachedHeights = nil
            reflow()
            print(
                "resize-edge \(edge) \(deltaPercent > 0 ? "+" : "")\(Int(deltaPercent))% -> \(Int(wH + dClamped))px (neighbor \(Int(nH - dClamped))px)"
            )

        default:
            print("resize-edge: unknown edge \"\(edge)\" (left/right/top/bottom)")
        }
    }

    // One entry point for "resize from this edge" regardless of which group
    // holds focus.
    func resizeEdge(_ edge: String, deltaPercent: CGFloat) {
        if workspace.isFloatingActive {
            resizeFloatingWindowEdge(edge, deltaPercent: deltaPercent)
        } else {
            resizeTiledEdge(edge, deltaPercent: deltaPercent)
        }
    }

    // Swaps the focused column's position with its neighbor (niri's
    // move-column-left/right) - no-op at either edge.
    func moveColumn(delta: Int) {
        guard !workspace.isFloatingActive else {
            print("move-column: el foco esta en la capa flotante (Mod+Shift+V para volver a las tileadas)")
            return
        }
        let newIndex = workspace.focusedIndex + delta
        guard workspace.columns.indices.contains(workspace.focusedIndex) else { return }
        guard workspace.columns.indices.contains(newIndex) else {
            print("move-column: ya esta en el extremo \(delta < 0 ? "izquierdo" : "derecho")")
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
        workspace.insertColumn(newColumn, at: columnIndex + 1)
        workspace.focus(column: columnIndex + 1)
        print(
            "consume-or-expel: stack needs \(Int(total))px but the column has \(Int(available))px - expelled back out"
        )
        reflow()
        focusCurrentColumn()
    }

    // niri converts Auto heights to weights that "preserve their visual
    // heights at the moment of the conversion". Same idea here: freeze what
    // the stack looks like RIGHT NOW into weights, so the window that was
    // deliberately tall stays proportionally tall after a sibling joins or
    // leaves instead of the column re-equalizing behind the user's back.
    func captureHeightWeights(_ column: Column) {
        let autos = column.windows.filter { $0.manualHeightPx == nil }
        guard autos.count > 1 else {
            column.windows.forEach { $0.heightWeight = 1 }
            return
        }
        let heights = autos.map { WindowMover.currentFrame($0.axElement)?.height ?? 0 }
        let total = heights.reduce(0, +)
        guard total > 0 else { return }
        let average = total / CGFloat(autos.count)
        for (w, h) in zip(autos, heights) { w.heightWeight = max(0.05, h / average) }
    }

    func consumeOrExpel(delta: Int) {
        focusedColumn().map(captureHeightWeights)
        guard let source = focusedColumn(), source.windows.indices.contains(source.focusedWindowIndex) else {
            return
        }
        let sourceIndex = workspace.focusedIndex
        let neighborIndex = sourceIndex + delta
        var verifyFits: (() -> Void)?

        if source.windows.count == 1 {
            guard workspace.columns.indices.contains(neighborIndex) else { return }
            guard let window = source.removeWindow(at: 0) else { return }
            let target = workspace.columns[neighborIndex]
            target.add(window)
            target.focus(row: target.windows.count - 1)
            workspace.removeColumn(at: sourceIndex)
            // Removing sourceIndex shifts every later index down by one - if
            // the target was to the right (delta > 0) it lands back at
            // sourceIndex; if it was to the left (delta < 0), unaffected,
            // still at sourceIndex - 1.
            workspace.focus(column: delta < 0 ? sourceIndex - 1 : sourceIndex)
            verifyFits = { self.expelBackIfStackOverflows(target, consumed: window) }
        } else {
            guard let window = source.removeWindow(at: source.focusedWindowIndex) else { return }
            let newColumn = Column()
            newColumn.setWindows([window])
            let insertAt = delta < 0 ? sourceIndex : sourceIndex + 1
            workspace.insertColumn(newColumn, at: insertAt)
            workspace.focus(column: insertAt)
        }
        reflow(onSettled: verifyFits)
        focusCurrentColumn()
        print(
            "consume-or-expel-\(delta < 0 ? "left" : "right") -> \(workspace.columns.count) column(s), focused column \(workspace.focusedIndex) (\(describeFocus()))"
        )
    }

    // niri's expel-window-from-column: unconditionally pulls the LAST window
    // in the stack (not necessarily the focused one) out into a new column
    // right after the current one - a no-op on a column with only one
    // window. Unlike consume-or-expel, focus does not follow the expelled
    // window; it stays on the source column.
    func expelFromColumn() {
        focusedColumn().map(captureHeightWeights)
        guard let column = focusedColumn(), column.windows.count > 1 else { return }
        guard let window = column.removeWindow(at: column.windows.count - 1) else { return }
        let newColumn = Column()
        newColumn.setWindows([window])
        workspace.insertColumn(newColumn, at: workspace.focusedIndex + 1)
        reflow()
        print("expel-window-from-column -> \(workspace.columns.count) column(s)")
    }

    // niri's preset-column-widths takes both `proportion` and `fixed <px>`.
    // The model's currency is proportions, so the pixel presets convert here,
    // where the usable width is known, and both kinds share one cycle.
    func presetProportions() -> [CGFloat] {
        let usableWidth = usableScreen().usableWidth
        // In the DECLARED order: this list is the cycle Mod+R walks.
        return ColumnLayoutEngine.presetColumnSizes.map { size in
            switch size {
            case .proportion(let p): return p
            case .fixed(let px):
                return usableWidth > 0
                    ? ColumnLayoutEngine.proportion(forWidth: px, usableWidth: usableWidth) : 0.5
            }
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
    func switchPresetColumnWidth(delta: Int = 1) {
        guard let column = focusedColumn() else { return }
        let knownFloor = column.validMinWidth
        ColumnLayoutEngine.newEpoch()
        let presets = presetProportions()
        guard !presets.isEmpty else { return }
        guard
            let nextIndex = ColumnLayoutEngine.presetIndex(
                after: column.widthProportion, in: presets,
                delta: delta, from: column.presetWidthIndex)
        else { return }
        column.presetWidthIndex = nextIndex
        let clamped = clampedProportion(presets[nextIndex], for: column, knownFloor: knownFloor)
        column.widthProportion = clamped
        reflow()
        let clampNote =
            abs(clamped - presets[nextIndex]) > 0.001
            ? " (clamped to \(String(format: "%.0f%%", clamped * 100)) by a window's minimum)" : ""
        print(
            "switch-preset-column-width\(delta < 0 ? "-back" : "") -> \(String(format: "%.0f%%", presets[nextIndex] * 100))\(clampNote)"
        )
    }

    // niri's switch-preset-window-width, the width counterpart of
    // switch-preset-window-height. In the tiled strip a window's width IS
    // its column's, so this just cycles the column preset there; a floating
    // window gets its own width cycled through the presets (as fractions of
    // the usable width), the frame animated like every other floating move.
    func switchPresetWindowWidth(delta: Int = 1) {
        guard workspace.isFloatingActive else { switchPresetColumnWidth(delta: delta); return }
        guard workspace.floatingWindows.indices.contains(workspace.floatingFocusedIndex) else { return }
        let w = workspace.floatingWindows[workspace.floatingFocusedIndex]
        guard let frame = settledFrame(of: w) else { return }
        let usableWidth = usableScreen().usableWidth
        let presets = presetProportions().map { $0 * usableWidth }
        guard !presets.isEmpty else { return }
        // Cycle by INDEX, the way niri tracks preset_width_idx - not by
        // "the first preset wider than I am now". With the comparison, a
        // window sized off-preset (dragged by hand, or clamped by its app)
        // jumped to an unpredictable slot and could never walk the list in
        // order; the index makes every press advance exactly one preset.
        let base = w.presetWidthIndex ?? presets.firstIndex { $0 > frame.width + 1 }.map { $0 - 1 } ?? -1
        let nextIndex = ((base + delta) % presets.count + presets.count) % presets.count
        w.presetWidthIndex = nextIndex
        let next = presets[nextIndex]
        var target = frame
        target.size.width = next
        animateFrames([(window: w, frame: target)]) { _ in }
        print("switch-preset-window-width (floating) -> \(Int(next))px")
    }

    // niri's close-window: press the window's own close button through AX -
    // the app runs its normal close path (save prompts and all). A
    // chrome-less window has no button to press; AX offers no other
    // close verb and nigiri never synthesizes keyboard input, so that's an
    // honest refusal, not a silent one.
    func closeWindow() {
        guard let w = focusedManagedWindow() else { return }
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
    func fullscreenWindow() {
        toggleWindowedFullscreen()
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
    func toggleWindowedFullscreen() {
        // Exiting is checked BEFORE the tiled-focus guard: focusedColumn() is
        // nil while the floating layer has focus, which otherwise made the
        // toggle a silent no-op and left the workspace stuck in fullscreen.
        if let current = fullscreenWindowRef {
            fullscreenWindowRef = nil
            if let c = workspace.columns.first(where: { $0.windows.contains { $0 === current } }) {
                c.cachedHeights = nil
                c.cachedMinWidth = nil
            }
            current.lastRequestedFrame = nil
            current.lastActualFrame = nil
            // Floating windows were shoved out of view and are not part of
            // the tiling pass: put them back where they were.
            for w in workspace.floatingWindows {
                guard let home = w.fullscreenHome else { continue }
                w.fullscreenHome = nil
                _ = ColumnLayoutEngine.applyFrame(w, target: home)
            }
            print("windowed-fullscreen: off")
            reflow()
            updateRingImmediate()
            return
        }
        guard let column = focusedColumn(), let window = focusedStackWindow() else { return }
        fullscreenWindowRef = window
        column.cachedHeights = nil
        column.cachedMinWidth = nil
        // Immediately, not at settle: the per-tick decoration update is
        // skipped while fullscreen, so the borders would otherwise sit frozen
        // in place for the whole animation and only vanish at the end.
        ring.hide()
        borders.hideAll()
        tabIndicators.hideAll()
        print("windowed-fullscreen: \(window.title)")
        reflow()
    }

    // niri's maximize-window-to-edges: fake fullscreen - the focused column
    // covers the raw screen frame, gaps and all, without macOS's real
    // fullscreen Space. Toggles off on repeat; plain maximize-column
    // resets the edges variant.
    // niri's maximize-window-to-edges acts on the focused WINDOW, not on
    // its whole column - with a stack of three, the other two stay where
    // they are. nigiri used to set a workspace-wide flag that blew up the
    // entire column to the screen edges.
    func maximizeWindowToEdges() {
        toggleWindowedFullscreen()
    }

    // niri's consume-window-into-column (Mod+Comma): swallow the FIRST
    // window of the column to the right into the focused column's stack.
    // Focus stays where it is - unlike consume-or-expel, nothing moves out.
    func consumeWindowIntoColumn() {
        focusedColumn().map(captureHeightWeights)
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
        print("move-workspace-\(delta < 0 ? "up" : "down") -> now workspace \(target + 1)")
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
                "[layout] \(Int(proportion * 100))% pedido, pero la app no baja de \(Int(minWidth))px - se vuelve a medir"
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
        let usableWidth = usableScreen().usableWidth
        // Both directions through LayoutEngine's pair, which is what its own
        // comment promises ("Every conversion goes through these") and what
        // this function was the last holdout from.
        func proportion(forPixels px: CGFloat) -> CGFloat {
            ColumnLayoutEngine.proportion(forWidth: px, usableWidth: usableWidth)
        }
        let currentPixels = ColumnLayoutEngine.width(
            forProportion: column.widthProportion, usableWidth: usableWidth)
        let target: CGFloat
        switch change {
        case .setProportion(let p): target = p / 100
        case .adjustProportion(let d): target = column.widthProportion + d / 100
        case .setFixed(let px): target = proportion(forPixels: px)
        case .adjustFixed(let px): target = proportion(forPixels: currentPixels + px)
        }
        column.widthProportion = clampedProportion(target, for: column, knownFloor: knownFloor)
        column.presetWidthIndex = nil
        reflow()
        print("set-column-width \(change) -> \(String(format: "%.0f%%", column.widthProportion * 100))")
    }

    // niri's set-window-height "±10%": adjusts the focused window's manual
    // height by 10 percentage points of the column's total usable height,
    // seeding it from the window's current actual height the first time
    // (niri's WindowHeight::Auto -> Fixed conversion happens the same way -
    // "weighted to preserve their visual heights at the moment of the
    // conversion").
    func setWindowHeight(_ change: SizeChange) {
        guard let column = focusedColumn(), let window = focusedStackWindow() else { return }
        let columnHeight = usableScreen().frame.height - 2 * ColumnLayoutEngine.gap
        let current =
            window.manualHeightPx ?? (WindowMover.currentFrame(window.axElement)?.height ?? columnHeight)
        let requested: CGFloat
        switch change {
        case .setProportion(let p): requested = columnHeight * p / 100
        case .adjustProportion(let d): requested = current + columnHeight * d / 100
        case .setFixed(let px): requested = px
        case .adjustFixed(let px): requested = current + px
        }
        // Ceiling: the column's height minus each sibling's gap and the same
        // 20px floor the manual height itself gets - vertical space is
        // genuinely fixed (no scrolling), so growth past what the stack can
        // hold was the vertical mirror of the column-width debt: invisible
        // overshoot that shrink presses had to pay back.
        let siblingCount = CGFloat(column.windows.count - 1)
        let ceiling = max(20, columnHeight - siblingCount * (ColumnLayoutEngine.gap + 20))
        window.manualHeightPx = min(ceiling, max(20, requested))
        column.cachedHeights = nil
        reflow()
        print("set-window-height \(change) -> \(describeFocus())")
    }

    // niri's reset-window-height: back to Auto, splitting whatever's left
    // among the column's other Auto windows again.
    func resetWindowHeight() {
        guard let column = focusedColumn(), let window = focusedStackWindow() else { return }
        window.manualHeightPx = nil
        // Back to an equal Auto share: a weight frozen by an earlier
        // consume/expel would otherwise keep the window disproportionate.
        window.heightWeight = 1
        column.cachedHeights = nil
        reflow()
        print("reset-window-height -> \(describeFocus())")
    }

    // niri's expand-column-to-available-width: grows the focused column to
    // absorb whatever room is left in the CURRENT view that isn't occupied
    // by other columns already fully visible there - if it's the only one
    // visible, it just takes the full width instead.
    func expandColumnToAvailableWidth() {
        ColumnLayoutEngine.newEpoch()
        guard focusedColumn() != nil else { return }
        let usableWidth = usableScreen().usableWidth
        let placements = ColumnLayoutEngine.columnPlacements(
            columns: workspace.columns, usableWidth: usableWidth, maximizedIndex: workspace.maximizedIndex)
        let activeIndex = workspace.focusedIndex

        var otherVisibleWidth: CGFloat = 0
        var anyOtherVisible = false
        for (idx, p) in placements.enumerated() where idx != activeIndex {
            let visible =
                p.x >= workspace.viewOffset - 0.5
                && (p.x + p.width) <= workspace.viewOffset + usableWidth + 0.5
            if visible {
                otherVisibleWidth += p.width + ColumnLayoutEngine.gap
                anyOtherVisible = true
            }
        }
        guard anyOtherVisible else {
            workspace.columns[activeIndex].widthProportion = 1.0
            workspace.columns[activeIndex].presetWidthIndex = nil
            reflow()
            print("expand-column-to-available-width -> 100% (only column in view)")
            return
        }
        // What is left once the other fully-visible columns have taken
        // theirs - that IS the active column's new width. Adding its current
        // width on top double-counted it and overflowed the strip, pushing
        // the very columns this measured out of view.
        let newWidth = usableWidth - otherVisibleWidth
        guard newWidth > 0 else { return }
        workspace.columns[activeIndex].widthProportion =
            ColumnLayoutEngine.proportion(forWidth: newWidth, usableWidth: usableWidth)
        workspace.columns[activeIndex].presetWidthIndex = nil
        reflow()
        print(
            "expand-column-to-available-width -> \(String(format: "%.0f%%", workspace.columns[activeIndex].widthProportion * 100))"
        )
    }

    // niri's center-column: an explicit, on-demand recentering of the
    // focused column - distinct from center-focused-column "never" (the
    // passive auto-follow policy every other action already respects).
    func centerColumn() {
        guard focusedColumn() != nil else { return }
        let usableWidth = usableScreen().usableWidth
        let placements = ColumnLayoutEngine.columnPlacements(
            columns: workspace.columns, usableWidth: usableWidth, maximizedIndex: workspace.maximizedIndex)
        let p = placements[workspace.focusedIndex]
        reflow(explicitViewOffset: p.x + p.width / 2 - usableWidth / 2)
        print("center-column")
    }

    // niri's center-visible-columns: keeps the same set of columns visible,
    // but recenters that whole group as a block within the view instead of
    // sitting flush against whichever edge they happened to scroll to.
    func centerVisibleColumns() {
        guard !workspace.isFloatingActive, !workspace.columns.isEmpty else { return }
        let usableWidth = usableScreen().usableWidth
        let placements = ColumnLayoutEngine.columnPlacements(
            columns: workspace.columns, usableWidth: usableWidth, maximizedIndex: workspace.maximizedIndex)
        let visible = placements.filter {
            $0.x >= workspace.viewOffset - 0.5
                && ($0.x + $0.width) <= workspace.viewOffset + usableWidth + 0.5
        }
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
    func toggleWindowFloating() {
        if workspace.isFloatingActive {
            guard workspace.floatingWindows.indices.contains(workspace.floatingFocusedIndex) else {
                print("toggle-window-floating: no hay ventana flotante enfocada")
                return
            }
            // Dialogs live in the floating layer permanently - tiling one
            // means the layout fighting a window that refuses to resize.
            guard !workspace.floatingWindows[workspace.floatingFocusedIndex].isDialog else {
                print("toggle-window-floating: dialogs stay floating")
                return
            }
            let window = workspace.floatingWindows.remove(at: workspace.floatingFocusedIndex)
            workspace.focus(floating: workspace.floatingFocusedIndex)
            let newColumn = Column()
            newColumn.setWindows([window])
            let insertAt =
                workspace.columns.isEmpty ? 0 : min(workspace.focusedIndex + 1, workspace.columns.count)
            workspace.insertColumn(newColumn, at: insertAt)
            workspace.focus(column: insertAt)
            // Unconditionally: the window that just got tiled is the one the
            // user is acting on, so focus has to follow it into the columns.
            // Clearing this only when the floating layer emptied left focus
            // reading through isFloatingActive at some OTHER floating window,
            // so the freshly-tiled one got neither focus nor the ring.
            workspace.isFloatingActive = false
            reflow()
            focusCurrentColumn()
            print("toggle-window-floating -> tiled, column \(workspace.focusedIndex)")
        } else {
            guard workspace.columns.indices.contains(workspace.focusedIndex) else { return }
            let column = workspace.columns[workspace.focusedIndex]
            guard column.windows.indices.contains(column.focusedWindowIndex) else { return }
            let window = column.windows[column.focusedWindowIndex]
            // One operation, with the fullscreen invariant inside it.
            workspace.detachFromTiling(window)
            // Default floating position: current tiled frame + (50,50),
            // clamped to stay on screen - matches niri's own default offset
            // (center-focused-column "never" always uses +50,+50, never the
            // (0,0) alternative reserved for "always" mode).
            if let currentFrame = WindowMover.currentFrame(window.axElement) {
                let screenFrame = ScreenGeometry.primaryScreenVisibleFrameInAXSpace()
                var newOrigin = CGPoint(x: currentFrame.origin.x + 50, y: currentFrame.origin.y + 50)
                newOrigin.x = min(newOrigin.x, screenFrame.maxX - currentFrame.width)
                newOrigin.y = min(newOrigin.y, screenFrame.maxY - currentFrame.height)
                try? WindowMover.setFrame(
                    window.axElement, to: CGRect(origin: newOrigin, size: currentFrame.size))
            }
            workspace.floatingWindows.append(window)
            workspace.focus(floating: workspace.floatingWindows.count - 1)
            workspace.isFloatingActive = true
            reflow()
            focusCurrentColumn()
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

import AppKit
import ApplicationServices

// Placement math over the model (niri's scrolling/floating layout logic):
// column widths, scroll offset, per-window target frames. No AX writes
// except applyFrame's probe; pure geometry otherwise.
enum ColumnLayoutEngine {
    // Mutable statics, not lets: these are the config file's knobs
    // (layout { gap / preset-column-widths / default-column-width }),
    // rewritten by applyConfig on every live reload.
    static var gap: CGFloat = 10
    // Layout epoch. Both caches below are ANSWERS FROM AN APP - "this window
    // refuses to be narrower than X", "it answered Y when asked for Z" - and
    // an app's constraints are not permanent: a call starting in a chat app,
    // a video leaving fullscreen, a display change. Cached forever, a stale
    // floor left the column stuck at a width no key could change, silently.
    //
    // Bumped on the events that can plausibly change an app's mind (config
    // reload, screen change, an explicit sizing action, a window opening or
    // closing), NOT on a timer: a periodic expiry would re-issue a write the
    // app is going to refuse again, which is the "windows dancing against
    // their clamp" bug this memo exists to prevent.
    static var epoch = 0
    static func newEpoch() { epoch &+= 1 }
    // niri's real preset-column-widths (layout.kdl): 1/3, 1/2, 2/3 of the
    // output, "taking gaps into account".
    static var presetColumnSizes: [NigiriConfig.PresetSize] = [
        .proportion(1.0 / 3.0), .proportion(0.5), .proportion(2.0 / 3.0),
    ]
    // niri's `preset-column-widths { fixed <px> }`, kept in pixels until the
    // usable width is known.
    // niri's preset-window-heights - a SEPARATE list, not the widths reused.
    static var presetWindowHeightSizes: [NigiriConfig.PresetSize] = [
        .proportion(1.0 / 3.0), .proportion(0.5), .proportion(2.0 / 3.0),
    ]
    // What a brand-new column asks for (niri's default-column-width).
    static var defaultColumnWidth: CGFloat = 0.5

    struct Placement {
        let x: CGFloat  // virtual, not yet adjusted for viewOffset
        let width: CGFloat
    }

    // Every column's width is a plain function of its own widthProportion
    // (or the full usable width, if it's the maximized column) - no
    // negotiation with siblings, since a column that doesn't fit on screen
    // just extends the scrollable strip instead of forcing the others to
    // shrink. See the formula below: it is niri's, and it is deliberately
    // independent of how many columns exist.
    static func columnPlacements(columns: [Column], usableWidth: CGFloat, maximizedIndex: Int?) -> [Placement]
    {
        var x: CGFloat = 0
        var result: [Placement] = []
        for (idx, column) in columns.enumerated() {
            // niri's resolve_column_width (scrolling.rs), read verbatim:
            //   ColumnWidth::Proportion(p) => (working_w - gaps) * p - gaps
            // Note what it does NOT contain: the column COUNT. A column's
            // width is a property of the column alone, so opening or closing
            // an unrelated column never resizes it. The previous formula
            // divided the leftover space among the current columns, which
            // happened to agree with niri at exactly two columns and drifted
            // everywhere else - windows visibly resizing when a sibling
            // appeared. `usableWidth` here is already working_w - 2*gap, so
            // (working_w - gap) becomes (usableWidth + gap).
            //
            // The shape is what makes proportions tile exactly: three 1/3
            // columns come to (working_w - gap) - 3*gap plus the two gaps
            // between them = working_w - 2*gap, the full working area.
            let requested =
                idx == maximizedIndex
                ? usableWidth
                : (usableWidth + gap) * column.widthProportion - gap
            // niri's update_tile_sizes_with_transaction (scrolling.rs):
            //   min_width = max over tiles' min sizes,
            //   max_width = min over tiles' non-zero max sizes,
            //   max_width = f64::max(max_width, min_width)  // floor wins
            //   width = f64::max(f64::min(width, max_width), min_width)
            // A fixed-size tile (AX: size not settable, min == max == its
            // actual size) therefore resolves its column to EXACTLY its own
            // width, whatever proportion was requested. The discovered
            // cachedMinWidth folds into the same floor: a column whose
            // windows refuse to shrink just takes that width - the strip is
            // infinite horizontally, so it extends the scroll range rather
            // than fighting the app.
            let fixedWidths = column.windows.compactMap { $0.fixedSize?.width }
            let minWidth = max(column.validMinWidth ?? 0, fixedWidths.max() ?? 0)
            let maxWidth = max(fixedWidths.min() ?? .greatestFiniteMagnitude, minWidth)
            let width = max(min(requested, maxWidth), minWidth)
            result.append(Placement(x: x, width: width))
            x += width + gap
        }
        return result
    }

    // The two directions of the width formula above. Every conversion goes
    // through these: four other sites used to invert with a DIFFERENT,
    // column-count-dependent formula, so a column's clamped floor and the
    // result of expand/resize-edge/mod-drag changed whenever an unrelated
    // column opened or closed.
    static func width(forProportion p: CGFloat, usableWidth: CGFloat) -> CGFloat {
        (usableWidth + gap) * p - gap
    }
    static func proportion(forWidth px: CGFloat, usableWidth: CGFloat) -> CGFloat {
        (px + gap) / (usableWidth + gap)
    }

    // niri's Column::toggle_width (scrolling.rs): the stored preset index is
    // a fast path, and when there is none it picks by COMPARING the current
    // width - forward, the first preset strictly bigger; backward, the last
    // one strictly smaller; wrapping to the ends. nil is not an edge case
    // here, it is the default (a fresh column has none) and every explicit
    // width action clears it, so cycling by index alone meant the FIRST
    // Mod+R on any newly opened window went to preset 0 - 1/3 here where
    // niri gives 2/3. The floating branch of the same action already did
    // this, so one key behaved differently depending on the layer.
    static func presetIndex(
        after current: CGFloat, in presets: [CGFloat], delta: Int,
        from stored: Int?
    ) -> Int? {
        guard !presets.isEmpty else { return nil }
        if let stored {
            return ((stored + delta) % presets.count + presets.count) % presets.count
        }
        if delta > 0 {
            return presets.firstIndex { current + 0.001 < $0 } ?? 0
        }
        return presets.lastIndex { $0 + 0.001 < current } ?? (presets.count - 1)
    }

    // The vertical twin. niri's resolve_preset_size (scrolling.rs) is
    // `(working - gaps) * p - gaps` for BOTH axes; the heights used a plain
    // `p * usableHeight`, so three windows at the 1/3 preset summed to the
    // full height PLUS two gaps against a column that only has
    // `usableHeight - 2*gap` to give - the last window ended up (n-1)*gap
    // below the usable area (66px with the user's `gaps 33`).
    static func height(forProportion p: CGFloat, usableHeight: CGFloat) -> CGFloat {
        (usableHeight + gap) * p - gap
    }

    // niri's layout { center-focused-column } policy, plus
    // always-center-single-column (scrolling.rs,
    // is_centering_focused_column). Static because the offset math is a pure
    // function called from several places that have no config in hand.
    enum CenterPolicy { case never, always, onOverflow }
    static var centerPolicy: CenterPolicy = .never
    static var alwaysCenterSingleColumn = false

    // niri's compute_new_view_offset (scrolling.rs), in this engine's
    // coordinates.
    //
    // niri pads the target by `gaps` on each side and measures against the
    // FULL working area. Here `usableWidth` is the working area with both
    // gaps already subtracted, and placements are gap-relative (the renderer
    // adds `screenFrame.minX + gap`), so that padding is already baked into
    // the coordinate system: applying it again would shift the view by one
    // gap on every focus change. niri's clamp confirms the equivalence -
    // `clamp((view - col) / 2, 0, gaps)` only shrinks below `gaps` for a
    // column wider than `view - 2 * gaps`, which in these coordinates cannot
    // exist (that IS usableWidth).
    //
    // What was genuinely missing: a column WIDER than the view. niri
    // left-aligns those unconditionally; this aligned whichever edge had
    // been clipped, so such a column could be shown right-aligned with its
    // left half unreachable.
    static func fitOffset(x: CGFloat, width: CGFloat, currentOffset: CGFloat, usableWidth: CGFloat) -> CGFloat
    {
        if usableWidth <= width { return x }
        // Already fully visible: niri leaves the view exactly where it is.
        if currentOffset <= x && x + width <= currentOffset + usableWidth { return currentOffset }
        // Otherwise the alignment that costs less motion from here - which
        // for a column clipped on one side is that side, and for one fully
        // off-view is the near edge.
        let distanceToLeft = abs(currentOffset - x)
        let distanceToRight = abs((currentOffset + usableWidth) - (x + width))
        return distanceToLeft <= distanceToRight ? x : x + width - usableWidth
    }

    static func scrollOffset(
        toShow index: Int, placements: [Placement], currentOffset: CGFloat, usableWidth: CGFloat,
        previousIndex: Int? = nil
    ) -> CGFloat {
        guard placements.indices.contains(index) else { return currentOffset }
        let p = placements[index]
        // A column wider than the view can't be centred; niri hands those
        // back to the fit path rather than centring them off-screen.
        let centered =
            usableWidth <= p.width
            ? fitOffset(x: p.x, width: p.width, currentOffset: currentOffset, usableWidth: usableWidth)
            : p.x - (usableWidth - p.width) / 2
        if alwaysCenterSingleColumn, placements.count <= 1 { return centered }
        switch centerPolicy {
        case .always:
            return centered
        case .onOverflow:
            // niri compares the target against the NEIGHBOUR on the side
            // focus came from, not against the previous column itself: what
            // matters is whether the view can still hold the pair it is
            // about to scroll across.
            guard let previousIndex, previousIndex != index, placements.indices.contains(previousIndex) else {
                break
            }
            let sourceIndex =
                previousIndex > index
                ? min(index + 1, placements.count - 1)
                : max(0, index - 1)
            let source = placements[sourceIndex]
            // niri adds `gaps * 2` here because it measures against the
            // full working area; usableWidth already has both subtracted,
            // so the term is the same one, not an extra.
            let totalWidth =
                source.x < p.x
                ? p.x - source.x + p.width
                : source.x - p.x + source.width
            if totalWidth > usableWidth { return centered }
        case .never:
            break
        }
        return fitOffset(x: p.x, width: p.width, currentOffset: currentOffset, usableWidth: usableWidth)
    }

    // `screenFrame` must already be in AX/CG space (top-left origin, Y down) -
    // pass ScreenGeometry.primaryScreenVisibleFrameInAXSpace().
    // Returns whether any pass DISCOVERED a new minimum width: placements
    // shifted mid-call, so the caller's pre-computed scroll offset (and the
    // ring it derived from targets) may no longer show the focused column -
    // the caller should re-run its scroll-into-view pass. Bounded for the
    // caller the same way the loop below is bounded: the discovery is
    // cached, so a re-run can't re-discover it.
    // macOS x clamp. Measured (with nigiri stopped, or its own relayout
    // overwrites the probe and every request reads back as clamped):
    //
    //     ask -719 -> get -719   1px visible    granted
    //     ask -720 -> get -680   40px           clamped
    //     ask 1469 -> get 1469   1px visible    granted
    //     ask 1500 -> get 1430   40px           clamped
    //
    // Any x leaving >= 1px on screen is granted exactly. A fully-off-screen
    // request is not clamped to the edge - the window is pulled 40px back
    // in, where it overlaps the visible columns. Hence: never request a
    // fully-off-screen x; request the last granted one.
    //
    // Do NOT hide off-screen columns by parking them at the 1px corner
    // (parkedOffScreen): that is for whole-workspace hiding, costs a diagonal
    // teleport, and is unnecessary given the above.
    static func grantedX(_ x: CGFloat, width: CGFloat, screenFrame: CGRect) -> CGFloat {
        min(max(x, screenFrame.minX - width + 1), screenFrame.maxX - 1)
    }

    // Where each column sits on screen, and which of its windows is the one
    // to show. The ONE placement computation: layout() (which writes to AX
    // and probes) and targetFrames() (pure, for the animator) used to derive
    // this separately and mirror every rule by hand - the horizontal half
    // already drifted once, when grantedX landed in one of them and not the
    // other. The height POLICY still differs between them (probe-and-cache
    // vs cached-or-naive); that difference is real, this one was not.
    struct ColumnGeometry {
        let column: Column
        let x: CGFloat
        let width: CGFloat
        let y: CGFloat
        let height: CGFloat
        // Tabbed columns show one window and park the rest off-screen; nil
        // means the whole stack is on screen.
        let visibleOnly: ManagedWindow?
        let parked: [ManagedWindow]
    }

    static func columnGeometry(
        columns: [Column], in screenFrame: CGRect,
        maximizedIndex: Int?, viewOffset: CGFloat
    ) -> [ColumnGeometry] {
        let usableWidth = screenFrame.width - 2 * gap
        let placements = columnPlacements(
            columns: columns, usableWidth: usableWidth, maximizedIndex: maximizedIndex)
        return zip(columns, placements).compactMap { column, placement in
            guard !column.windows.isEmpty else { return nil }
            let x = grantedX(
                screenFrame.minX + gap + (placement.x - viewOffset),
                width: placement.width, screenFrame: screenFrame)
            var visibleOnly: ManagedWindow? = nil
            var parked: [ManagedWindow] = []
            if column.isTabbed {
                let activeIndex =
                    column.windows.indices.contains(column.focusedWindowIndex) ? column.focusedWindowIndex : 0
                visibleOnly = column.windows[activeIndex]
                parked = column.windows.enumerated().filter { $0.offset != activeIndex }.map(\.element)
            }
            return ColumnGeometry(
                column: column, x: x, width: placement.width,
                y: screenFrame.minY + gap, height: screenFrame.height - 2 * gap,
                visibleOnly: visibleOnly, parked: parked)
        }
    }

    // The overview's geometry: the VIRTUAL strip, without the on-screen
    // clamp and without the camera.
    //
    // REGRESSION: the overview used targetFrames(viewOffset: 0) and then
    // dropped anything sitting at the right edge, to hide the windows a
    // tabbed column parks there. But grantedX clamps ANY column whose
    // virtual x falls past the right edge to that same coordinate, so the
    // third column of a three-column workspace was clamped into the parking
    // spot and then filtered out - it simply was not in the overview. The
    // zoomed-out camera has no screen edge to clamp against, so it must not
    // go through the layout's clamp at all; parked tabs are excluded here by
    // identity instead of by position.
    static func overviewFrames(
        columns: [Column], in screenFrame: CGRect, maximizedIndex: Int?,
        viewOffset: CGFloat = 0
    ) -> [(window: ManagedWindow, frame: CGRect)] {
        guard !columns.isEmpty else { return [] }
        let usableWidth = screenFrame.width - 2 * gap
        let placements = columnPlacements(
            columns: columns, usableWidth: usableWidth, maximizedIndex: maximizedIndex)
        var result: [(ManagedWindow, CGRect)] = []
        for (column, placement) in zip(columns, placements) {
            guard !column.windows.isEmpty else { continue }
            // At the workspace's OWN scroll position, and deliberately
            // unclamped: niri's overview shows each workspace exactly as it
            // looks, so a column scrolled out of view stays out of view - it
            // just lands outside the workspace rectangle instead of vanishing.
            let x = screenFrame.minX + gap + placement.x - viewOffset
            let y = screenFrame.minY + gap
            let height = screenFrame.height - 2 * gap
            if column.isTabbed {
                // One card for the whole column, like niri's overview.
                let activeIndex =
                    column.windows.indices.contains(column.focusedWindowIndex) ? column.focusedWindowIndex : 0
                result.append(
                    (column.windows[activeIndex], CGRect(x: x, y: y, width: placement.width, height: height)))
                continue
            }
            let n = column.windows.count
            let heights =
                column.cachedHeights?.count == n
                ? column.cachedHeights!
                : naiveHeights(for: column.windows, usableHeight: height - CGFloat(n - 1) * gap)
            var top = y
            for (window, h) in zip(column.windows, heights) {
                result.append((window, CGRect(x: x, y: top, width: placement.width, height: h)))
                top += h + gap
            }
        }
        return result
    }

    // The width clamp, pure: a rule's max-width is the ceiling, the window's
    // discovered/ruled minimum the floor, and if the two ever cross the floor
    // wins (a window nobody can read is worse than one too wide). Extracted
    // from the engine so it can be tested - and because its caller has to be
    // able to pass a floor it captured BEFORE bumping the epoch.
    static func clampProportion(
        _ proportion: CGFloat, minWidth: CGFloat?, maxWidth: CGFloat?,
        usableWidth: CGFloat
    ) -> CGFloat {
        var p = min(1.0, max(0.05, proportion))
        guard usableWidth > 0 else { return p }
        if let maxWidth {
            p = min(p, ColumnLayoutEngine.proportion(forWidth: maxWidth, usableWidth: usableWidth))
        }
        if let minWidth {
            p = max(p, ColumnLayoutEngine.proportion(forWidth: minWidth, usableWidth: usableWidth))
        }
        return p
    }

    // niri's interactive move (scrolling.rs, insert_position): where a
    // dragged window lands. Verbatim rule - the closest GAP wins, and the
    // comparison is between the horizontal distance to the nearest column
    // gap and the vertical distance to the nearest tile gap inside the
    // column under the cursor. A tie goes to a new column.
    enum InsertPosition: Equatable {
        case newColumn(Int)  // insert a fresh column at this index
        case inColumn(Int, Int)  // into this column's stack, at this row
    }

    // `frames` is what targetFrames produced for the CURRENT layout (the
    // dragged window excluded by the caller): the geometry is already known,
    // so this stays pure and testable.
    // `tabbed`: for each column, the index of the ACTIVE tab, or nil when the
    // column is not tabbed. A tabbed column shows one tile, so its frame list
    // has one entry and the tile-gap contest could only ever answer row 0 or
    // 1 - the new tab landed at the top of the stack no matter where the user
    // pointed, and the tab order is visible in the indicator. niri measures
    // the ACTIVE tile and returns its index or index+1 (scrolling.rs).
    static func insertPosition(
        columnFrames: [[CGRect]], point: CGPoint, screenFrame: CGRect,
        tabbed: [Int?] = []
    ) -> InsertPosition {
        guard !columnFrames.isEmpty else { return .newColumn(0) }
        // The gaps between columns, aimed at the middle of each gap: one
        // before every column, plus one past the last.
        var columnGaps: [(index: Int, x: CGFloat)] = []
        for (i, frames) in columnFrames.enumerated() {
            guard let first = frames.first else { continue }
            columnGaps.append((i, first.minX - gap / 2))
        }
        if let last = columnFrames.last?.first {
            columnGaps.append((columnFrames.count, last.maxX + gap / 2))
        }
        let closestColumnGap =
            columnGaps.min { abs($0.x - point.x) < abs($1.x - point.x) }
            ?? (index: 0, x: point.x)
        let horizontalDistance = abs(closestColumnGap.x - point.x)

        // The column the cursor is actually over: only its tile gaps count.
        let hovered = columnFrames.firstIndex { frames in
            guard let f = frames.first else { return false }
            return point.x >= f.minX && point.x <= f.maxX
        }
        guard let hovered else { return .newColumn(closestColumnGap.index) }
        let frames = columnFrames[hovered]
        guard !frames.isEmpty else { return .newColumn(closestColumnGap.index) }
        var tileGaps: [(index: Int, y: CGFloat)] = []
        for (i, f) in frames.enumerated() { tileGaps.append((i, f.minY - gap / 2)) }
        if let last = frames.last { tileGaps.append((frames.count, last.maxY + gap / 2)) }
        let closestTileGap =
            tileGaps.min { abs($0.y - point.y) < abs($1.y - point.y) }
            ?? (index: 0, y: point.y)
        let verticalDistance = abs(closestTileGap.y - point.y)

        if horizontalDistance <= verticalDistance {
            return .newColumn(closestColumnGap.index)
        }
        // In a tabbed column the single visible tile IS the active tab, so
        // "above or below it" means "before or after the active tab".
        if tabbed.indices.contains(hovered), let activeTab = tabbed[hovered], let visible = frames.first {
            return .inColumn(hovered, point.y < visible.midY ? activeTab : activeTab + 1)
        }
        return .inColumn(hovered, closestTileGap.index)
    }

    @discardableResult
    // `skipping` is the windowed-fullscreen window: laying it out at its
    // column size would flicker it on every settle, and the min-width
    // discovery would memorize its full-screen width as the column minimum.
    static func layout(
        columns: [Column], in screenFrame: CGRect, maximizedIndex: Int? = nil, viewOffset: CGFloat = 0,
        skipping: ManagedWindow? = nil
    ) -> Bool {
        guard !columns.isEmpty else { return false }
        let usableWidth = screenFrame.width - 2 * gap
        // A pass can DISCOVER a column's real minimum width (see
        // cachedMinWidth) partway through, which shifts every later column's
        // position - re-run with the corrected placements until nothing new
        // is discovered. Bounded: each extra pass requires a fresh discovery,
        // and a discovered minimum makes the next pass's request match what
        // the app already accepted, so this can't ping-pong.
        var discoveredAny = false
        for _ in 0..<3 {
            var discovered = false
            for geometry in columnGeometry(
                columns: columns, in: screenFrame,
                maximizedIndex: maximizedIndex, viewOffset: viewOffset)
            {
                var actualWidth = geometry.width
                if let visible = geometry.visibleOnly {
                    actualWidth = max(
                        actualWidth,
                        applyFrame(
                            visible,
                            target: CGRect(
                                x: geometry.x, y: geometry.y, width: geometry.width, height: geometry.height)
                        ).width)
                    for w in geometry.parked {
                        guard let current = WindowMover.currentFrame(w.axElement) else { continue }
                        _ = applyFrame(
                            w,
                            target: CGRect(
                                x: screenFrame.maxX - 1, y: current.origin.y,
                                width: current.width, height: current.height))
                    }
                } else {
                    actualWidth = layoutColumn(
                        geometry.column, x: geometry.x, y: geometry.y,
                        width: geometry.width, height: geometry.height, skipping: skipping)
                }
                // A discovered minimum states what the app refuses to shrink
                // past, so it cannot exceed the working area; a larger value
                // only comes from measuring a window mid-animation.
                if actualWidth > geometry.width + 1.0, actualWidth <= usableWidth,
                    abs((geometry.column.validMinWidth ?? 0) - actualWidth) > 1.0
                {
                    geometry.column.cachedMinWidth = actualWidth
                    discovered = true
                }
            }
            if !discovered { return discoveredAny }
            discoveredAny = true
        }
        return discoveredAny
    }

    // Pure companion to layout() - computes the same desired frame for every
    // window WITHOUT writing anything to AX, so a caller can animate each
    // window smoothly toward it instead of snapping directly there. Uses
    // cached per-column heights when available; falls back to a naive equal
    // share for a column whose stack shape hasn't been probed yet (a brand
    // new column, or one that just changed) - close enough to animate
    // toward, and the real layout() call a caller makes once the animation
    // settles probes/corrects/caches the true value for next time.
    // `includingParked: false` leaves out the windows a tabbed column hides -
    // and with them the only AX reads in this otherwise pure function. Two
    // round-trips per parked window, and the drop preview calls this on every
    // leftMouseDragged (~120/s, inside the event tap's own callback).
    static func targetFrames(
        columns: [Column], in screenFrame: CGRect, maximizedIndex: Int? = nil,
        viewOffset: CGFloat = 0, includingParked: Bool = true
    ) -> [(window: ManagedWindow, frame: CGRect)] {
        guard !columns.isEmpty else { return [] }
        var result: [(ManagedWindow, CGRect)] = []
        for geometry in columnGeometry(
            columns: columns, in: screenFrame,
            maximizedIndex: maximizedIndex, viewOffset: viewOffset)
        {
            if let visible = geometry.visibleOnly {
                result.append(
                    (
                        visible,
                        CGRect(
                            x: geometry.x, y: geometry.y,
                            width: geometry.width, height: geometry.height)
                    ))
                for w in geometry.parked where includingParked {
                    let current = WindowMover.currentFrame(w.axElement)
                    result.append(
                        (
                            w,
                            CGRect(
                                x: screenFrame.maxX - 1,
                                y: current?.origin.y ?? geometry.y,
                                width: current?.width ?? geometry.width,
                                height: current?.height ?? geometry.height)
                        ))
                }
                continue
            }
            let n = geometry.column.windows.count
            let heights: [CGFloat]
            if let cached = geometry.column.cachedHeights, cached.count == n {
                heights = cached
            } else {
                heights = naiveHeights(
                    for: geometry.column.windows,
                    usableHeight: geometry.height - CGFloat(n - 1) * gap)
            }
            var y = geometry.y
            for (w, h) in zip(geometry.column.windows, heights) {
                result.append((w, CGRect(x: geometry.x, y: y, width: geometry.width, height: h)))
                y += h + gap
            }
        }
        return result
    }

    @discardableResult
    private static func layoutColumn(
        _ column: Column, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
        skipping: ManagedWindow? = nil
    ) -> CGFloat {
        guard !column.windows.isEmpty else { return width }
        let n = column.windows.count

        let targetHeights: [CGFloat]
        if let cached = column.cachedHeights, cached.count == n {
            targetHeights = cached
        } else if let skipping, column.windows.contains(where: { $0 === skipping }) {
            // probeTargetHeights writes to every window it measures, which
            // would resize the fullscreen window to its column size for a
            // frame. No probe and no cache while fullscreen; cachedHeights is
            // cleared on exit, so the real probe happens then.
            targetHeights = naiveHeights(for: column.windows, usableHeight: height - gap * CGFloat(n - 1))
        } else {
            targetHeights = probeTargetHeights(column: column, x: x, y: y, width: width, height: height)
            column.cachedHeights = targetHeights
        }

        var currentY = y
        var actualWidth = width
        for (w, targetHeight) in zip(column.windows, targetHeights) {
            let frame = CGRect(x: x, y: currentY, width: width, height: targetHeight)
            // The fullscreen window keeps its own frame AND is excluded from
            // the width discovery: its size says nothing about what this
            // column can shrink to.
            if w !== skipping {
                actualWidth = max(actualWidth, applyFrame(w, target: frame).width)
            }
            currentY += targetHeight + gap
        }
        return actualWidth
    }

    // Every window but one manually-sized (niri's WindowHeight::Fixed) keeps
    // exactly that height; the rest (Auto, matching niri's WindowHeight::Auto)
    // split whatever's left equally - the fallback used before a column's
    // real stack shape has been probed (see probeTargetHeights below for the
    // authoritative, stuck-aware version).
    static func naiveHeights(for windows: [ManagedWindow], usableHeight: CGFloat) -> [CGFloat] {
        // effectiveFixedHeightPx, not manualHeightPx: an exact size
        // constraint fixes the height exactly like set-window-height does
        // (niri scrolling.rs: `if min_size.h == max_size.h { *h =
        // WindowHeight::Fixed(min_size.h) }`).
        let manualTotal = windows.reduce(CGFloat(0)) { $0 + ($1.effectiveFixedHeightPx ?? 0) }
        // Weighted, not equal: niri's WindowHeight::Auto carries a weight,
        // so a window that was made taller keeps its ratio when the column's
        // membership changes (see ManagedWindow.heightWeight).
        let weightTotal = windows.filter { $0.effectiveFixedHeightPx == nil }.reduce(CGFloat(0)) {
            $0 + max(0.01, $1.heightWeight)
        }
        let autoSpace = max(0, usableHeight - manualTotal)
        return windows.map { w in
            guard w.effectiveFixedHeightPx == nil else { return w.effectiveFixedHeightPx! }
            guard weightTotal > 0 else { return 0 }
            return autoSpace * max(0.01, w.heightWeight) / weightTotal
        }
    }

    // Which Auto windows in a stack refuse to shrink to an equal share of
    // the column's height (e.g. Telegram enforcing its own minimum) - same
    // idea as columnPlacements' width redistribution, applied within a
    // stack. Vertical space is still genuinely fixed (no scrolling), unlike
    // column width, so this redistribution still applies. Manually-sized
    // windows (set-window-height) are exempt entirely - they keep exactly
    // their fixed height and don't participate in the Auto split.
    private static func probeTargetHeights(
        column: Column, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
    ) -> [CGFloat] {
        let n = CGFloat(column.windows.count)
        let usableHeight = height - gap * (n - 1)
        let manualTotal = column.windows.reduce(CGFloat(0)) { $0 + ($1.effectiveFixedHeightPx ?? 0) }
        let autoCount = column.windows.filter { $0.effectiveFixedHeightPx == nil }.count
        let autoUsableHeight = max(0, usableHeight - manualTotal)
        // Weighted share per window (niri's Auto { weight }), so the first
        // probe already asks for the proportions the stack is supposed to
        // keep instead of an equal slice.
        let weightTotal = column.windows.filter { $0.effectiveFixedHeightPx == nil }.reduce(CGFloat(0)) {
            $0 + max(0.01, $1.heightWeight)
        }
        func weightedShare(_ w: ManagedWindow) -> CGFloat {
            guard weightTotal > 0 else { return 0 }
            return autoUsableHeight * max(0.01, w.heightWeight) / weightTotal
        }
        let naiveShare = autoCount > 0 ? autoUsableHeight / CGFloat(autoCount) : 0

        let stuckTolerance: CGFloat = 1.0
        var heights = [CGFloat](repeating: 0, count: column.windows.count)
        // A window that refused its share: its probed height is final, and
        // comes out of the pool the remaining Auto windows split.
        var stuck = [Bool](repeating: false, count: column.windows.count)
        var share = naiveShare
        var redistributed = false

        // Each pass writes the current share to every not-yet-stuck Auto
        // window and records what it ACCEPTED; a refusal shrinks the pool for
        // the others, so the new, smaller share has to be re-probed rather
        // than just recomputed - a window that fit the naive share can still
        // refuse the redistributed one, and returning that unverified number
        // stacked the window below it straight INTO it (and cached the
        // overlap for as long as the column's shape held). Bounded: an extra
        // pass requires at least one newly-stuck window.
        for _ in 0...column.windows.count {
            var currentY = y
            var newlyStuck = false
            for (i, w) in column.windows.enumerated() {
                // `share` starts as each window's weighted share and only
                // becomes a flat redistribution once someone refuses.
                let targetH =
                    w.effectiveFixedHeightPx
                    ?? (stuck[i] ? heights[i] : (redistributed ? share : weightedShare(w)))
                let actual = applyFrame(w, target: CGRect(x: x, y: currentY, width: width, height: targetH))
                    .height
                heights[i] = actual
                currentY += actual + gap
                if w.effectiveFixedHeightPx == nil, !stuck[i], actual > targetH + stuckTolerance {
                    stuck[i] = true
                    newlyStuck = true
                }
            }
            guard newlyStuck else { break }
            let stuckTotal = column.windows.indices
                .filter { stuck[$0] && column.windows[$0].effectiveFixedHeightPx == nil }
                .reduce(CGFloat(0)) { $0 + heights[$1] }
            let flexibleCount = column.windows.indices
                .filter { !stuck[$0] && column.windows[$0].effectiveFixedHeightPx == nil }.count
            guard flexibleCount > 0 else { break }
            share = max(0, autoUsableHeight - stuckTotal) / CGFloat(flexibleCount)
            redistributed = true
        }

        // Probed truth for every window, never a theoretical share.
        return heights
    }

    // Applies `target` to a single window and returns its ACTUAL resulting
    // frame - skipping the write when the window is already there, AND when
    // this exact request was already made and refused (the window sits at
    // the app's clamped answer to it - see ManagedWindow.lastRequestedFrame).
    // Re-writing a known refusal changes nothing on screen but generates
    // fresh moved/resized notifications, each of which triggers another
    // relayout - the loop only converges if a fully-applied layout performs
    // ZERO writes. Falls back to whatever frame the window already has if
    // the app refuses/fails the write, so callers always get a real frame
    // back instead of having to handle a missing one themselves.
    static func applyFrame(_ w: ManagedWindow, target: CGRect) -> CGRect {
        if let current = WindowMover.currentFrame(w.axElement) {
            if isClose(current, target) { return current }
            if let memo = w.refusalMemo, isClose(target, memo.requested), isClose(current, memo.actual) {
                return current
            }
        }
        var wrote = false
        do {
            debugLog(
                "[write] \(w.title) -> (\(Int(target.origin.x)),\(Int(target.origin.y))) \(Int(target.width))x\(Int(target.height))"
            )
            try WindowMover.setFrame(w.axElement, to: target)
            w.positionRefusals = 0
            wrote = true
        } catch let error as WindowMover.MoveError {
            if case .positionNotSettable = error {
                // A window in native fullscreen (a fullscreened video, the green
                // button) legitimately refuses position writes - that is
                // temporary, not the permanent "refuses to tile" the demotion is
                // for. Counting it demoted the window to floating, and it came
                // back stacked over its neighbour instead of in its column.
                let fullscreen: Bool = AX.attribute(w.axElement, "AXFullScreen") ?? false
                if fullscreen {
                    w.positionRefusals = 0
                } else {
                    w.notePositionRefusal()
                }
            }
            print("[layout] skipping \(w.title): \(error.description)")
        } catch {
            print("[layout] skipping \(w.title): unexpected error")
        }
        let actual = WindowMover.currentFrame(w.axElement) ?? target
        // The memo means "this exact request was made and THIS is the app's
        // answer", so it may only be recorded when the request actually
        // reached the app. setFrame writes the position and then the size, so
        // a busy app can take the position and time out on the size (1s, item
        // 11): memoizing there recorded a moved-but-not-resized frame as the
        // answer, and every later pass short-circuited on it - the window kept
        // its stale size until something bumped the epoch. Same reasoning as
        // the refusal counter in item 37: a timeout is not an answer.
        if wrote {
            switch Self.refusalVerdict(
                target: target, actual: actual, candidate: w.confirmedRefusalCandidate)
            {
            case .agreed:
                w.lastRequestedFrame = target
                w.lastActualFrame = actual
                w.refusalCandidate = nil
            case .confirmedRefusal:
                // The same divergent answer, two passes in a row: a real
                // min-size/clamp refusal. Latch it so we stop re-fighting.
                w.lastRequestedFrame = target
                w.lastActualFrame = actual
                w.refusalCandidate = nil
            case .unconfirmed:
                // First divergent answer. It may be a real refusal - or a busy
                // app's STALE read-back (the write landed, the frame just
                // hadn't updated when we read). Memoizing a stale read as
                // "the app's answer" latched permanently-wrong layouts, so
                // record only a candidate and let the next pass decide.
                w.refusalCandidate = (target, actual)
                w.lastRequestedFrame = nil
                w.lastActualFrame = nil
            }
        } else {
            w.lastRequestedFrame = nil
            w.lastActualFrame = nil
            w.refusalCandidate = nil
        }
        return actual
    }

    enum RefusalVerdict {
        case agreed
        case confirmedRefusal
        case unconfirmed
    }

    // Pure decision for the memoization above, selftestable: the answer
    // matches the request (agreed), matches a previous sighting of the same
    // divergent answer (confirmedRefusal), or diverges for the first time
    // (unconfirmed - retry before latching).
    static func refusalVerdict(
        target: CGRect, actual: CGRect, candidate: (requested: CGRect, actual: CGRect)?
    ) -> RefusalVerdict {
        if isClose(actual, target) { return .agreed }
        if let candidate, isClose(candidate.requested, target), isClose(candidate.actual, actual) {
            return .confirmedRefusal
        }
        return .unconfirmed
    }

    static func isClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1.0) -> Bool {
        abs(a.origin.x - b.origin.x) < tolerance && abs(a.origin.y - b.origin.y) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }
}

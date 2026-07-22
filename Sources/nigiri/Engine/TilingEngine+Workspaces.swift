import AppKit
import Foundation

// Workspaces: switching (vertical fall/rise animation), stashing, dynamic compaction, maximize, tabbed columns.
extension TilingEngine {
    // No real macOS Spaces (window-to-Space moves have no public API - CGS
    // calls, private since 10.7), NO minimizing (the Dock's genie/scale/
    // suck animation cannot be disabled), and NO app hiding (hide/unhide
    // are asynchronous AND apps restore their own autosaved frames while
    // materializing - a probabilistic ghost that survived three rounds of
    // gating, verified by screen recording). Pure, deterministic,
    // synchronous window geometry only.
    //
    // The animation endpoint: a ~45px bottom strip at the window's own x -
    // the fall decelerates into it, the rise starts from it. Its depth
    // stays shallower than any measured position clamp so no animated
    // write ever fights one.
    func stashStrip(_ frame: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(x: frame.origin.x, y: screenFrame.maxY - 45, width: frame.width, height: frame.height)
    }

    // The RESTING place for a window whose workspace is not active: a
    // single synchronous granted write, nothing async and nothing to race.
    func parkedOffScreen(_ frame: CGRect, screenFrame: CGRect) -> CGRect {
        // x only; y is left as-is. Measured (nigiri stopped):
        //
        //     ask x 1469 -> get 1469   1px visible          granted
        //     ask y  900 -> get  900                        granted
        //     ask y  940 -> get  915   title-bar height     clamped
        //     ask y    0 -> get   34   menu bar             clamped
        //
        // The y clamp always keeps a window's title bar on screen (32-66px
        // depending on the app), so vertical offsets hide nothing. All
        // hiding comes from x; moving y as well only adds motion.
        CGRect(x: screenFrame.maxX - 1, y: frame.origin.y, width: frame.width, height: frame.height)
    }

    // GNOME/niri dynamic workspaces: empty workspaces (other than the
    // active one) vanish and the rest reindex, and exactly one empty
    // trailing workspace always exists to move into. Runs from relayout,
    // so any window opening/closing/moving re-settles the set.
    func compactWorkspaces() {
        let plan = TilingEngine.compactPlan(
            workspaces.map {
                (empty: $0.columns.isEmpty && $0.floatingWindows.isEmpty, named: $0.name != nil)
            },
            active: activeWorkspaceIndex, previous: previousWorkspaceIndex,
            emptyAboveFirst: emptyWorkspaceAboveFirst)
        workspaces = plan.keep.map { workspaces[$0] }
        activeWorkspaceIndex = plan.active
        previousWorkspaceIndex = plan.previous
        if plan.insertLeading { workspaces.insert(Workspace(), at: 0) }
        if plan.appendTrailing { workspaces.append(Workspace()) }
        previousWorkspaceIndex = min(previousWorkspaceIndex, workspaces.count - 1)
    }

    // The dynamic-workspace rule, pure: which slots survive and where the two
    // indices end up. It rewrites activeWorkspaceIndex on every relayout, so
    // an off-by-one here reads exactly like "macOS switched my desktop on its
    // own" - and it had no check at all, because SelfTest never builds a
    // TilingEngine.
    struct CompactPlan {
        let keep: [Int]
        let active: Int
        let previous: Int
        let appendTrailing: Bool
        let insertLeading: Bool
    }

    static func compactPlan(
        _ slots: [(empty: Bool, named: Bool)], active: Int, previous: Int,
        emptyAboveFirst: Bool
    ) -> CompactPlan {
        var keep: [Int] = []
        var newActive = active
        var newPrevious = previous
        for (i, slot) in slots.enumerated() {
            // Named workspaces are persistent slots - never auto-removed even
            // when empty (that is the point of naming one) - and neither is
            // the active one, the trailing one, or the leading one under
            // empty-workspace-above-first.
            let keptAboveFirst = emptyAboveFirst && i == 0
            let removable =
                slot.empty && !slot.named && i != active && i != slots.count - 1 && !keptAboveFirst
            if removable {
                if newActive > keep.count { newActive -= 1 }
                if newPrevious > keep.count {
                    newPrevious -= 1
                } else if newPrevious == keep.count {
                    newPrevious = newActive
                }
                continue
            }
            keep.append(i)
        }
        // Re-express the indices against the SURVIVING array.
        let activeSlot = keep.firstIndex(of: active) ?? min(newActive, max(0, keep.count - 1))
        let previousSlot = keep.firstIndex(of: previous) ?? min(newPrevious, max(0, keep.count - 1))
        let lastEmpty = keep.last.map { slots[$0].empty } ?? true
        let firstEmpty = keep.first.map { slots[$0].empty } ?? true
        let insertLeading = emptyAboveFirst && !firstEmpty
        return CompactPlan(
            keep: keep,
            active: activeSlot + (insertLeading ? 1 : 0),
            previous: previousSlot + (insertLeading ? 1 : 0),
            appendTrailing: !lastEmpty,
            insertLeading: insertLeading)
    }

    // What a single liveness probe concluded about a window.
    enum DeathVerdict { case dead, alive, absentFromList }

    // The purge's consecutive-absence rule, pure. It is the final judge of
    // whether a LIVE window is deleted from the model and it has regressed
    // twice already (items 8 and 37).
    static func purgeVerdict(scans: Int, verdict: DeathVerdict) -> (scans: Int, dead: Bool) {
        switch verdict {
        case .dead: return (0, true)
        case .alive: return (0, false)
        case .absentFromList: return (scans + 1, scans + 1 >= 3)
        }
    }

    // Index of the workspace declared with this name, or nil. Named
    // workspaces are labeled slots, so this is just a lookup over the model.
    func workspaceIndex(named name: String) -> Int? {
        workspaces.firstIndex { $0.name == name }
    }

    // Focus the workspace carrying this stable id - niri's FocusWorkspace by Id,
    // which is what a bar sends when a workspace is clicked. The id is not a
    // position, so map it to one on the focused output; an unknown id is a
    // no-op.
    func focusWorkspace(byId id: UInt64) {
        if let index = workspaces.firstIndex(where: { $0.id == id }) {
            focusWorkspace(index + 1)
        }
    }

    // niri's focus-workspace N (1-based, Mod+1..9). Dynamic model: asking
    // for a number past the end lands on the trailing empty workspace
    // instead of manufacturing a stack of empty ones.
    func focusWorkspace(_ number: Int) {
        // niri creates workspaces up to N instead of clamping: pressing
        // Mod+7 with four workspaces open lands you on 7, not on the last
        // one. compactWorkspaces() collects whatever stays empty afterwards,
        // so this cannot leak workspaces.
        let requested = max(0, number - 1)
        while workspaces.count <= requested { workspaces.append(Workspace()) }
        let targetIndex = requested
        guard targetIndex != activeWorkspaceIndex else { return }
        // Two frames, and the difference matters once a strut is reserved: the
        // RAW visible frame is where windows park off-screen (below its bottom,
        // past its right edge), while the USABLE frame is where the layout puts
        // them - shrunk by any reserved zone. Using the raw frame for the
        // layout too left an entered workspace ignoring the strut (window at
        // the raw top, inside the reserved band), even though the same-screen
        // relayout honored it. Park with raw, lay out with usable.
        let screenFrame = currentRawScreenFrame()
        let usableFrame = usableScreen().frame
        let leaving = workspace
        previousWorkspaceIndex = activeWorkspaceIndex
        activeWorkspaceIndex = targetIndex

        // One combined spring, and the motion language is VERTICAL, matching
        // niri's vertically-stacked workspaces: leaving windows FALL straight
        // down from where they stand into their bottom strips, entering
        // windows RISE straight up from theirs. Down is the only hideable
        // direction - macOS refuses any position that would put a title bar
        // above the menu bar (verified live: y=-5000 reads back as 34), so
        // both switch directions share the fall-out/rise-in language rather
        // than mirroring. Everything here is synchronous, deterministic
        // geometry: no hide/unhide, no gates, no async races (see
        // stashStrip). Only the animation is async, and its completion is
        // guaranteed (fires cancelled if superseded), so the transition
        // flag cannot stick.
        var targets: [(window: ManagedWindow, frame: CGRect)] = []
        var fallPairs: [(ManagedWindow, CGRect)] = []
        for w in leaving.allWindows {
            // A switch arriving while the PREVIOUS switch's rise is still in
            // flight reads windows mid-air - stashing that transient
            // position would make a floating window "restore" to wherever
            // the interruption caught it. The in-flight animation's target
            // is where the window was actually headed; stash that instead.
            guard let frame = settledFrame(of: w) else { continue }
            w.stashedFrame = frame
            let strip = stashStrip(frame, screenFrame: screenFrame)
            fallPairs.append((w, strip))
            targets.append((w, strip))
        }
        var enteringTargets = ColumnLayoutEngine.targetFrames(
            columns: workspace.columns, in: usableFrame, maximizedIndex: workspace.maximizedIndex,
            viewOffset: workspace.viewOffset)
        var enteringFloating: [ManagedWindow] = []
        for w in workspace.floatingWindows {
            if let stashed = w.stashedFrame {
                enteringTargets.append((w, stashed))
                // stashedFrame is cleared in the completion, not here: a
                // superseded transition would otherwise leave the window at
                // the bottom strip with no record of where it belongs (the
                // tiling pass never touches floating windows).
                enteringFloating.append(w)
            }
        }
        // Entering windows rest as 1px corner lines - one synchronous write
        // moves each to the strip under its destination slot, where the
        // vertical rise starts. Visible for a single frame before motion
        // begins, which reads as the window emerging.
        for (w, frame) in enteringTargets {
            let pre = ColumnLayoutEngine.applyFrame(w, target: stashStrip(frame, screenFrame: screenFrame))
            debugLog(
                "[transition] \(w.title): pre=(\(Int(pre.origin.x)),\(Int(pre.origin.y))) target=(\(Int(frame.origin.x)),\(Int(frame.origin.y))) viewOffset=\(Int(workspace.viewOffset))"
            )
        }
        targets += enteringTargets

        isTransitioningWorkspace = true
        workspaceTransitionGeneration += 1
        lastWorkspaceSwitch = Date()
        let generation = workspaceTransitionGeneration
        focusCurrentColumn()
        // The ring hides for the whole transition and reappears at settle -
        // per-tick tracking over this long a travel draws an empty outline
        // ahead of the window's laggy real rendering (the ghost), and on an
        // empty workspace it would hover mid-air with nothing to frame.
        // The debounced update must die WITH the hide: a focus change in
        // the same run loop turn as this switch left its 50ms work item
        // pending, which then fired mid-transition and re-showed the ring
        // floating over the fall.
        pendingRingUpdate?.cancel()
        ring.hide()
        borders.hideAll()
        tabIndicators.hideAll()
        // Park every leaving window that is STILL inactive into the 1px
        // corner: the landed strip vanishes into an invisible line with one
        // synchronous granted write. Doubles as the superseded-transition
        // repair - nothing may be left frozen mid-screen.
        func parkInactive() {
            let activeNow = workspace.allWindows
            for (w, _) in fallPairs where !activeNow.contains(where: { $0 === w }) {
                guard let frame = WindowMover.currentFrame(w.axElement) else { continue }
                _ = ColumnLayoutEngine.applyFrame(w, target: parkedOffScreen(frame, screenFrame: screenFrame))
            }
        }
        let leavingSet = fallPairs.map { $0.0 }
        let focusedEntering = focusedManagedWindow()
        // Per-window settling: each landed strip parks into the corner the
        // very tick its own fall ends (no waiting for the slowest window -
        // the visible landed-header beat WAS the end-of-fall ghost), and
        // the ring appears the moment the FOCUSED window arrives instead of
        // when the whole animation settles.
        let clearStashOnArrival = enteringFloating
        animateFrames(
            targets, animation: "workspace-switch", trackRing: false,
            onWindowSettled: { w in
                if leavingSet.contains(where: { $0 === w }) {
                    guard let frame = WindowMover.currentFrame(w.axElement) else { return }
                    _ = ColumnLayoutEngine.applyFrame(
                        w, target: self.parkedOffScreen(frame, screenFrame: screenFrame))
                } else if w === focusedEntering, let target = enteringTargets.first(where: { $0.0 === w })?.1
                {
                    self.ring.show(around: target)
                }
            },
            completion: { cancelled in
                var discovered = false
                if !cancelled {
                    // The floating windows made it home; only now is their
                    // return address safe to drop.
                    for w in clearStashOnArrival { w.stashedFrame = nil }
                    discovered = self.applyLayout(screenFrame: usableFrame)
                    // Re-assert the model's focus: macOS may have handed real
                    // focus elsewhere during the switch - syncing FROM that
                    // transient state (instead of re-imposing ours) is what
                    // made the strip scroll sideways right after settling.
                    self.focusCurrentColumn()
                }
                parkInactive()
                self.updateInactiveDecorations()
                self.updateTabIndicators()
                guard generation == self.workspaceTransitionGeneration else { return }
                self.isTransitioningWorkspace = false
                if self.relayoutQueuedDuringTransition {
                    self.relayoutQueuedDuringTransition = false
                    self.scheduleRelayout()
                }
                // First visit to a workspace with a clamped window (Discord
                // rising into a 720px slot it can't take): the settle pass
                // just discovered its floor, so the strip and ring were
                // computed against stale placements - re-run the
                // scroll+animate now that the transition flag is down.
                // Bounded by the discovery cache.
                if discovered { self.reflow() }
            })
        print("focus-workspace \(number)")
        msgServer.broadcast("{\"event\":\"workspace\",\"active\":\(targetIndex + 1)}")
        emitWorkspaceActivated(targetIndex)
        emitWorkspacesChanged()
    }

    // niri's focus-workspace-down/up (Mod+Page_Down/Up, Mod+U/I) - cycles to
    // the adjacent workspace number, creating one past the end if needed.
    func focusWorkspaceRelative(delta: Int) {
        // empty-workspace-above-first: going up from the first workspace
        // grows a new empty one above it instead of doing nothing.
        if delta < 0, activeWorkspaceIndex == 0, emptyWorkspaceAboveFirst,
            !(workspace.columns.isEmpty && workspace.floatingWindows.isEmpty)
        {
            workspaces.insert(Workspace(), at: 0)
            activeWorkspaceIndex += 1
            previousWorkspaceIndex += 1
        }
        focusWorkspace(max(1, activeWorkspaceIndex + 1 + delta))
    }

    // niri's move-column-to-workspace N: relocates the focused column to
    // workspace N (creating it if needed) and stashes it to its bottom
    // strip, since it now belongs to a workspace that isn't the active one.
    // `focus` mirrors niri's parameter of the same name, verbatim from
    // niri-ipc/src/lib.rs:551 - "If `true` (the default), the focus will
    // follow the column to the new workspace." nigiri used to always keep
    // focus put, so the column just vanished from under the user: the
    // opposite of the muscle memory, on the nine Mod+Shift+N keys.
    func moveColumnToWorkspace(_ number: Int, focus: Bool = true) {
        guard !isTransitioningWorkspace else {
            print("move-column-to-workspace: ignored, a workspace switch is in progress")
            return
        }
        guard !workspace.isFloatingActive else {
            print("move-column-to-workspace: focus is on the floating layer")
            return
        }
        guard workspace.columns.indices.contains(workspace.focusedIndex) else {
            print("move-column-to-workspace: no focused column")
            return
        }
        // Dynamic model: past-the-end numbers land on the trailing empty
        // workspace (compactWorkspaces then grows a fresh trailing one).
        let targetIndex = min(max(0, number - 1), workspaces.count - 1)
        guard targetIndex != activeWorkspaceIndex else { return }
        let screenFrame = currentRawScreenFrame()
        guard let column = workspace.removeColumn(at: workspace.focusedIndex) else { return }
        // The fullscreen window cannot travel to another workspace and leave
        // this one still pointing at it: the same invariant detachFromTiling
        // enforces window by window.
        if let full = workspace.fullscreenWindow, column.windows.contains(where: { $0 === full }) {
            workspace.fullscreenWindow = nil
        }
        // Focus falls after the removal - to something the user can see,
        // not to whatever column (possibly on another macOS Space) slid
        // into the vacated index.
        workspace.focus(column: nearestVisiblyOccupiedColumnIndex(from: workspace.focusedIndex))
        for w in column.windows {
            guard let frame = WindowMover.currentFrame(w.axElement) else { continue }
            w.stashedFrame = frame
            _ = ColumnLayoutEngine.applyFrame(w, target: parkedOffScreen(frame, screenFrame: screenFrame))
        }
        workspaces[targetIndex].appendColumn(column)
        // The column keeps focus on arrival, so the switch below lands on it
        // rather than on whatever happened to be focused there before.
        workspaces[targetIndex].focus(column: workspaces[targetIndex].columns.count - 1)
        workspaces[targetIndex].isFloatingActive = false
        print("move-column-to-workspace \(number)\(focus ? " (following the focus)" : "")")
        if focus {
            // The normal animated switch - it restores the moved column from
            // the stash we just wrote, same as any other window arriving on
            // the workspace being entered.
            focusWorkspace(targetIndex + 1)
        } else {
            reflow()
        }
    }

    // The plain maximize toggle (niri's maximize-column). Pressing it while
    // the edges variant is active downgrades to a plain maximize instead of
    // toggling everything off - matching niri's separate states.
    func maximizeColumnToggle() {
        guard !workspace.isFloatingActive, !workspace.columns.isEmpty else { return }
        if workspace.maximizedIndex == workspace.focusedIndex {
            workspace.maximizedIndex = nil
            print("maximize-column: off")
        } else {
            workspace.maximizedIndex = workspace.focusedIndex
            print("maximize-column: column \(workspace.focusedIndex) (\(describeFocus()))")
        }
        reflow()
    }

    // niri's toggle-column-tabbed-display: flip the focused column between
    // a vertical stack and one-window-under-a-tab-bar. The stack's height
    // cache dies with the mode - the shapes are unrelated.
    func toggleColumnTabbedDisplay() {
        guard let column = focusedColumn() else { return }
        column.isTabbed.toggle()
        column.cachedHeights = nil
        reflow()
        print(
            "toggle-column-tabbed-display -> \(column.isTabbed ? "tabbed" : "normal") (\(column.windows.count) window(s))"
        )
    }

    // niri's switch-preset-window-height, applied to the focused window
    // like set-window-height.
    func switchPresetWindowHeight(delta: Int = 1) {
        guard let column = focusedColumn(), let window = focusedStackWindow() else { return }
        let columnHeight = usableScreen().frame.height - 2 * ColumnLayoutEngine.gap
        // niri's preset-window-heights: its OWN config list, cycled by
        // INDEX. nigiri used to reuse preset-column-WIDTHS scaled by the
        // column height, and to pick "the first preset taller than I am",
        // which skipped entries for any window sized off-preset.
        let presets = ColumnLayoutEngine.presetWindowHeightSizes.map { size -> CGFloat in
            switch size {
            case .proportion(let p):
                return ColumnLayoutEngine.height(forProportion: p, usableHeight: columnHeight)
            case .fixed(let px): return px
            }
        }
        guard !presets.isEmpty else { return }
        let current =
            window.manualHeightPx ?? (WindowMover.currentFrame(window.axElement)?.height ?? columnHeight)
        let base = window.presetHeightIndex ?? presets.firstIndex { $0 > current + 1 }.map { $0 - 1 } ?? -1
        let nextIndex = ((base + delta) % presets.count + presets.count) % presets.count
        window.presetHeightIndex = nextIndex
        let nextPreset = presets[nextIndex]
        window.manualHeightPx = nextPreset
        column.cachedHeights = nil
        reflow()
        print("switch-preset-window-height -> \(Int(nextPreset))px")
    }
}

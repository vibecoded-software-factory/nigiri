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
        // Special case (monitor.rs:646-653): with empty-workspace-above-first
        // and EVERYTHING empty, two empty unnamed workspaces collapse to
        // one - keeping both showed a phantom pair on an empty desktop.
        if emptyAboveFirst, !insertLeading, keep.count == 2,
            keep.allSatisfy({ slots[$0].empty && !slots[$0].named })
        {
            return CompactPlan(
                keep: [keep[0]], active: 0, previous: 0,
                appendTrailing: false, insertLeading: false)
        }
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
        // niri CLAMPS: switch_workspace(idx) is activate_workspace(min(idx,
        // len - 1)) (src/layout/monitor.rs:1011-1013). Pressing Mod+7 with
        // four workspaces lands on the trailing empty one, never on a
        // manufactured stack of empties. (The comment here used to claim
        // the opposite, citing niri for a behavior niri does not have -
        // fidelity audit ACT-1.)
        let targetIndex = min(max(0, number - 1), workspaces.count - 1)
        // niri's workspace-auto-back-and-forth (switch_workspace_auto_back_
        // and_forth, monitor.rs:1015-1025): focusing the workspace you are
        // already on goes back to the previous one, when the input flag asks.
        if targetIndex == activeWorkspaceIndex, workspaceAutoBackAndForth,
            previousWorkspaceIndex != activeWorkspaceIndex
        {
            focusWorkspace(previousWorkspaceIndex + 1)
            return
        }
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
            columns: workspace.columns, in: usableFrame,
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
        msgServer.broadcastLegacy("{\"event\":\"workspace\",\"active\":\(targetIndex + 1)}")
        emitWorkspaceActivated(targetIndex, focused: true)
        emitWorkspacesChanged()
    }

    // niri's focus-workspace-down/up (Mod+Page_Down/Up, Mod+U/I) - the
    // adjacent workspace, CLAMPED at both ends like switch_workspace_down/up
    // (src/layout/monitor.rs:992-1004): on the last workspace, down is a
    // no-op (focusWorkspace clamps), never a fresh empty one.
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
        if workspace.isFloatingActive {
            // niri's move_column_to_workspace with the floating layer active
            // falls through to moving the FLOATING WINDOW (monitor.rs:
            // 961-968, and the same in the up/down variants) - refusing with
            // a log line was invented behavior (audit ACT-3).
            moveWindowToWorkspace(number, focus: focus)
            return
        }
        guard workspace.columns.indices.contains(workspace.focusedIndex) else {
            print("move-column-to-workspace: no focused column")
            return
        }
        // Dynamic model: past-the-end numbers land on the trailing empty
        // workspace (compactWorkspaces then grows a fresh trailing one).
        let targetIndex = min(max(0, number - 1), workspaces.count - 1)
        // niri's workspace-auto-back-and-forth (switch_workspace_auto_back_
        // and_forth, monitor.rs:1015-1025): focusing the workspace you are
        // already on goes back to the previous one, when the input flag asks.
        if targetIndex == activeWorkspaceIndex, workspaceAutoBackAndForth,
            previousWorkspaceIndex != activeWorkspaceIndex
        {
            focusWorkspace(previousWorkspaceIndex + 1)
            return
        }
        guard targetIndex != activeWorkspaceIndex else { return }
        let screenFrame = currentRawScreenFrame()
        guard let column = workspace.removeColumn(at: workspace.focusedIndex) else { return }
        // Fullscreen travels WITH the column now (the flag lives on it,
        // like upstream's is_pending_fullscreen): the moved column arrives
        // on the other workspace still fullscreen, nothing to cancel here.
        // Focus falls after the removal - to something the user can see,
        // not to whatever column (possibly on another macOS Space) slid
        // into the vacated index.
        workspace.focus(column: nearestVisiblyOccupiedColumnIndex(from: workspace.focusedIndex))
        for w in column.windows {
            guard let frame = WindowMover.currentFrame(w.axElement) else { continue }
            w.stashedFrame = frame
            _ = ColumnLayoutEngine.applyFrame(w, target: parkedOffScreen(frame, screenFrame: screenFrame))
        }
        let target = workspaces[targetIndex]
        // niri inserts the arriving column NEXT TO the target's active one
        // (add_column's default index is active_column_idx + 1,
        // scrolling.rs:972-978), and with focus=false leaves the target's
        // own focus completely untouched (ActivateWindow::No,
        // monitor.rs:853-908). It used to append at the END and steal the
        // focus unconditionally (audit ACT-4). With focus=true the column
        // is activated on arrival, so the switch below lands on it.
        let insertAt = target.columns.isEmpty ? 0 : min(target.focusedIndex + 1, target.columns.count)
        target.insertColumn(column, at: insertAt, activating: focus)
        if focus { target.isFloatingActive = false }
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
        guard !workspace.isFloatingActive, let column = focusedColumn() else { return }
        // niri's toggle_full_width (scrolling.rs:4909-4917): a per-column
        // flag flip, so maximizing one column says nothing about any other -
        // several can be full-width at once.
        column.isFullWidth.toggle()
        if column.isFullWidth {
            print("maximize-column: column \(workspace.focusedIndex) (\(describeFocus()))")
        } else {
            print("maximize-column: off")
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
        // Leaving tabbed with a multi-window column cancels fullscreen and
        // maximize (scrolling.rs:2192-2196): the stack reappears, and a
        // fullscreen pinned to one of its windows no longer describes it.
        if !column.isTabbed, column.windows.count > 1 {
            if column.isPendingFullscreen || column.isPendingMaximized {
                toggleWindowedFullscreen()
            }
            column.isFullWidth = false
        }
        reflow()
        print(
            "toggle-column-tabbed-display -> \(column.isTabbed ? "tabbed" : "normal") (\(column.windows.count) window(s))"
        )
    }

    // niri's switch-preset-window-height, applied to the focused window
    // like set-window-height.
    func switchPresetWindowHeight(delta: Int = 1, id: UInt64? = nil) {
        guard let t = windowTarget(id: id, action: "switch-preset-window-height") else { return }
        guard case .tiled(let wi, let ci, _) = t.location else { return }
        let column = workspaces[wi].columns[ci]
        let window = t.window
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
        // Same two-tier resolution as the width presets (scrolling.rs:
        // 5043-5055): stored index advances by one; off-preset, forward
        // seeds at the first strictly-taller preset and backward at the
        // LAST strictly-shorter one. The old firstTaller-1 seed walked
        // backward one preset too far (audit LAY-7).
        guard
            let nextIndex = ColumnLayoutEngine.presetIndex(
                after: current, in: presets, delta: delta, from: window.presetHeightIndex)
        else { return }
        // One non-Auto height per column (scrolling.rs:244-247): upstream's
        // toggle_window_height routes through set_window_height, which
        // converts the siblings to Auto first.
        if window.manualHeightPx == nil, window.presetHeightIndex == nil {
            convertHeightsToAuto(column)
        }
        // Stored as niri's WindowHeight::Preset(idx), NOT materialized px:
        // the layout re-resolves it every pass (scrolling.rs:4533-4547), so
        // a monitor or gap change re-applies the proportion.
        window.manualHeightPx = nil
        window.presetHeightIndex = nextIndex
        column.cachedHeights = nil
        reflow()
        print(
            "switch-preset-window-height -> preset \(nextIndex + 1) (\(Int(presets[nextIndex]))px now)")
    }
}

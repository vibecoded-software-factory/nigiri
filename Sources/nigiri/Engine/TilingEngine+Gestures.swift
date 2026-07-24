import AppKit

// niri's continuous touchpad gestures (input/mod.rs:3843-4010), on top of
// the SwipeTracker port: a 3-finger swipe accumulates until 16px decides
// its axis - horizontal drives the view offset (scrolling.rs view_offset_
// gesture), vertical the workspace switch (monitor.rs workspace_switch_
// gesture) - and a 4-finger vertical swipe drives the overview
// (layout/mod.rs overview_gesture). Sign conventions: fingers are read in
// MT coordinates (y grows up), and macOS trackpads are natural-scroll, so
// fingers-left pans the columns left (camera right) and fingers-up goes to
// the next workspace - the same directions a niri touchpad produces.
//
// Two macOS-forced deviations, both at the RENDERING layer only (the
// decision math is upstream's exactly):
// - the workspace switch cannot slide two workspaces continuously (the
//   other workspace's windows are parked off-screen; AX cannot render them
//   mid-flight), so the gesture tracks invisibly and the landing workspace
//   plays the normal animated switch;
// - the overview is a panel, not a continuous zoom, so the gesture's
//   projected progress picks open/closed at the end instead of scrubbing.
extension TilingEngine {
    enum SwipeGestureState {
        // 3-finger, before the 16px axis lock decides.
        case undecided(cx: CGFloat, cy: CGFloat)
        case workspaceSwitch(WorkspaceSwitchGestureState)
        case viewOffset(ViewGestureState)
        // 4-finger: the tracker plus whether the overview was open at begin.
        case overview(SwipeTracker, wasOpen: Bool)
    }

    func handleSwipe(_ phase: SwipePhase) {
        switch phase {
        case .begin(let fingers):
            guard modDrag == nil, !isTransitioningWorkspace else { return }
            if fingers == 3 {
                swipeGesture = .undecided(cx: 0, cy: 0)
            } else {
                swipeGesture = .overview(SwipeTracker(), wasOpen: isOverviewActive)
            }
        case .update(let dx, let dy, let timestamp):
            swipeUpdate(dx: dx, dy: dy, timestamp: timestamp)
        case .end:
            swipeEnd()
        }
    }

    private func swipeUpdate(dx: CGFloat, dy: CGFloat, timestamp: TimeInterval) {
        switch swipeGesture {
        case nil:
            return
        case .undecided(var cx, var cy):
            cx += dx
            cy += dy
            let threshold = GestureConstants.axisLockThreshold
            if cx * cx + cy * cy >= threshold * threshold {
                // The axis decides the gesture (input/mod.rs:3910-3941).
                if abs(cx) > abs(cy) {
                    guard !workspace.columns.isEmpty else {
                        swipeGesture = nil
                        return
                    }
                    // Our own per-frame writes must not feed the relayout loop.
                    watcher.beginApplyingLayout()
                    swipeGesture = .viewOffset(
                        ViewGestureState(deltaFromTracker: workspace.viewOffset))
                } else {
                    swipeGesture = .workspaceSwitch(
                        WorkspaceSwitchGestureState(centerIdx: activeWorkspaceIndex))
                }
            } else {
                swipeGesture = .undecided(cx: cx, cy: cy)
            }
        case .workspaceSwitch(var gesture):
            // Natural scroll: fingers up (MT dy > 0) moves DOWN the strip,
            // toward the next workspace - pos > 0 raises the index, exactly
            // the sign niri sees after libinput's natural inversion.
            gesture.tracker.push(dy, timestamp: timestamp)
            swipeGesture = .workspaceSwitch(gesture)
        case .viewOffset(var gesture):
            // Natural scroll: fingers left (MT dx < 0) means the columns
            // follow the fingers left, i.e. the camera pans right - the
            // view offset grows.
            gesture.tracker.push(-dx, timestamp: timestamp)
            swipeGesture = .viewOffset(gesture)
            applyViewGestureFrame(gesture)
        case .overview(var tracker, let wasOpen):
            // Fingers up opens (progress grows), like niri's
            // overview_gesture_update(-uninverted_delta_y).
            tracker.push(dy, timestamp: timestamp)
            swipeGesture = .overview(tracker, wasOpen: wasOpen)
        }
    }

    // The 1:1 pan while the horizontal gesture is live: every tiled frame
    // at the gesture's view offset, written directly - the same immediate
    // path the animator's ticks use, no springs to fight the finger.
    private func applyViewGestureFrame(_ gesture: ViewGestureState) {
        let (screenFrame, usableWidth) = usableScreen()
        let offset = gesture.currentViewOffset(usableWidth: usableWidth)
        let targets = ColumnLayoutEngine.targetFrames(
            columns: workspace.columns, in: screenFrame, viewOffset: offset,
            includingParked: false)
        for (window, frame) in targets {
            try? WindowMover.setPosition(window.axElement, to: frame.origin)
        }
        updateRingImmediate()
    }

    private func swipeEnd() {
        guard let gesture = swipeGesture else { return }
        swipeGesture = nil
        let now = Date().timeIntervalSinceReferenceDate
        switch gesture {
        case .undecided:
            return
        case .workspaceSwitch(var g):
            // "Take into account any idle time between the last event and
            // now" (workspace_switch_gesture_end).
            g.tracker.push(0, timestamp: now)
            let newIdx = g.endIdx(workspaceCount: workspaces.count)
            if newIdx != activeWorkspaceIndex {
                focusWorkspace(newIdx + 1)
                print("gesture: workspace-switch -> \(newIdx + 1)")
            }
        case .viewOffset(var g):
            watcher.endApplyingLayout()
            g.tracker.push(0, timestamp: now)
            let usableWidth = usableScreen().usableWidth
            let placements = ColumnLayoutEngine.columnPlacements(
                columns: workspace.columns, usableWidth: usableWidth)
            let target = g.projectedViewOffset(usableWidth: usableWidth)
            guard
                let snap = ViewGestureSnapping.snap(
                    target: target, placements: placements, usableWidth: usableWidth)
            else {
                reflow()
                return
            }
            // The snap's column becomes the active one (upstream activates
            // the column whose snapping point won), and the settle animates
            // from wherever the finger left the view.
            workspace.viewOffset = g.currentViewOffset(usableWidth: usableWidth)
            workspace.focus(column: snap.colIdx)
            reflow(explicitViewOffset: snap.viewPos)
            focusCurrentColumn()
            print("gesture: view-offset -> column \(snap.colIdx)")
        case .overview(var tracker, let wasOpen):
            tracker.push(0, timestamp: now)
            // Progress starts at 1 with the overview open, 0 closed; the
            // projected end decides which side of 0.5 the gesture lands on
            // (layout/mod.rs overview_gesture_end), rubber-banded 0..1.
            let start: CGFloat = wasOpen ? 1 : 0
            let projected = start + tracker.projectedEndPos() / GestureConstants.overviewGestureMovement
            let open = RubberBand.overviewGesture.clamp(0, 1, projected) > 0.5
            if open, !isOverviewActive {
                enterOverview()
            } else if !open, isOverviewActive {
                exitOverview()
            }
        }
    }
}

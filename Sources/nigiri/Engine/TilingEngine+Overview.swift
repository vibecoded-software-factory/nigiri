import AppKit
import Foundation
import ScreenCaptureKit

// Overview mode: niri's zoomed-out camera of the real layout (thumbnail panel) and the move-the-windows fallback.
extension TilingEngine {
    // ---- overview (niri's toggle-overview, Exposé flavor) ----
    // No compositor means no scaled previews: the overview MOVES the real
    // windows into a grid - one row per occupied workspace, a labeled chip
    // on each row - and moves them back. Selection is a plain click on any
    // window (the mouse tap consumes it); toggling again returns without
    // switching. Everything rides existing machinery: the spring animator,
    // the corner park, the stash addresses, the relayout deferral.

    func anyManagedWindowAt(_ point: CGPoint) -> ManagedWindow? {
        for ws in workspaces {
            for w in ws.floatingWindows {
                if let f = WindowMover.currentFrame(w.axElement), f.contains(point) { return w }
            }
            for column in ws.columns {
                for w in column.windows {
                    if let f = WindowMover.currentFrame(w.axElement), f.contains(point) { return w }
                }
            }
        }
        return nil
    }

    func occupiedWorkspaceRows() -> [(wsIndex: Int, windows: [ManagedWindow])] {
        workspaces.enumerated().compactMap { i, ws in
            let windows = ws.allWindows
            return windows.isEmpty ? nil : (i, windows)
        }
    }

    // The pretty overview: a full-screen panel of live THUMBNAILS - the
    // real windows never move. Needs Screen Recording (a one-time,
    // once-per-boot-rate-limited request); without it, the move-the-real-
    // windows flavor below still works.
    func enterOverviewPanel() {
        guard !occupiedWorkspaceRows().isEmpty else {
            print("overview: no hay ninguna ventana que mostrar")
            return
        }
        isOverviewActive = true
        overviewUsedPanel = true
        startOverviewKeyMonitor()
        pendingRingUpdate?.cancel()
        ring.hide()
        borders.hideAll()
        tabIndicators.hideAll()
        // Show the previous capture NOW (the fresh one cannot land before the
        // panel does), then refresh it.
        overviewPanel.setBackdrop(lastDesktopImage)
        refreshDesktopBackdrop()
        startOverviewCaptureLoop()
        presentOverviewPanel(select: focusedManagedWindow())
        msgServer.broadcast("{\"event\":\"overview\",\"active\":true}")
        emitOverviewChanged(true)
        print("overview: panel on (\(overviewRowRanges.count) workspace(s), \(overviewSelection.count) window(s))")
    }

    // (Re)builds the thumbnail panel from the CURRENT model and shows it,
    // landing the selection ring on `select` (or the first entry). Shared by
    // the initial enter and every in-overview keyboard move: since a move
    // only reorders the model (real windows stay put in panel mode), the
    // whole panel is recomputed to show the new arrangement, thumbnails and
    // all. The one-time session setup (flags, key monitor, hiding the ring)
    // stays in enterOverviewPanel - this is purely the presentation.
    func presentOverviewPanel(select: ManagedWindow?) {
        let rows = occupiedWorkspaceRows()
        let screenFrame = usableScreen().frame
        // Gather each workspace's REAL geometry; OverviewPanel.computeRows
        // does the zoom-out math. targetFrames at viewOffset 0 gives every
        // column with its vertical stack intact; floating windows keep
        // their stashed/real frame.
        let inputs: [OverviewPanel.WorkspaceInput] = rows.map { row in
            let ws = workspaces[row.wsIndex]
            var frames = ColumnLayoutEngine.overviewFrames(columns: ws.columns, in: screenFrame,
                                                           maximizedIndex: ws.maximizedIndex,
                                                           viewOffset: ws.viewOffset)
            for fw in ws.floatingWindows {
                // fullscreenHome before the live frame: during a fullscreen
                // the live frame is the 1px parking spot, not where the
                // window belongs.
                frames.append((fw, fw.stashedFrame ?? fw.fullscreenHome
                                    ?? WindowMover.currentFrame(fw.axElement) ?? screenFrame))
            }
            // overviewFrames already leaves out the windows a tabbed column
            // parks; only degenerate frames are dropped here.
            let windows = frames
                .filter { $0.1.width > 2 && $0.1.height > 2 }
                .map { w, frame in
                    (window: w, layoutFrame: frame, captureFrame: WindowMover.currentFrame(w.axElement) ?? frame)
                }
            return OverviewPanel.WorkspaceInput(wsIndex: row.wsIndex,
                                                active: row.wsIndex == activeWorkspaceIndex,
                                                viewOffset: ws.viewOffset,
                                                windows: windows)
        }
        let computed = OverviewPanel.computeRows(inputs, screenFrame: screenFrame)
        overviewSelection = computed.selection
        let requests = computed.requests
        // Flatten the geometry for live navigation: one box per entry, plus
        // the index range each workspace row spans (for whole-row jumps).
        overviewBoxes = []
        overviewRowRanges = []
        overviewRowBands = []
        for row in computed.rows {
            let start = overviewBoxes.count
            overviewBoxes.append(contentsOf: row.entries.map { $0.box })
            overviewRowRanges.append(start..<overviewBoxes.count)
            overviewRowBands.append((row.wsIndex, row.band))
        }
        // Land the ring on the requested window (fall back to the first entry).
        overviewSelectedIndex = overviewSelection.firstIndex { $0.window === select } ?? 0
        // Rebuild ONLY when the panel's shape actually changed. This runs on
        // every relayout while the overview is up (that is what makes it a
        // live mirror), and every selection move raises its window, which
        // itself provokes an AX notification and therefore a relayout - so a
        // plain arrow key was tearing down and re-creating every card, and
        // the cards blinked. Same windows in the same boxes: nothing to
        // rebuild, just move the ring.
        let signature = computed.selection.map { $0.window.id } + overviewBoxes.map { UInt64($0.integerHash) }
        let rebuilt = signature != overviewPanelSignature
        if rebuilt {
            overviewPanelSignature = signature
            // Placeholder cards appear instantly; screenshots fill in as the
            // captures land, then a periodic refresh keeps live content moving.
            overviewPanel.show(screenFrame: screenFrame, rows: computed.rows,
                               animation: animationCurve(named: "overview-open-close"),
                               cameraAnimation: animationCurve(named: "horizontal-view-movement"))
            // A rebuilt panel has empty cards. Rather than keeping a parallel
            // cache of CGImages to seed them (a copy of every frame, forever,
            // for the rare rebuild), re-send the frame each window ALREADY
            // has: the streams and the still path both retain their last
            // buffer, and a surface can be handed to a new layer for free.
            replayOverviewFrames()
            fillStandIns(computed.selection)
        }
        overviewPanel.setSelectedIndex(overviewSelectedIndex)
        raiseOverviewSelection()
        // The loop reads these; it is started once per overview session by
        // enterOverviewPanel, not restarted here. The AX->SCWindow mapping is
        // re-resolved only when the panel's shape actually changed, which is
        // exactly when a window could have opened, closed or moved.
        if rebuilt, #available(macOS 14.0, *) {
            // The slot index is shared by overviewSelection, the requests and
            // the resolved SCWindows, so a rebuild renumbers all three at
            // once - and resolve() takes ~85ms (a system-wide enumeration).
            // Without a shape generation, a tick landing inside that window
            // wrote the OLD slot->window map's images against the NEW ids:
            // with [A,B,C] -> close A -> [B,C], B's picture was painted into
            // C's card. The only guard was ids.indices.contains(slot), which
            // is a bounds check, not an identity one. Two rebuilds inside
            // 85ms could also land their completions out of order.
            overviewShapeGeneration += 1
            overviewCaptureWindows = [:]
            let shape = overviewShapeGeneration
            let generation = overviewCaptureGeneration
            WindowCapture.resolve(requests) { resolved in
                guard generation == self.overviewCaptureGeneration,
                      shape == self.overviewShapeGeneration else { return }
                self.overviewCaptureWindows = resolved
                self.overviewCaptureIDs = self.overviewSelection.map { $0.window.id }
                self.startOverviewStreams(resolved)
            }
        }
    }

    // One capture pass, then schedule the next one from how long THIS one
    // took: a capture is ~11ms of GPU/XPC per window (measured), so a fixed
    // interval either starves the thumbnails on a busy workspace or burns the
    // machine on a quiet one. Rescheduling off the measured cost keeps the
    // duty cycle at about a third whatever the workspace holds, which is what
    // makes the overview read as live rather than as a slideshow.
    func runOverviewCaptureLoop(generation: Int) {
        guard #available(macOS 14.0, *), isOverviewActive, overviewUsedPanel,
              generation == overviewCaptureGeneration else { return }
        // Only what no stream is covering. On a settled overview this is
        // empty and the loop costs one timer wake-up: the streams deliver
        // when the windows actually change, which is what the loop was
        // faking at a fixed 6fps for every window at once.
        let streamed = streamedWindows
        let resolved = overviewCaptureWindows.filter { slot, _ in
            guard overviewCaptureIDs.indices.contains(slot) else { return true }
            return !streamed.contains(overviewCaptureIDs[slot])
        }
        guard !resolved.isEmpty else {
            // Nothing to shoot: heartbeat instead of spinning. Streams are
            // covering every card.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.runOverviewCaptureLoop(generation: generation) }
            return
        }
        // The ids that were resolved WITH this map, not whatever the model
        // holds now: the two only agree while the panel's shape is unchanged.
        let ids = overviewCaptureIDs
        let shape = overviewShapeGeneration
        let started = Date()
        // Ask for exactly the pixels the tile will show.
        let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
        var sizes: [Int: CGSize] = [:]
        let tiles = Dictionary(uniqueKeysWithValues: overviewPanel.thumbnailTargets(scale: scale).map { ($0.id, $0.size) })
        for (slot, _) in resolved where ids.indices.contains(slot) {
            if let size = tiles[ids[slot]] { sizes[slot] = size }
        }
        WindowCapture.capture(resolved: resolved, sizes: sizes) { buffers in
            guard self.isOverviewActive, self.overviewUsedPanel,
                  generation == self.overviewCaptureGeneration,
                  shape == self.overviewShapeGeneration else { return }
            for (slot, buffer) in buffers where ids.indices.contains(slot) {
                let id = ids[slot]
                // Retained so the surface stays valid while the layer shows
                // it, and so a rebuilt panel can be re-seeded from it.
                self.overviewStills[id] = buffer
                if let surface = CVPixelBufferGetIOSurface(buffer) {
                    self.overviewPanel.setThumbnail(unsafeBitCast(surface.takeUnretainedValue(), to: IOSurface.self),
                                                    forWindow: id)
                }
            }
            let cost = Date().timeIntervalSince(started)
            debugLog("[capture] \(buffers.count) ventana(s) en \(Int(cost * 1000))ms")
            // Wait as long as the batch took: half the time capturing, half
            // idle, on a background queue. Off the main thread this is a
            // throughput knob rather than a stutter knob - it was cost * 2
            // while the captures still ran on main, to keep the stalls apart.
            let delay = min(0.4, max(0.06, cost))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.runOverviewCaptureLoop(generation: generation)
            }
        }
    }

    // One live stream per card. The still loop stays as the safety net: it
    // covers the first frames (a stream's first frame lands a moment after it
    // starts), minimized windows (Apple pauses their streams) and anything
    // whose stream failed.
    @available(macOS 14.0, *)
    func startOverviewStreams(_ resolved: [Int: SCWindow]) {
        let scale = usableScreen().frame.width > 0 ? (NSScreen.screens.first?.backingScaleFactor ?? 2) : 2
        var sizeByID: [UInt64: CGSize] = [:]
        for target in overviewPanel.thumbnailTargets(scale: scale) { sizeByID[target.id] = target.size }
        var starting: [(id: UInt64, window: SCWindow, size: CGSize)] = []
        for (slot, scWindow) in resolved {
            guard overviewCaptureIDs.indices.contains(slot) else { continue }
            let id = overviewCaptureIDs[slot]
            guard let size = sizeByID[id] else { continue }
            starting.append((id, scWindow, size))
        }
        guard !starting.isEmpty else { return }
        let ids = Set(starting.map { $0.id })
        // A window that is no longer on the panel loses its stream, so it
        // must also lose its "covered by a stream" mark - otherwise the still
        // loop would keep skipping a card that nothing is feeding.
        streamedWindows.formIntersection(ids)
        streamer.keepOnly(ids)
        streamer.start(starting)
        debugLog("[stream] \(starting.count) ventana(s) en vivo")
    }

    // Every card starts with something recognisable, before any pixels of
    // the real window exist - and stays that way when they never will: no
    // Screen Recording grant, a stream that stopped (macOS re-asks for the
    // grant monthly since Sequoia and they all die together), or a window so
    // idle it never produces a frame.
    func fillStandIns(_ selection: [(window: ManagedWindow, wsIndex: Int)]) {
        let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
        let sizes = Dictionary(uniqueKeysWithValues: overviewPanel.thumbnailTargets(scale: scale).map { ($0.id, $0.size) })
        for entry in selection {
            let w = entry.window
            // Something that already has real pixels keeps them.
            if overviewStills[w.id] != nil { continue }
            if #available(macOS 14.0, *), streamedWindows.contains(w.id) { continue }
            overviewPanel.setStandIn(WindowStandIn.icon(forPid: w.pid), forWindow: w.id)
            // ...and if the window is showing a FILE, the document itself,
            // rendered by QuickLook. No Screen Recording involved: this comes
            // from the Accessibility grant nigiri already holds.
            guard let url = WindowStandIn.documentURL(of: w) else { continue }
            let size = sizes[w.id] ?? CGSize(width: 320, height: 240)
            WindowStandIn.documentThumbnail(for: url, size: size) { [weak self] image in
                guard let self, self.isOverviewActive, self.overviewStills[w.id] == nil else { return }
                if #available(macOS 14.0, *), self.streamedWindows.contains(w.id) { return }
                self.overviewPanel.setStandIn(image, forWindow: w.id)
            }
        }
    }

    // Re-send every frame we already hold to the cards that are showing
    // those windows now.
    func replayOverviewFrames() {
        for (id, buffer) in overviewStills {
            guard let surface = CVPixelBufferGetIOSurface(buffer) else { continue }
            overviewPanel.setThumbnail(unsafeBitCast(surface.takeUnretainedValue(), to: IOSurface.self), forWindow: id)
        }
        if #available(macOS 14.0, *) { streamer.replay() }
    }

    func startOverviewCaptureLoop() {
        overviewCaptureGeneration += 1
        runOverviewCaptureLoop(generation: overviewCaptureGeneration)
    }

    func stopOverviewCaptureLoop() {
        if #available(macOS 14.0, *) {
            streamer.stopAll()
            streamedWindows = []
        }
        overviewCaptureGeneration += 1
        overviewCaptureWindows = [:]
        overviewCaptureIDs = []
        // The thumbnail cache only exists to seed the cards WITHIN one
        // overview session, and window ids are a monotonic counter that never
        // repeats - so every entry of a window that has since closed is a
        // ~0.3-0.9MB CGImage nobody will ever read again, in a process that
        // runs for days. Same policy the purge states for its own caches.
        // The last frame of each window SURVIVES the session, pruned to what
        // still exists: it is what lets the next overview open on real
        // pixels. It matters more now that the animation starts at zoom 1,
        // where a card is exactly the size of its window - opening on the app
        // icon at that size reads as a placeholder, opening on the window
        // reads as the window itself shrinking, which is the whole effect.
        // Bounded by construction: one frame per live window, dropped with
        // the window.
        let live = Set(workspaces.flatMap { $0.allWindows.map { $0.id } })
        overviewStills = overviewStills.filter { live.contains($0.key) }
        WindowStandIn.forgetDocuments()
    }

    func enterOverview() {
        guard !isOverviewActive else { return }
        guard !isTransitioningWorkspace else {
            print("overview: ignorado, hay un cambio de workspace en curso")
            return
        }
        // The panel works either way now: with the Screen Recording grant it
        // shows live windows, without it the app icons and - for a window
        // showing a file - a QuickLook render of that document. Both beat
        // hauling the user's real windows around the screen, which is what
        // the fallback below does; that one is kept for macOS 13, where
        // ScreenCaptureKit is not available at all.
        if #available(macOS 14.0, *) {
            if !WindowCapture.hasPermission(), WindowCapture.requestPermissionOnce() {
                print("overview: Screen Recording pedido (una sola vez) - mientras tanto, iconos y documentos")
            }
            enterOverviewPanel()
            return
        }
        enterOverviewMoving()
    }

    func enterOverviewMoving() {
        let rows = occupiedWorkspaceRows()
        guard !rows.isEmpty else { return }
        isOverviewActive = true
        overviewUsedPanel = false
        startOverviewKeyMonitor()
        pendingRingUpdate?.cancel()
        ring.hide()
        borders.hideAll()
        tabIndicators.hideAll()
        let screenFrame = usableScreen().frame
        // Active-workspace floating windows need a return address; every
        // other workspace's windows already carry one from their stash.
        for w in workspace.floatingWindows where w.stashedFrame == nil {
            w.stashedFrame = WindowMover.currentFrame(w.axElement)
        }
        let gap = ColumnLayoutEngine.gap
        let rowHeight = (screenFrame.height - CGFloat(rows.count + 1) * gap) / CGFloat(rows.count)
        var targets: [(window: ManagedWindow, frame: CGRect)] = []
        var chips: [(y: CGFloat, label: String, active: Bool)] = []
        for (rowIndex, row) in rows.enumerated() {
            let y = screenFrame.minY + gap + CGFloat(rowIndex) * (rowHeight + gap)
            let count = CGFloat(row.windows.count)
            let cellWidth = (screenFrame.width - (count + 1) * gap) / count
            for (i, w) in row.windows.enumerated() {
                targets.append((w, CGRect(x: screenFrame.minX + gap + CGFloat(i) * (cellWidth + gap), y: y, width: cellWidth, height: rowHeight)))
            }
            chips.append((y: y + 4, label: "Workspace \(row.wsIndex + 1)", active: row.wsIndex == activeWorkspaceIndex))
        }
        overviewChrome.show(rows: chips)
        animateFrames(targets, trackRing: false) { _ in }
        msgServer.broadcast("{\"event\":\"overview\",\"active\":true}")
        emitOverviewChanged(true)
        print("overview: on (\(rows.count) workspace(s))")
    }

    // Escape/Return, live only while the overview is up - registered as real
    // (unmodified) Carbon hotkeys, the same mechanism as every config bind.
    //
    // They used to be an NSEvent GLOBAL monitor, which can only WATCH: the
    // key fired the overview action AND still reached whatever app had
    // focus. Since the panel deliberately never becomes key (the selected
    // window must keep real focus so native shortcuts land on it), Enter
    // typed anywhere - a terminal, a chat box - closed the overview behind
    // the user's back. A hotkey registration swallows the key instead, and
    // only for as long as the overview is open. A keyboard CGEventTap would
    // also swallow it, but that is the keylogger-class API behind Input
    // Monitoring, which nigiri deliberately does not use (see
    // MouseDragController's scope note).
    func startOverviewKeyMonitor() {
        guard !overviewKeysRegistered, overviewKeyMonitor == nil else { return }
        // Reserve first, and only fall back to watching if the reservation
        // fails. A reservation CONSUMES the key; the global monitor cannot,
        // so every Escape that closed the overview also reached the focused
        // app - which, with an agent running in the terminal, meant closing
        // the overview interrupted it (reported live). Verified afterwards on
        // this machine: Escape DOES arrive as a hotkey, contradicting an
        // older note in this file that had it accepted-but-never-delivered.
        _ = overviewKeys.start()
        let escape = overviewKeys.register(53, modifiers: []) { self.exitOverview() }
        let ret = overviewKeys.register(36, modifiers: []) { self.overviewConfirmSelection() }
        let enter = overviewKeys.register(76, modifiers: []) { self.overviewConfirmSelection() }
        if escape, ret || enter {
            overviewKeysRegistered = true
            return
        }
        overviewKeys.unregisterAll()
        print("overview: Escape/Enter no se pudieron reservar - modo observador (la tecla tambien llega a la app)")
        overviewKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { event in
            switch event.keyCode {
            case 53: MainActor.assumeIsolated { self.exitOverview() }
            case 36, 76: MainActor.assumeIsolated { self.overviewConfirmSelection() }
            default: break
            }
        }
    }

    func stopOverviewKeyMonitor() {
        if overviewKeysRegistered {
            overviewKeys.unregisterAll()
            overviewKeysRegistered = false
        }
        if let monitor = overviewKeyMonitor {
            NSEvent.removeMonitor(monitor)
            overviewKeyMonitor = nil
        }
    }

    func exitOverview(focusing explicitSelection: ManagedWindow? = nil) {
        guard isOverviewActive else { return }
        // niri's overview selection IS the focus: closing it - by click, by
        // Enter, or by Escape/toggle - lands on whatever the ring framed. So
        // when no explicit target is given, fall back to the selected window
        // (captured before overviewSelection is cleared below).
        let selected = explicitSelection ?? (overviewUsedPanel ? overviewSelectedWindow() : nil)
        print("overview exit -> focusing \(selected?.title ?? "(nothing)")\(explicitSelection == nil ? " (from the ring)" : " (explicit)")")
        isOverviewActive = false
        // Next entry rebuilds from scratch: the windows will have moved.
        overviewPanelSignature = []
        stopOverviewKeyMonitor()
        stopOverviewCaptureLoop()
        overviewChrome.hide()
        // Panel flavor: nothing moved, so exiting is just hiding the panel -
        // and selecting is a plain focus (same workspace) or a normal
        // animated workspace switch (the machinery already knows how).
        if overviewUsedPanel {
            overviewPanel.hide(animation: animationCurve(named: "overview-open-close"))
            overviewUsedPanel = false
            overviewSelection = []
            // Every rearrangement made inside the overview was already
            // applied to the real windows when it happened, so exiting is
            // just focus - nothing is left to move. It used to be queued up
            // here instead, which is why the layout lurched into place a
            // beat AFTER the panel disappeared.
            //
            // activateWorkspace: false - a selection on ANOTHER workspace is
            // handed to focusWorkspace, which animates the real switch;
            // writing the index here would skip the stash and leave both
            // workspaces' windows on screen at once.
            if let selected, let location = focusInModel(selected, activateWorkspace: false) {
                if location.workspaceIndex == activeWorkspaceIndex {
                    if case .tiled = location { reflow() }
                    focusCurrentColumn()
                } else {
                    focusWorkspace(location.workspaceIndex + 1)
                }
            }
            updateRingImmediate()
            if relayoutQueuedDuringTransition {
                relayoutQueuedDuringTransition = false
                scheduleRelayout()
            }
            msgServer.broadcast("{\"event\":\"overview\",\"active\":false}")
            emitOverviewChanged(false)
            print("overview: panel off -> workspace \(activeWorkspaceIndex + 1)")
            return
        }
        // Moving flavor: put everything back where it belongs.
        // Selecting a window makes its workspace active and focuses it.
        // The moving flavor re-places every window itself below, so it can
        // switch workspace by assignment.
        if let selected {
            focusInModel(selected, activateWorkspace: true)
            // The same residual-activation grace a real workspace switch gets.
            lastWorkspaceSwitch = Date()
        }
        placeAllWindowsFromModel {
            self.focusCurrentColumn()
            self.updateRingImmediate()
            if self.relayoutQueuedDuringTransition {
                self.relayoutQueuedDuringTransition = false
                self.scheduleRelayout()
            }
        }
        msgServer.broadcast("{\"event\":\"overview\",\"active\":false}")
        emitOverviewChanged(false)
        print("overview: off -> workspace \(activeWorkspaceIndex + 1)")
    }

    // Put every real window where the model now says it belongs: the active
    // workspace laid out, every other workspace's windows parked. Shared by
    // the overview's exit and by each in-overview rearrangement.
    @discardableResult
    func placeAllWindowsFromModel(trackRing: Bool = false, onDone: (() -> Void)? = nil) -> CGRect {
        let screenFrame = usableScreen().frame
        var targets = ColumnLayoutEngine.targetFrames(columns: workspace.columns, in: screenFrame,
                                                      maximizedIndex: workspace.maximizedIndex,
                                                      viewOffset: workspace.viewOffset)
        // The stash is cleared in the completion, and only if the animation
        // was NOT superseded: clearing it here left a floating window
        // stranded mid-flight at overview-cell size with no return address if
        // anything reflowed during the trip (a bind, or the app activation
        // the selection itself provokes). Nothing repairs that - the tiling
        // pass never touches the floating layer - and the next overview
        // recorded the deformed frame as its new home. focusWorkspace does
        // exactly this and says why (clearStashOnArrival).
        var clearStashOnArrival: [ManagedWindow] = []
        for w in workspace.floatingWindows {
            if let home = w.stashedFrame {
                targets.append((w, home))
                clearStashOnArrival.append(w)
            }
        }
        for (i, ws) in workspaces.enumerated() where i != activeWorkspaceIndex {
            for w in ws.allWindows {
                guard let frame = WindowMover.currentFrame(w.axElement) else { continue }
                targets.append((w, parkedOffScreen(frame, screenFrame: screenFrame)))
            }
        }
        animateFrames(targets, trackRing: trackRing) { cancelled in
            if !cancelled {
                for w in clearStashOnArrival { w.stashedFrame = nil }
                self.applyLayout(screenFrame: screenFrame)
            }
            onDone?()
        }
        return screenFrame
    }

    // A rearrangement made INSIDE the overview happens for real, right away,
    // behind the panel - instead of being queued up and unleashed on exit,
    // which read as the whole layout lurching into place a beat late. The
    // model is already updated by the caller; this is the physical half.
    func applyOverviewRearrangement() {
        placeAllWindowsFromModel()
    }

    // ---- live navigation inside the panel overview (niri parity) ----
    // Navigation itself moves nothing: it walks the grid of thumbnails and
    // moves the selection ring. Movement is SPATIAL
    // over the boxes you actually see (nearest neighbor in the pressed
    // direction) rather than replaying column/stack semantics - visually
    // identical, and it can't desync from the real layout model.

    enum OverviewDirection { case left, right, up, down }

    // Intercepts an action while the panel overview is up. Returns true if it
    // was a navigation/confirm action handled here (overview stays open, or
    // closes on confirm); false lets performAction fall through to its
    // normal "any action exits the overview" path.
    func handleOverviewPanelAction(_ name: String, _ parts: [Substring]) -> Bool {
        guard isOverviewActive, overviewUsedPanel else { return false }
        switch name {
        case "focus-column-left": overviewNavigate(.left); return true
        case "focus-column-right": overviewNavigate(.right); return true
        case "focus-window-up": overviewNavigate(.up); return true
        case "focus-window-down": overviewNavigate(.down); return true
        case "focus-column-first": overviewSelectRowEdge(first: true); return true
        case "focus-column-last": overviewSelectRowEdge(first: false); return true
        case "focus-workspace-up", "focus-workspace-previous": overviewJumpRow(-1); return true
        case "focus-workspace-down": overviewJumpRow(1); return true
        // ---- keyboard moves: reorder the model, rebuild the panel ----
        case "move-column-left": overviewMoveColumn(-1); return true
        case "move-column-right": overviewMoveColumn(1); return true
        case "move-window-up": overviewMoveWindowInStack(-1); return true
        case "move-window-down": overviewMoveWindowInStack(1); return true
        case "move-column-to-workspace":
            if parts.count > 1, let n = Int(parts[1]) { overviewMoveColumnToWorkspace(n) }
            else if parts.count > 1, let idx = workspaceIndex(named: String(parts[1])) { overviewMoveColumnToWorkspace(idx + 1) }
            return true
        case "move-column-to-workspace-up": overviewMoveColumnToWorkspaceRelative(-1); return true
        case "move-column-to-workspace-down": overviewMoveColumnToWorkspaceRelative(1); return true
        // ---- window actions target the SELECTED window, in place ----
        case "close-window": overviewCloseSelected(); return true
        default: return false
        }
    }

    // Close the selected window's real window (its AX close button) and keep
    // the overview open, rebuilding it around a neighbor. Window actions in
    // overview act on the selection, niri-style; close is the common one and
    // benefits from staying in the overview so several can be closed in a row.
    func overviewCloseSelected() {
        guard let w = overviewSelectedWindow() else { return }
        // Pick a neighbor to land on before w disappears.
        let neighbor: ManagedWindow? = {
            let s = overviewSelectedIndex
            if overviewSelection.indices.contains(s + 1) { return overviewSelection[s + 1].window }
            if overviewSelection.indices.contains(s - 1) { return overviewSelection[s - 1].window }
            return nil
        }()
        // Press the real close button (same path as closeWindow()).
        if let closeButton = AX.element(w.axElement, kAXCloseButtonAttribute as String) {
            AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
        } else {
            print("overview close: \(w.title) has no close button")
        }
        // Drop it from the model now so the panel reflects the close at once;
        // the async destroy observer no-ops once it's already gone.
        if let loc = overviewLocateWindow(w) {
            let col = workspaces[loc.wsIndex].columns[loc.colIndex]
            col.removeWindows {  $0 === w }
            col.cachedHeights = nil
            if col.windows.isEmpty { _ = workspaces[loc.wsIndex].removeColumn(at: loc.colIndex) }
            // Whole-workspace normalisation, not just this column's row:
            // removing a column can leave the workspace's own focusedIndex
            // (and the floating focus) pointing past the end, which is
            // invisible until that workspace is next entered.
            workspaces[loc.wsIndex].clampFocus()
        }
        for ws in workspaces { ws.floatingWindows.removeAll { $0 === w } }
        applyOverviewRearrangement()
        if occupiedWorkspaceRows().isEmpty { exitOverview(); return }
        presentOverviewPanel(select: neighbor)
    }

    // True unless the window is gone. Two death modes: the whole app process
    // exited (Cmd+Q, killed, crash) - then no NSRunningApplication for its
    // pid; or a single window closed inside a live app (Cmd+W) - then the AX
    // element is invalid. Minimized / off-Space windows stay alive (their
    // element answers with other errors), so no false prunes.
    func windowIsAlive(_ w: ManagedWindow) -> Bool {
        if NSRunningApplication(processIdentifier: w.pid) == nil { return false }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(w.axElement, kAXRoleAttribute as CFString, &value) != .invalidUIElement
    }

    // Prune windows whose real window has been destroyed and rebuild the
    // panel, so a close done outside the overview action (Command+W, an app
    // quitting) updates the thumbnails live instead of only on exit.
    func refreshOverviewForDeadWindows() {
        let sel = overviewSelectedWindow()
        var removedAny = false
        for ws in workspaces {
            for col in ws.columns {
                let n = col.windows.count
                col.removeWindows {  !windowIsAlive($0) }
                if col.windows.count != n {
                    removedAny = true
                    col.cachedHeights = nil
                    col.clampFocus()
                }
            }
            var i = ws.columns.count - 1
            while i >= 0 { if ws.columns[i].windows.isEmpty { _ = ws.removeColumn(at: i) }; i -= 1 }
            let f = ws.floatingWindows.count
            ws.floatingWindows.removeAll { !windowIsAlive($0) }
            if ws.floatingWindows.count != f { removedAny = true }
        }
        guard removedAny else { return }
        // Same rule as relayout's purge: every workspace re-anchors its
        // indices after windows disappear.
        for ws in workspaces { ws.clampFocus() }
        // A fullscreen window that died must not keep the workspace shoved
        // aside (relayout does this too, but the overview purges on its own).
        for ws in workspaces {
            if let full = ws.fullscreenWindow,
               !ws.allWindows.contains(where: { $0 === full }) {
                ws.fullscreenWindow = nil
            }
        }
        applyOverviewRearrangement()
        if occupiedWorkspaceRows().isEmpty { exitOverview(); return }
        presentOverviewPanel(select: sel.flatMap { windowIsAlive($0) ? $0 : nil })
    }

    // The window the selection ring currently frames.
    // niri's overview selection IS the focus - the ring moving means macOS
    // focus moving too, not just a highlight. Without this the panel was
    // decorative until Enter/click: the app focused BEFORE opening the
    // overview kept real focus, so every plain shortcut typed with the
    // overview up (Cmd+N, Cmd+W, Cmd+T - none of them nigiri binds, they go
    // straight to the frontmost app) acted on the OLD window. Verified live:
    // focus Chrome, open the overview, move the ring onto the terminal,
    // press Cmd+N - and CHROME opened the new window.
    // Safe to raise from here: the app-activation observer bails out while
    // the overview is active, so this can't trigger a strip scroll or a ring
    // chase, and the panel sits at .floating, above whatever gets raised.
    // The camera travels with the selection, the way it does outside the
    // overview: niri scrolls the workspace so the focused column is in view
    // (compute_new_view_offset), and the overview draws each workspace at its
    // own scroll position - so without this, navigating onto a column that is
    // off-view selected something the user cannot see.
    //
    // Only the selection's OWN workspace moves; the others keep their cameras,
    // exactly as they would if you focused them one at a time.
    func overviewFollowCamera() {
        guard overviewSelection.indices.contains(overviewSelectedIndex) else { return }
        let selected = overviewSelection[overviewSelectedIndex]
        guard workspaces.indices.contains(selected.wsIndex) else { return }
        let ws = workspaces[selected.wsIndex]
        guard let columnIndex = ws.columns.firstIndex(where: { column in
            column.windows.contains { $0 === selected.window }
        }) else { return }   // a floating window has no column to scroll to
        let screenFrame = usableScreen().frame
        let usableWidth = screenFrame.width - 2 * ColumnLayoutEngine.gap
        let placements = ColumnLayoutEngine.columnPlacements(columns: ws.columns,
                                                            usableWidth: usableWidth,
                                                            maximizedIndex: ws.maximizedIndex)
        let offset = ColumnLayoutEngine.scrollOffset(toShow: columnIndex, placements: placements,
                                                     currentOffset: ws.viewOffset,
                                                     usableWidth: usableWidth,
                                                     previousIndex: ws.focusedIndex)
        // The model's focus moves with it: the offset is computed FROM the
        // column focus came from, so leaving it behind would make the next
        // move measure against a stale one.
        ws.focus(column: columnIndex)
        guard abs(offset - ws.viewOffset) > 0.5 else { return }
        let before = ws.viewOffset
        ws.viewOffset = offset
        // PAN, do not rebuild. Rebuilding tore down and recreated every card
        // (text fields and layers included) and re-ran the system-wide
        // SCWindow resolution, twice per keypress once the relayout that the
        // focus change provokes came back around - which is what made moving
        // between cards feel heavy next to moving between real windows.
        let zoom = min(0.75, max(0.0001, OverviewPanel.zoom))
        let moved = (before - offset) * zoom
        overviewPanel.panCamera(wsIndex: selected.wsIndex, by: moved,
                                selected: overviewSelectedIndex,
                                animation: animationCurve(named: "horizontal-view-movement"))
        if let rowIndex = overviewRowBands.firstIndex(where: { $0.wsIndex == selected.wsIndex }),
           overviewRowRanges.indices.contains(rowIndex) {
            for i in overviewRowRanges[rowIndex] where overviewBoxes.indices.contains(i) {
                overviewBoxes[i].origin.x += moved
            }
        }
    }

    // niri's overview pans with a scroll: view_offset_gesture_update divides
    // the delta by the zoom, so the strip travels exactly as far as the
    // fingers did ON SCREEN rather than in workspace coordinates. The
    // workspace under the cursor is the one that moves - each has its own
    // camera, and reaching for the row you are looking at is the whole point.
    //
    // A plain mouse wheel has no horizontal axis, so a vertical scroll pans
    // too: in the overview there is nothing else for it to do (the panel owns
    // the screen), and refusing it would make the feature useless on anything
    // but a trackpad.
    @discardableResult
    func overviewPan(dx: CGFloat, dy: CGFloat, at point: CGPoint) -> Bool {
        guard isOverviewActive, overviewUsedPanel else { return false }
        let travel = dx != 0 ? dx : dy
        guard travel != 0 else { return false }
        let zoom = min(0.75, max(0.0001, OverviewPanel.zoom))
        let rowIndex = overviewRowBands.firstIndex { $0.band.contains(point) }
            ?? overviewRowRanges.firstIndex { $0.contains(overviewSelectedIndex) }
        guard let rowIndex, overviewRowBands.indices.contains(rowIndex) else { return false }
        let wsIndex = overviewRowBands[rowIndex].wsIndex
        guard workspaces.indices.contains(wsIndex) else { return false }
        let ws = workspaces[wsIndex]
        let screenFrame = usableScreen().frame
        let usableWidth = screenFrame.width - 2 * ColumnLayoutEngine.gap
        // How far the strip reaches, so panning cannot wander off into empty
        // space forever: half a screen past either end is as far as it goes.
        let placements = ColumnLayoutEngine.columnPlacements(columns: ws.columns,
                                                            usableWidth: usableWidth,
                                                            maximizedIndex: ws.maximizedIndex)
        let stripEnd = placements.map { $0.x + $0.width }.max() ?? usableWidth
        let before = ws.viewOffset
        let wanted = before - travel / zoom
        ws.viewOffset = min(max(wanted, -usableWidth / 2), max(0, stripEnd - usableWidth / 2))
        let moved = (before - ws.viewOffset) * zoom
        guard moved != 0 else { return true }   // at the end of the strip, but still ours
        overviewPanel.panCamera(wsIndex: wsIndex, by: moved, selected: overviewSelectedIndex)
        // The engine's own copy of the boxes drives navigation, so it travels
        // with the panel's.
        for i in overviewRowRanges[rowIndex] where overviewBoxes.indices.contains(i) {
            overviewBoxes[i].origin.x += moved
        }
        return true
    }

    // The selection IS the focus (that is what makes Mod+N land on the app you
    // are looking at), but activating an app is a system-wide event: the menu
    // bar swaps, the app wakes, and AX notifications come back at us. Doing it
    // on every arrow key of a burst means paying that for windows the user is
    // only passing OVER. Debounced: the ring moves instantly, the real focus
    // lands once the selection settles.
    func raiseOverviewSelection() {
        pendingOverviewRaise?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard self.isOverviewActive, self.overviewUsedPanel,
                      let w = self.overviewSelectedWindow() else { return }
                WindowMover.focus(w.axElement, pid: w.pid)
            }
        }
        pendingOverviewRaise = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func overviewSelectedWindow() -> ManagedWindow? {
        overviewSelection.indices.contains(overviewSelectedIndex) ? overviewSelection[overviewSelectedIndex].window : nil
    }

    // Point the model's focus (active workspace + column/window, or floating)
    // at the overview selection, synchronously and without animating. So any
    // keybinding that falls through then acts on the selected window - even
    // one on another workspace - as if it had been focused all along.
    func overviewFocusSelectedInModel() {
        guard let w = overviewSelectedWindow() else { return }
        print("overview bypass -> acting on \(w.title)")
        let leavingIndex = activeWorkspaceIndex
        focusInModel(w, activateWorkspace: true)
        // Writing activeWorkspaceIndex is a switch WITHOUT the switch: the
        // workspace being left keeps its windows on screen, and the reflow
        // that follows brings the entered one back from its parking spot on
        // top of them. Verified live: after a bypass across workspaces both
        // workspaces' windows sat at x=10, stacked.
        //
        // The index is still written synchronously (an animated switch would
        // raise isTransitioningWorkspace and the guards would swallow the very
        // action this bypass exists to deliver); what was missing is the
        // physical half - park what is leaving, place what arrives.
        guard activeWorkspaceIndex != leavingIndex else { return }
        previousWorkspaceIndex = leavingIndex
        lastWorkspaceSwitch = Date()
        // Parked SYNCHRONOUSLY, not through the animator: exitOverview runs
        // its own reflow one line later, and a reflow supersedes (cancels)
        // any animation in flight - so an animated park never landed and the
        // windows stayed on screen anyway. One granted write each, like every
        // other parking path.
        let screenFrame = usableScreen().frame
        for (i, ws) in workspaces.enumerated() where i != activeWorkspaceIndex {
            for w in ws.allWindows {
                guard let frame = WindowMover.currentFrame(w.axElement) else { continue }
                // The floating layer is never re-laid-out, so its return
                // address has to be recorded before it moves.
                w.stashedFrame = frame
                _ = ColumnLayoutEngine.applyFrame(w, target: parkedOffScreen(frame, screenFrame: screenFrame))
            }
        }
        // ...and PLACE WHAT ARRIVES, which is the half that was missing: the
        // comment above says "park what is leaving, place what arrives" and
        // only the first half was written. exitOverview's focusInModel then
        // saw the workspace already active and took the same-workspace
        // branch, which at most reflows - and reflow only writes
        // targetFrames(columns:), so an arriving FLOATING window stayed
        // invisible 1px from the edge. Permanently: the next workspace switch
        // out of here overwrites its stashedFrame with that parking spot.
        // Synchronous, for the same reason the parking above is.
        for w in workspace.floatingWindows {
            guard let home = w.stashedFrame else { continue }
            w.stashedFrame = nil
            _ = ColumnLayoutEngine.applyFrame(w, target: home)
        }
        for (w, frame) in ColumnLayoutEngine.targetFrames(columns: workspace.columns, in: screenFrame,
                                                          maximizedIndex: workspace.maximizedIndex,
                                                          viewOffset: workspace.viewOffset) {
            _ = ColumnLayoutEngine.applyFrame(w, target: frame)
        }
    }

    // Move the selected window's whole column one slot left/right within its
    // workspace, then rebuild the panel showing the new order (ring follows
    // the window). Real windows stay put until exit re-places them.
    func overviewMoveColumn(_ delta: Int) {
        guard let sel = overviewSelectedWindow() else { return }
        for ws in workspaces {
            guard let ci = ws.columns.firstIndex(where: { $0.windows.contains { $0 === sel } }) else { continue }
            let newIndex = ci + delta
            guard ws.columns.indices.contains(newIndex) else { return }
            ws.swapColumns(ci, newIndex)
            applyOverviewRearrangement()
            presentOverviewPanel(select: sel)
            return
        }
    }

    // Reorder the selected window within its column's vertical stack.
    func overviewMoveWindowInStack(_ delta: Int) {
        guard let sel = overviewSelectedWindow() else { return }
        for ws in workspaces {
            for col in ws.columns {
                guard let wi = col.windows.firstIndex(where: { $0 === sel }) else { continue }
                let newIdx = wi + delta
                guard col.windows.indices.contains(newIdx) else { return }
                col.swapWindows(wi, newIdx)
                col.focus(row: newIdx)
                applyOverviewRearrangement()
                presentOverviewPanel(select: sel)
                return
            }
        }
    }

    // move-column-to-workspace-up/down, relative to the SELECTED window's
    // workspace (not the model's active one - in overview the selection can
    // be on any row).
    func overviewMoveColumnToWorkspaceRelative(_ delta: Int) {
        guard let sel = overviewSelectedWindow() else { return }
        for (wi, ws) in workspaces.enumerated() where ws.columns.contains(where: { $0.windows.contains { $0 === sel } }) {
            overviewMoveColumnToWorkspace(wi + 1 + delta)
            return
        }
    }

    // Move the selected window's column to another workspace (its row jumps
    // in the panel). Real placement happens on exit.
    func overviewMoveColumnToWorkspace(_ number: Int) {
        guard let sel = overviewSelectedWindow() else { return }
        let targetIndex = min(max(0, number - 1), workspaces.count - 1)
        for (wi, ws) in workspaces.enumerated() {
            guard let ci = ws.columns.firstIndex(where: { $0.windows.contains { $0 === sel } }) else { continue }
            guard targetIndex != wi else { return }
            guard let column = ws.removeColumn(at: ci) else { return }
            workspaces[targetIndex].appendColumn(column)
            applyOverviewRearrangement()
            presentOverviewPanel(select: sel)
            return
        }
    }

    func overviewNavigate(_ dir: OverviewDirection) {
        guard overviewBoxes.indices.contains(overviewSelectedIndex) else { return }
        let cur = overviewBoxes[overviewSelectedIndex]
        var best: Int?
        var bestScore = CGFloat.greatestFiniteMagnitude
        for (i, b) in overviewBoxes.enumerated() where i != overviewSelectedIndex {
            let dx = b.midX - cur.midX
            let dy = b.midY - cur.midY
            // Primary axis must move the right way; the off-axis distance is
            // weighted so a box roughly in line is strongly preferred.
            let (primary, offAxis): (CGFloat, CGFloat)
            switch dir {
            case .left:  guard dx < -1 else { continue }; (primary, offAxis) = (-dx, abs(dy))
            case .right: guard dx > 1  else { continue }; (primary, offAxis) = (dx, abs(dy))
            case .up:    guard dy < -1 else { continue }; (primary, offAxis) = (-dy, abs(dx))
            case .down:  guard dy > 1  else { continue }; (primary, offAxis) = (dy, abs(dx))
            }
            let score = primary + offAxis * 2
            if score < bestScore { bestScore = score; best = i }
        }
        if let best { overviewSelectedIndex = best; overviewPanel.setSelectedIndex(best) }
        overviewFollowCamera()
        raiseOverviewSelection()
    }

    // First / last entry of the row the selection is currently in.
    func overviewSelectRowEdge(first: Bool) {
        guard let range = overviewRowRanges.first(where: { $0.contains(overviewSelectedIndex) }) else { return }
        let target = first ? range.lowerBound : range.upperBound - 1
        overviewSelectedIndex = target
        overviewPanel.setSelectedIndex(target)
        overviewFollowCamera()
        raiseOverviewSelection()
    }

    // Jump to the adjacent workspace row, landing on the entry nearest in x
    // to the current selection so vertical motion feels continuous.
    func overviewJumpRow(_ delta: Int) {
        guard let rowIdx = overviewRowRanges.firstIndex(where: { $0.contains(overviewSelectedIndex) }) else { return }
        let targetRow = rowIdx + delta
        guard overviewRowRanges.indices.contains(targetRow) else { return }
        let curX = overviewBoxes[overviewSelectedIndex].midX
        let target = overviewRowRanges[targetRow].min {
            abs(overviewBoxes[$0].midX - curX) < abs(overviewBoxes[$1].midX - curX)
        }
        if let target { overviewSelectedIndex = target; overviewPanel.setSelectedIndex(target) }
        overviewFollowCamera()
        raiseOverviewSelection()
    }

    // Enter/Return (or a click): close the overview and jump to the selected
    // window. Escape closes without changing focus (plain exitOverview).
    func overviewConfirmSelection() {
        guard isOverviewActive, overviewUsedPanel, overviewSelection.indices.contains(overviewSelectedIndex) else {
            exitOverview(); return
        }
        exitOverview(focusing: overviewSelection[overviewSelectedIndex].window)
    }

    // ---- mouse drag inside the overview (niri parity) ----
    // A plain press grabs the thumbnail under the cursor; a release without
    // real movement is a click (select+exit), a release after dragging drops
    // the window at the target position/workspace. The moving flavor (no
    // panel) keeps its old click-to-jump behavior.

    func overviewDragStart(_ point: CGPoint) {
        overviewDragDownPoint = point
        overviewDragIndex = nil
        guard overviewUsedPanel, let idx = overviewPanel.hitTest(point) else {
            print("overview press at (\(Int(point.x)),\(Int(point.y))): no card there")
            return
        }
        print("overview press at (\(Int(point.x)),\(Int(point.y))) -> card \(idx) (\(overviewSelection.indices.contains(idx) ? overviewSelection[idx].window.title : "?"))")
        overviewDragIndex = idx
        // By identity too: the index is a position into overviewSelection,
        // and that list is rebuilt mid-drag by design (an AX notification
        // from a window dying triggers refreshOverviewForDeadWindows). With
        // [A,B,C,D] and C grabbed, A dying makes index 2 resolve to D - and
        // the drop rearranged a window the user never touched.
        overviewDragWindow = overviewSelection.indices.contains(idx) ? overviewSelection[idx].window : nil
        overviewSelectedIndex = idx
        overviewPanel.setSelectedIndex(idx)
        raiseOverviewSelection()
        overviewPanel.beginCardDrag(idx)
    }

    func overviewDragMove(_ point: CGPoint) {
        guard overviewUsedPanel, overviewDragIndex != nil else { return }
        overviewPanel.dragCard(toAXPoint: point)
        // Live drop feedback: the hint region shows exactly where it lands.
        overviewPanel.setDropHint(overviewDropTarget(at: point)?.hint)
    }

    func overviewDragEnd(_ point: CGPoint) {
        defer { overviewDragDownPoint = nil; overviewDragIndex = nil; overviewDragWindow = nil }
        // Moving flavor: unchanged - a click jumps to the window under it.
        guard overviewUsedPanel else {
            exitOverview(focusing: anyManagedWindowAt(point))
            return
        }
        let moved = overviewDragDownPoint.map { hypot(point.x - $0.x, point.y - $0.y) } ?? 0
        overviewPanel.setDropHint(nil)
        guard let idx = overviewDragIndex else {
            // Pressed empty space: a click there closes the overview.
            if moved < 8 { exitOverview() }
            return
        }
        // The WINDOW that was grabbed, re-checked against the current model:
        // a window dying mid-drag rebuilds overviewSelection, so the index
        // this held predates that rebuild. Indexing it blind used to crash
        // the whole window manager; bounds-checking it stopped the crash but
        // left it pointing at whatever now sits in that slot.
        guard let dragged = overviewDragWindow,
              overviewSelection.contains(where: { $0.window === dragged }) else {
            overviewPanel.endCardDrag()
            presentOverviewPanel(select: overviewSelectedWindow())
            return
        }
        _ = idx
        overviewPanel.endCardDrag()
        // A press that barely moved is a click: select and jump.
        if moved < 8 {
            exitOverview(focusing: dragged)
            return
        }
        // A real drag: apply the drop under the cursor and keep the overview
        // open (niri rearranges in place).
        if let target = overviewDropTarget(at: point) {
            overviewApplyDrop(dragged: dragged, target.drop)
        } else {
            presentOverviewPanel(select: dragged)
        }
    }

    // Where a drop lands. Two kinds, mirroring niri's InsertPosition: a new
    // COLUMN beside a column (dragged tile expelled to its own column), or
    // INTO a column's vertical STACK relative to a tile.
    enum OverviewDrop {
        case newColumn(anchor: ManagedWindow, after: Bool)
        case intoStack(anchor: ManagedWindow, below: Bool)
    }

    // niri's hit test (ScrollingSpace::insert_position): NOT a zones scheme -
    // a nearest-gap contest. The nearest gap BETWEEN columns competes with
    // the nearest gap BETWEEN tiles in the hovered column; whichever gap edge
    // is closer to the cursor wins (ties -> new column). Returns the drop and
    // the landing footprint: a full-height column slab for new-column, a
    // column-wide band at the tile gap for stack.
    func overviewDropTarget(at point: CGPoint) -> (drop: OverviewDrop, hint: CGRect)? {
        guard !overviewRowRanges.isEmpty else { return nil }
        func band(_ r: Range<Int>) -> (minY: CGFloat, maxY: CGFloat) {
            let boxes = r.map { overviewBoxes[$0] }
            return (boxes.map { $0.minY }.min() ?? 0, boxes.map { $0.maxY }.max() ?? 0)
        }
        func vDist(_ y: CGFloat, _ b: (minY: CGFloat, maxY: CGFloat)) -> CGFloat {
            y < b.minY ? b.minY - y : (y > b.maxY ? y - b.maxY : 0)
        }
        // Nearest workspace row (forgiving off-row).
        guard let ri = overviewRowRanges.indices.min(by: { vDist(point.y, band(overviewRowRanges[$0])) < vDist(point.y, band(overviewRowRanges[$1])) }) else { return nil }
        let range = overviewRowRanges[ri]
        let (rowMinY, rowMaxY) = band(range)

        // Group the row's entries into columns (shared minX) sorted L->R,
        // each column's tiles sorted top->bottom.
        var byX: [Int: [Int]] = [:]
        for e in range { byX[Int((overviewBoxes[e].minX / 2).rounded()), default: []].append(e) }
        let cols = byX.keys.sorted().map { k in byX[k]!.sorted { overviewBoxes[$0].minY < overviewBoxes[$1].minY } }
        guard !cols.isEmpty else { return nil }
        let colBox = cols.map { c -> CGRect in
            let bs = c.map { overviewBoxes[$0] }
            let minX = bs.map { $0.minX }.min()!, maxX = bs.map { $0.maxX }.max()!
            return CGRect(x: minX, y: rowMinY, width: maxX - minX, height: rowMaxY - rowMinY)
        }

        // Nearest BETWEEN-columns gap (n+1 gaps: before first .. after last).
        var colGapX: [CGFloat] = [colBox[0].minX]
        for i in 1..<colBox.count { colGapX.append((colBox[i - 1].maxX + colBox[i].minX) / 2) }
        colGapX.append(colBox.last!.maxX)
        let (gapIdx, gapX) = colGapX.enumerated().min(by: { abs($0.element - point.x) < abs($1.element - point.x) })!
        let vertDist = abs(gapX - point.x)

        // Hovered column, and its nearest BETWEEN-tiles gap. A point PAST
        // the last column is not hovering it: the upper bound was missing, so
        // dropping in the empty space to the right of everything - where a
        // new column is what anyone would expect - measured a horizontal
        // distance of 0 against the last column and stacked into it instead.
        // insertPosition, the tiled twin of this contest, has both bounds.
        guard let colIdx = TilingEngine.hoveredColumn(colBox, x: point.x) else {
            let hint = CGRect(x: colGapX.last! - 7, y: rowMinY, width: 14, height: rowMaxY - rowMinY)
            let anchor = overviewSelection[cols[cols.count - 1][0]].window
            return (.newColumn(anchor: anchor, after: true), hint)
        }
        let tiles = cols[colIdx].map { overviewBoxes[$0] }
        var tileGapY: [CGFloat] = [tiles[0].minY]
        for j in 1..<tiles.count { tileGapY.append((tiles[j - 1].maxY + tiles[j].minY) / 2) }
        tileGapY.append(tiles.last!.maxY)
        let (tileIdx, tileY) = tileGapY.enumerated().min(by: { abs($0.element - point.y) < abs($1.element - point.y) })!
        let horDist = abs(tileY - point.y)

        // Slim insertion bars: full-length along the gap so you see WHERE,
        // thin across so they don't swamp the thumbnails.
        let thickness: CGFloat = 14
        if vertDist <= horDist {
            // New column: a tall thin bar at the column gap, full row height.
            let hint = CGRect(x: gapX - thickness / 2, y: rowMinY, width: thickness, height: rowMaxY - rowMinY)
            let anchor = gapIdx < cols.count ? overviewSelection[cols[gapIdx][0]].window : overviewSelection[cols[cols.count - 1][0]].window
            return (.newColumn(anchor: anchor, after: gapIdx >= cols.count), hint)
        } else {
            // Stack: a wide thin bar across the column at the tile gap.
            let cb = colBox[colIdx]
            let hint = CGRect(x: cb.minX, y: tileY - thickness / 2, width: cb.width, height: thickness)
            let anchor = tileIdx == 0 ? overviewSelection[cols[colIdx][0]].window : overviewSelection[cols[colIdx][tileIdx - 1]].window
            return (.intoStack(anchor: anchor, below: tileIdx != 0), hint)
        }
    }

    // Which column a point is over, or nil when it is past the ends. Pure so
    // the rule can be checked next to insertPosition's, which is the one it
    // has to agree with.
    static func hoveredColumn(_ boxes: [CGRect], x: CGFloat) -> Int? {
        boxes.indices.last { x >= boxes[$0].minX && x <= boxes[$0].maxX }
    }

    // Full (workspace, column, stack) location of a window.
    func overviewLocateWindow(_ w: ManagedWindow) -> (wsIndex: Int, colIndex: Int, winIndex: Int)? {
        for (wi, ws) in workspaces.enumerated() {
            for (ci, col) in ws.columns.enumerated() {
                if let wIdx = col.windows.firstIndex(where: { $0 === w }) { return (wi, ci, wIdx) }
            }
        }
        return nil
    }

    // Apply a drop: pull the dragged window out of its column (dropping the
    // column if it empties), then either splice it in as a new column beside
    // the anchor's column, or insert it into the anchor's column stack.
    // Anchors are resolved AFTER removal (by identity) so index shifts can't
    // corrupt the target.
    func overviewApplyDrop(dragged: ManagedWindow, _ drop: OverviewDrop) {
        let anchor: ManagedWindow
        switch drop {
        case .newColumn(let a, _), .intoStack(let a, _): anchor = a
        }
        guard anchor !== dragged, let from = overviewLocateWindow(dragged) else {
            presentOverviewPanel(select: dragged); return
        }
        let fromCol = workspaces[from.wsIndex].columns[from.colIndex]
        fromCol.removeWindow(at: from.winIndex)
        fromCol.cachedHeights = nil
        if fromCol.windows.isEmpty {
            _ = workspaces[from.wsIndex].removeColumn(at: from.colIndex)
        } else if fromCol.focusedWindowIndex >= fromCol.windows.count {
            fromCol.focus(row: fromCol.windows.count - 1)
        }
        switch drop {
        case .newColumn(_, let after):
            guard let a = overviewLocateWindow(anchor) else { presentOverviewPanel(select: dragged); return }
            let newCol = Column()
            newCol.setWindows([dragged])
            newCol.focus(row: 0)
            let idx = min(max(0, a.colIndex + (after ? 1 : 0)), workspaces[a.wsIndex].columns.count)
            workspaces[a.wsIndex].insertColumn(newCol, at: idx)
        case .intoStack(_, let below):
            guard let a = overviewLocateWindow(anchor) else { presentOverviewPanel(select: dragged); return }
            let col = workspaces[a.wsIndex].columns[a.colIndex]
            let at = below ? a.winIndex + 1 : a.winIndex
            col.insert(dragged, at: at)
            col.focus(row: at)
            col.cachedHeights = nil
        }
        // The columns of BOTH workspaces shifted: the source lost one (its
        // focusedIndex could now point past the end) and the target gained
        // one before or at its focused index. Without this the strip came
        // out of the overview focused on a column the user never picked, and
        // the camera scrolled to it.
        workspaces[from.wsIndex].clampFocus()
        if let landed = overviewLocateWindow(dragged) {
            workspaces[landed.wsIndex].focus(column: landed.colIndex)
            workspaces[landed.wsIndex].columns[landed.colIndex].focus(row: landed.winIndex)
            workspaces[landed.wsIndex].clampFocus()
        }
        applyOverviewRearrangement()
        presentOverviewPanel(select: dragged)
    }

    func toggleOverview() {
        isOverviewActive ? exitOverview() : enterOverview()
    }
}

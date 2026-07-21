import AppKit
import QuartzCore
import ApplicationServices

// The critically-damped spring animator (niri's animation sync group):
// animateFrames, plus the focus/model helpers the layout passes share.
extension TilingEngine {
    // The frame the layout believes this window has: the in-flight
    // animation's target if it has one, else its real frame. Rapid presses
    // must accumulate rather than sample a mid-spring position - this was
    // copy-pasted (with its comment) at five call sites.
    func settledFrame(of w: ManagedWindow) -> CGRect? {
        frameAnimationTargets.first { $0.window === w }?.frame
            ?? WindowMover.currentFrame(w.axElement)
    }

    // Where a window lives in the model.
    enum WindowLocation {
        case tiled(workspace: Int, column: Int, row: Int)
        case floating(workspace: Int, index: Int)
        var workspaceIndex: Int {
            switch self {
            case .tiled(let ws, _, _), .floating(let ws, _): return ws
            }
        }
    }

    func locate(_ w: ManagedWindow) -> WindowLocation? {
        for (wi, ws) in workspaces.enumerated() {
            if let ci = ws.columns.firstIndex(where: { $0.windows.contains { $0 === w } }),
               let ri = ws.columns[ci].windows.firstIndex(where: { $0 === w }) {
                return .tiled(workspace: wi, column: ci, row: ri)
            }
            if let fi = ws.floatingWindows.firstIndex(where: { $0 === w }) {
                return .floating(workspace: wi, index: fi)
            }
        }
        return nil
    }

    // Point the model's focus at `w`. `activateWorkspace` writes
    // activeWorkspaceIndex directly - only correct for callers that then
    // place every window themselves; the ones that animate a real switch
    // pass false and call focusWorkspace instead. Three near-identical
    // copies of this used to live in the overview alone, differing in
    // exactly that detail and in nothing that said so.
    @discardableResult
    func focusInModel(_ w: ManagedWindow, activateWorkspace: Bool) -> WindowLocation? {
        guard let location = locate(w) else { return nil }
        switch location {
        case .tiled(let wi, let ci, let ri):
            let ws = workspaces[wi]
            ws.isFloatingActive = false
            ws.focus(column: ci)
            ws.columns[ci].focus(row: ri)
            if activateWorkspace { activeWorkspaceIndex = wi }
        case .floating(let wi, let fi):
            let ws = workspaces[wi]
            ws.isFloatingActive = true
            ws.focus(floating: fi)
            if activateWorkspace { activeWorkspaceIndex = wi }
        }
        return location
    }

    // niri's animation names, resolved against the config. Defaults match
    // what nigiri shipped before the section existed: a critically damped
    // spring at 2x niri's 1100 (cross-app render lag shows in proportion to
    // how long windows spend in the air, so the transitions run stiffer
    // here than on a compositor).
    func animationCurve(named name: String) -> AnimationCurve {
        if animationsOff { return .off }
        if let configured = configuredAnimations[name] { return scaled(configured) }
        if name == "workspace-switch", let group = configuredAnimations["window-movement"] { return scaled(group) }
        return .spring(Spring(stiffness: 2200))
    }

    // niri's animations { slowdown }: stretches every duration.
    private func scaled(_ curve: AnimationCurve) -> AnimationCurve {
        guard animationSlowdown != 1 else { return curve }
        switch curve {
        case .off: return .off
        case .easing(let e):
            return .easing(Easing(durationMs: e.durationMs * animationSlowdown, curve: e.curve))
        case .spring(let s):
            // A slower spring is a softer one: stiffness scales with the
            // inverse square of time.
            return .spring(Spring(stiffness: s.omega0 * s.omega0 / (animationSlowdown * animationSlowdown),
                                  dampingRatio: s.dampingRatio, epsilon: s.epsilon))
        }
    }

    // niri keeps the floating space ABOVE the tiled one at all times
    // (workspace.rs chains floating after scrolling, so it renders last).
    // macOS only goes most of the way there, measured: AXRaise lifts a
    // window above every other app's, but never above the ACTIVE app's - so
    // focusing a tiled window sank every floating dialog under it, which is
    // how an installer ended up buried behind the terminal.
    //
    // What is reachable: after focusing a tiled window, re-raise the
    // floating layer, which then sits above everything except the focused
    // window itself. Raise, not activate: focus must not move.
    func raiseFloatingLayer(above focused: ManagedWindow) {
        guard !workspace.floatingWindows.isEmpty else { return }
        for w in workspace.floatingWindows where w !== focused {
            AXUIElementPerformAction(w.axElement, kAXRaiseAction as CFString)
        }
    }

    func describeFocus() -> String {
        focusedManagedWindow()?.title ?? "(none)"
    }

    func focusCurrentColumn() {
        guard let w = focusedManagedWindow() else { return }
        if currentlyFocusedWindow !== w {
            previouslyFocusedWindow = currentlyFocusedWindow
            currentlyFocusedWindow = w
        }
        lastSelfInitiatedActivation = Date()
        WindowMover.focus(w.axElement, pid: w.pid)
        raiseFloatingLayer(above: w)
        // niri's warp-mouse-to-focus (input section, opt-in): the cursor
        // rides along to the newly-focused window's center.
        if warpMouseEnabled, let frame = WindowMover.currentFrame(w.axElement) {
            CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
        }
        // Escaped inline: a title with quotes must not break the stream.
        let title = w.title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        msgServer.broadcast("{\"event\":\"focus\",\"title\":\"\(title)\",\"pid\":\(w.pid)}")
        emitWindowFocusChanged(w)
    }

    // Stops any in-flight animation and fires its pending completions with
    // cancelled=true. Every completion an animation was given fires exactly
    // once, cancelled or not - a chain waiting on one (the workspace-switch
    // curtain waiting to reveal) being silently orphaned is what once left
    // the curtain covering the whole screen until a hard restart. Balance:
    // a running animation holds exactly one beginApplyingLayout.
    func cancelFrameAnimation() {
        guard frameAnimationTimer != nil else { return }
        frameAnimationTimer?.cancel()
        frameAnimationTimer = nil
        frameAnimationTargets = []
        frameAnimationRawSettleHandlers = []
        frameAnimationWindowSettledHandlers = []
        let orphaned = frameAnimationCompletions
        frameAnimationCompletions = []
        watcher.endApplyingLayout()
        for c in orphaned { c(true) }
    }

    // Animates every window from its current frame to `targets` as a
    // critically-damped spring - matching the user's real niri config
    // (animations/glitch/animations.kdl: window-movement, window-resize and
    // horizontal-view-movement are all `spring damping-ratio=1.0
    // stiffness=1100`, the same "sync group"), not an arbitrary
    // fixed-duration ease curve. Position and size are treated as 4
    // independent springs per window (x/y/width/height), all sharing the
    // same clock, ticking at a high rate (~120Hz) until every one settles
    // within half a pixel rather than a fixed frame count. `completion`
    // always fires exactly once: cancelled=false once every window settled,
    // cancelled=true if a newer animation with different targets superseded
    // this one first.
    // `stiffness` defaults to the global spring (2x niri's 1100); a caller
    // can pass a stiffer one for a shorter flight - the workspace switch
    // does, because cross-app render lag (invisible to AX) shows itself in
    // proportion to how long windows spend in the air.
    // `trackRing: false` keeps the per-tick ring-follow off for this
    // animation: the ring rides the COMPUTED frames, which lead a slow
    // app's real rendering by several frames - over the long travel of a
    // workspace transition that reads as an empty ghost outline floating
    // where the window hasn't arrived yet (caught on screen recording).
    // The ring still lands at the focused target on settle.
    // `onWindowSettled` fires the moment EACH window reaches its target,
    // inside the same tick - for work that must not wait for the slowest
    // window (parking a landed strip, showing the ring on the focused
    // window). A window a settled-handler deliberately moves is left alone
    // by the deferred verification pass.
    // `verifyOnSettle: false` drops the deferred pass's re-write (its ring
    // correction and guard teardown still run) - for callers whose completion
    // immediately runs its OWN authoritative writing pass. Two memorizing
    // writes back-to-back are exactly the burst a heavy app silently drops:
    // the second one then read back as "refused" and memorized a
    // (requested, actual) pair that nothing ever invalidates, freezing that
    // window's height for the rest of the session.
    func animateFrames(_ targets: [(window: ManagedWindow, frame: CGRect)], animation: String = "window-movement", trackRing: Bool = true, verifyOnSettle: Bool = true, onWindowSettled: ((ManagedWindow) -> Void)? = nil, onRawSettle: (() -> Void)? = nil, completion: @escaping (_ cancelled: Bool) -> Void) {
        // A re-request with the SAME targets mid-animation (the app-activation
        // echo of focusCurrentColumn() re-running reflow moments after the
        // action that already started this animation) joins the in-flight
        // spring instead of restarting it from rest - a restart re-runs the
        // whole decay curve from zero, which reads as a visible mid-move hitch.
        let sameTargets = frameAnimationTimer != nil
            && frameAnimationTargets.count == targets.count
            && zip(frameAnimationTargets, targets).allSatisfy { $0.0 === $1.window && ColumnLayoutEngine.isClose($0.1, $1.frame, tolerance: 0.5) }
        if sameTargets {
            frameAnimationCompletions.append(completion)
            if let onRawSettle { frameAnimationRawSettleHandlers.append(onRawSettle) }
            if let onWindowSettled { frameAnimationWindowSettledHandlers.append(onWindowSettled) }
            return
        }
        cancelFrameAnimation()

        struct Anim { let window: ManagedWindow; let start: CGRect; let target: CGRect; var done: Bool; var lastWritten: CGRect; var translationOnly: Bool = false }
        var anims: [Anim] = targets.compactMap { entry in
            guard let start = WindowMover.currentFrame(entry.window.axElement) else { return nil }
            // Already in place - or sitting at the app's known clamped answer
            // to this exact frame (see ManagedWindow.lastRequestedFrame):
            // re-asking can't move it, so animating it just re-fights the
            // refusal - visibly, as off-screen columns "dancing" from their
            // clamped position toward an unreachable target on every pass.
            var done = ColumnLayoutEngine.isClose(start, entry.frame, tolerance: 0.5)
            if !done, let memo = entry.window.refusalMemo,
               ColumnLayoutEngine.isClose(entry.frame, memo.requested), ColumnLayoutEngine.isClose(start, memo.actual) {
                done = true
            }
            // A pure translation (workspace fall/rise, strip scroll) never
            // needs the size touched mid-flight - and a size write forces
            // the app to re-layout its whole content every tick, which is
            // what made translations render visibly less smoothly than the
            // window could actually move.
            let translationOnly = abs(start.width - entry.frame.width) <= 0.5 && abs(start.height - entry.frame.height) <= 0.5
            return Anim(window: entry.window, start: start, target: entry.frame, done: done, lastWritten: start, translationOnly: translationOnly)
        }
        guard anims.contains(where: { !$0.done }) else {
            updateRingImmediate()
            onRawSettle?()
            completion(false)
            return
        }
        // Slowest app first: each window's synchronous write blocks the tick
        // for everyone after it, and heavy apps also take the longest to
        // actually render what was written - leading with them gives their
        // pipeline the most time per tick, shrinking the visible phase lag
        // between heavy and light windows moving together.
        anims.sort { $0.window.axWriteLatencyEMA > $1.window.axWriteLatencyEMA }

        let curve = animationCurve(named: animation)
        // `off` lands everything on its target on the first tick.
        if case .off = curve {
            for i in anims.indices where !anims[i].done {
                anims[i].done = true
                anims[i].lastWritten = anims[i].target
                _ = ColumnLayoutEngine.applyFrame(anims[i].window, target: anims[i].target)
            }
        }
        // 120Hz, matching ProMotion: affordable now that pure translations
        // write only the position (see Anim.translationOnly) - a move is
        // cheap for the target app, unlike the size writes that force a
        // full content re-layout per tick and used to make anything above
        // 60Hz counterproductive. Resize-involving animations still write
        // full frames; the sub-pixel skip keeps their effective write rate
        // at whatever the app can absorb.
        let tickInterval: TimeInterval = 1.0 / 120.0
        // Wall-clock time, not tick-counting: a late tick (an app was slow
        // to service a write) must advance the spring by the REAL time that
        // passed, or every delayed tick silently stretches the animation's
        // total duration - the "it feels slow AND choppy" combination.
        let startTime = CACurrentMediaTime()
        // Spans the WHOLE animation, not just each individual tick's Set
        // call (see WindowWatcher.beginApplyingLayout's doc comment) -
        // notifications slipping through a per-tick-only guard window were
        // frequent enough to trigger competing full relayout() calls
        // mid-animation.
        watcher.beginApplyingLayout()
        frameAnimationGeneration += 1
        let generation = frameAnimationGeneration
        frameAnimationTargets = targets
        frameAnimationCompletions = [completion]
        frameAnimationRawSettleHandlers = onRawSettle.map { [$0] } ?? []
        frameAnimationWindowSettledHandlers = onWindowSettled.map { [$0] } ?? []
        let focusedWindow = focusedManagedWindow()
        // The handler block is @Sendable in the current SDK; it runs on the
        // main queue by construction, so MainActor.assumeIsolated states
        // that fact once instead of spreading Sendable annotations through
        // deliberately single-threaded code.
        // The windows this animation does NOT move cannot change while it
        // runs, so their frames (and minimized flags) are read once here
        // instead of on every 8.3ms tick - that was two AX round-trips per
        // window per tick, twice over, since coveringFloatingFrames read the
        // floating ones a second time. With one hung app those blocking
        // reads froze the animation itself.
        let staticDecorations = trackRing
            ? decorationCandidates(excluding: anims.map { $0.window } + (focusedWindow.map { [$0] } ?? []))
            : []
        let animatedFloating = Set(anims.indices.filter { i in
            workspace.floatingWindows.contains { $0 === anims[i].window }
        })
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + tickInterval, repeating: tickInterval)
        timer.setEventHandler { MainActor.assumeIsolated {
            // A tick already queued on the main queue when this animation
            // got superseded would otherwise run against the replacement's
            // shared state (and cancel the replacement's timer below).
            guard self.frameAnimationTimer === timer else { return }
            var stillMoving = false
            for i in anims.indices where !anims[i].done {
                let a = anims[i]
                // Critically damped spring at rest (v0=0): displacement(t) =
                // x0 * (1 + omega*t) * e^(-omega*t), decaying to 0 with no
                // overshoot - the exact shape niri's own critically-damped
                // (damping-ratio=1.0) springs produce. The time sample is
                // taken PER WINDOW, right before its own (blocking,
                // synchronous) write: a slow app's multi-millisecond write
                // delays every window after it in the tick, and computing
                // one shared instant up front handed those windows frames
                // that were already stale by the time they landed - windows
                // visibly out of phase with each other mid-flight.
                let elapsed = CACurrentMediaTime() - startTime
                let decay = curve.remainingFraction(at: elapsed)
                let dx = Double(a.start.origin.x - a.target.origin.x) * decay
                let dy = Double(a.start.origin.y - a.target.origin.y) * decay
                let dw = Double(a.start.width - a.target.width) * decay
                let dh = Double(a.start.height - a.target.height) * decay
                // 3px, not sub-pixel: the done-write snaps to the EXACT
                // target anyway, and the spring's sub-3px tail is ~80ms of
                // invisible-motion decay - a landed strip sat visibly at
                // the bottom for that whole tail before its park fired.
                if abs(dx) <= 3.0, abs(dy) <= 3.0, abs(dw) <= 3.0, abs(dh) <= 3.0 {
                    anims[i].done = true
                    anims[i].lastWritten = a.target
                }
                let justSettled = anims[i].done
                stillMoving = stillMoving || !anims[i].done
                let frame = anims[i].done ? a.target : CGRect(
                    x: a.target.origin.x + CGFloat(dx), y: a.target.origin.y + CGFloat(dy),
                    width: a.target.width + CGFloat(dw), height: a.target.height + CGFloat(dh))
                // Sub-pixel deltas aren't visible but still cost a full
                // synchronous IPC round-trip each - common in the spring's
                // long decaying tail.
                guard anims[i].done || !ColumnLayoutEngine.isClose(frame, a.lastWritten) else { continue }
                anims[i].lastWritten = frame
                do {
                    // Deliberately NOT applyFrame here: no (requested,
                    // actual) memorization mid-animation. A busy app
                    // (Finder, verified live) silently drops writes arriving
                    // in a burst while returning success - a read-back now
                    // would memorize that transient dropped state as the
                    // app's permanent refusal, freezing the window wherever
                    // the burst caught it. Truth is recorded once, below, at
                    // settle time, when an isolated write actually lands.
                    let writeStart = CACurrentMediaTime()
                    if a.translationOnly {
                        try WindowMover.setPosition(a.window.axElement, to: frame.origin,
                                                    assumeSettable: a.window.positionSettable)
                    } else {
                        try WindowMover.setFrame(a.window.axElement, to: frame)
                    }
                    a.window.axWriteLatencyEMA = a.window.axWriteLatencyEMA * 0.8 + (CACurrentMediaTime() - writeStart) * 0.2
                } catch let error as WindowMover.MoveError {
                    // Once per window, not 120 times a second: this used to
                    // put a string interpolation and a write(2) inside the
                    // tick loop for every refused write.
                    if !a.window.warnedUnwritable {
                        a.window.warnedUnwritable = true
                        print("[layout] skipping \(a.window.title): \(error.description)")
                    }
                } catch {}
                if justSettled {
                    for handler in self.frameAnimationWindowSettledHandlers { handler(a.window) }
                }
            }
            // Track the focused window with the frame we just computed for
            // it, instead of updateRingImmediate()'s AX read-back of it -
            // that's one more blocking IPC call per tick, and it reports the
            // app's redraw-lagged position rather than where the motion is.
            // fullscreenWindowRef is checked here too, not only in
            // updateRingImmediate: the animator paints the ring directly, so
            // a reflow running while a window is fullscreen would draw the
            // focused window's OLD column-sized ring across it.
            if trackRing, self.fullscreenWindowRef == nil,
               let fw = focusedWindow, let anim = anims.first(where: { $0.window === fw }) {
                self.ring.show(around: anim.lastWritten)
            }
            // The OTHER windows' decorations ride the same tick. They used to
            // be recomputed only at settle (updateRingImmediate's pass), so
            // while the focused window grew smoothly under its own ring,
            // every inactive window dragged its border behind it - most
            // visibly on the one being pushed off-screen, which reached the
            // edge with its frame still catching up. Same source of truth as
            // the ring: the frame just written, never an AX read-back.
            if trackRing, self.fullscreenWindowRef == nil {
                let screen = ScreenGeometry.primaryScreenVisibleFrameInAXSpace()
                // Windows NOT in this animation (floating ones, other
                // columns) keep their decoration: borders.update replaces the
                // whole set, so feeding it only the animated windows made
                // every other border blink off for the animation's duration.
                // The moving ones come from the frame just written, never an
                // AX read-back; the still ones from the hoisted snapshot.
                var candidates = staticDecorations
                for i in anims.indices where anims[i].window !== focusedWindow {
                    candidates.append(TilingEngine.DecorationCandidate(
                        frame: anims[i].lastWritten, minimized: false,
                        isFloating: animatedFloating.contains(i)))
                }
                // Same rule as the settle pass, and now literally the same
                // function: minimized windows excluded, and a floating window
                // is never counted as covering itself.
                self.borders.update(frames: TilingEngine.decoratedFrames(candidates, screen: screen))
            }
            if !stillMoving {
                timer.cancel()
                self.frameAnimationTimer = nil
                self.frameAnimationTargets = []
                let settled = self.frameAnimationCompletions
                self.frameAnimationCompletions = []
                // Land the ring on the TARGET we just wrote, not on an AX
                // read-back - the app's reported frame lags its redraw, so
                // reading it here dropped the ring onto a stale position for
                // a beat before the next event corrected it: a visible
                // jerk at the end of every otherwise-smooth animation.
                if self.fullscreenWindowRef != nil {
                    self.ring.hide()
                } else if let fw = focusedWindow, let anim = anims.first(where: { $0.window === fw }) {
                    self.ring.show(around: anim.target)
                } else {
                    self.updateRingImmediate()
                }
                let rawSettleHandlers = self.frameAnimationRawSettleHandlers
                self.frameAnimationRawSettleHandlers = []
                self.frameAnimationWindowSettledHandlers = []
                for h in rawSettleHandlers { h() }
                // The authoritative verification pass - one isolated write +
                // read-back per window, the only place an animation
                // memorizes (requested, actual) - runs after a short
                // breather, NOT immediately: right at the last tick the app
                // is still catching up on redraws, so an immediate read-back
                // reports a stale frame, and "correcting" it re-writes the
                // same target the window was already applying - a visible
                // double-apply shake on the focused window. The layout guard
                // stays up across the breather (endApplyingLayout below runs
                // after), suppressing the late redraw notifications too.
                let finishVerification = MainActorCallback {
                    let superseded = self.frameAnimationGeneration != generation
                    if !superseded {
                        // The ring at rest must frame the window's REAL
                        // frame, not the theoretical target: a clamped
                        // window (Discord's 800px min vs a 710px slot)
                        // rests wider than its target, and a ring drawn
                        // from the target sat visibly inset. Reads are
                        // trustworthy here, after the breather.
                        if self.fullscreenWindowRef == nil,
                           let fw = focusedWindow, anims.contains(where: { $0.window === fw }),
                           let actual = WindowMover.currentFrame(fw.axElement) {
                            self.ring.show(around: actual)
                        }
                        for a in anims where verifyOnSettle {
                            // A window sitting away from BOTH its target and
                            // the animator's last write was deliberately
                            // moved by a settled-handler (a landed strip
                            // parked into the corner) - re-asserting the
                            // stale target here made it flash back into
                            // view for a beat (the end-of-fall ghost).
                            if let current = WindowMover.currentFrame(a.window.axElement),
                               !ColumnLayoutEngine.isClose(current, a.target, tolerance: 8),
                               !ColumnLayoutEngine.isClose(current, a.lastWritten, tolerance: 8) {
                                continue
                            }
                            _ = ColumnLayoutEngine.applyFrame(a.window, target: a.target)
                        }
                    }
                    self.watcher.endApplyingLayout()
                    // If a newer animation started during the breather, IT
                    // owns the settle now - report these as superseded so
                    // e.g. reflow's completion doesn't write a stale layout
                    // against the newer animation's motion.
                    for c in settled { c(superseded) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    MainActor.assumeIsolated { finishVerification.run() }
                }
            }
        } }
        frameAnimationTimer = timer
        timer.resume()
    }

}

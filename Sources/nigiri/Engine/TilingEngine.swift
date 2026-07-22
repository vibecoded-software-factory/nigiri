import AppKit
import ApplicationServices
import QuartzCore
import ScreenCaptureKit
import Foundation
import CoreGraphics

// TilingEngine: the resident window-manager. This file holds the class's
// STATE (the workspace/column model, animation and overview bookkeeping)
// and its CORE - window collection, relayout, the spring animator, reflow,
// focus/ring helpers - plus start() (the one-time observer/hotkey/IPC/
// mouse/config wiring). The rest is split by responsibility into
// TilingEngine+{Actions,Workspaces,Overview,Input,Dispatch,IPC}.swift.
// runTilingSession() at the bottom is the entry point main.swift calls.
@MainActor
final class TilingEngine {
    let tileAll: Bool
    let watchedAppNames: [String]
    let neverTile: [String] = []
    // Prefix-matched, so the whole com.apple.bluetooth* family is covered by
    // one entry.
    // nonisolated: the desktop capture reads it off the main actor too.
    nonisolated static let systemUIAgentBundleIDs: [String] = [
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.systemuiserver",
        "com.apple.WindowManager",
        "com.apple.dock",
        "com.apple.screencaptureui",
        "com.apple.BluetoothUIServer",
        "com.apple.bluetooth",
        "com.apple.PowerChime",
        "com.apple.CoreLocationAgent",
        "com.apple.UserNotificationCenter",
        "com.apple.coreservices.uiagent",
    ]

    // Window rules come from the config file's window-rules section
    // (defaults reproduce the user's real niri rules: AWS VPN not
    // floating, Picture-in-Picture floating) - only what's implementable
    // via AX translates from niri: per-app opacity, corner-radius etc. are
    // compositor rendering with no AX equivalent.
    // CFHash(element) -> the managed windows carrying it. Rebuilt once per
    // relayout: the model passes used to rebuild
    // `columns.flatMap + floatingWindows` for EVERY scanned element x every
    // workspace, which is O(N x windows x workspaces) with an allocation in
    // the innermost loop.
    var elementIndex: [UInt: [ManagedWindow]] = [:]
    func rebuildElementIndex() {
        elementIndex.removeAll(keepingCapacity: true)
        for ws in allWorkspaces {
            for w in ws.allWindows {
                elementIndex[CFHash(w.axElement), default: []].append(w)
            }
        }
    }
    func knownWindow(for element: AXUIElement) -> ManagedWindow? {
        elementIndex[CFHash(element)]?.first { CFEqual($0.axElement, element) }
    }

    var windowRules: [NigiriConfig.Rule] = []
    // The config currently in force (see applyConfig).
    var lastAppliedConfig: NigiriConfig?
    // When nigiri started, for at-startup.
    let startedAt = Date()

    // niri's rule resolution, which is a MERGE, not a pick: every matching
    // rule is applied in order and each field is overwritten by the last
    // rule that sets it. nigiri used to take the last matching rule whole,
    // so a general rule setting one field and a specific one setting
    // another could not combine - and a rule with no `match` at all never
    // applied, which is exactly how niri writes "for every window".
    func matchingWindowRule(
        appName: String, bundleID: String? = nil, title: String,
        isActive: Bool = false, isFloating: Bool = false
    ) -> NigiriConfig.Rule? {
        let atStartup = Date().timeIntervalSince(startedAt) < 5
        func hits(_ matchers: [NigiriConfig.Matcher]) -> Bool {
            matchers.contains {
                $0.matches(
                    app: appName, bundleID: bundleID, title: title,
                    isActive: isActive, isFloating: isFloating, atStartup: atStartup)
            }
        }
        var merged: NigiriConfig.Rule?
        for rule in windowRules {
            // No `match` line means "every window"; any `exclude` hit vetoes.
            guard rule.matchers.isEmpty || hits(rule.matchers) else { continue }
            guard !hits(rule.excludes) else { continue }
            if merged == nil { merged = NigiriConfig.Rule() }
            if let v = rule.openFloating { merged?.openFloating = v }
            if let v = rule.defaultWidthProportion { merged?.defaultWidthProportion = v }
            if let v = rule.openOnWorkspace { merged?.openOnWorkspace = v }
            if let v = rule.openOnWorkspaceName { merged?.openOnWorkspaceName = v }
            if rule.openMaximized { merged?.openMaximized = true }
            if rule.openFullscreen { merged?.openFullscreen = true }
            if let v = rule.defaultFloatingPosition { merged?.defaultFloatingPosition = v }
            if let v = rule.minWidthPx { merged?.minWidthPx = v }
            if let v = rule.maxWidthPx { merged?.maxWidthPx = v }
        }
        return merged
    }

    // Multi-monitor: each Output owns its own workspace stack and active index,
    // and exactly one output is focused. `workspaces`, `activeWorkspaceIndex`,
    // `previousWorkspaceIndex` and `workspace` are PROXIES onto the focused
    // output, so every existing "workspace.columns"/"workspaces[i]"/etc. call
    // site below keeps working completely unchanged - it now operates on the
    // focused output. `outputs` is never empty (a display disappearing migrates
    // its workspaces rather than dropping the last one), so the proxies are
    // always valid. syncOutputs() reconciles it against NSScreen.screens.
    var outputs: [Output] = [
        Output(
            displayID: NSScreen.screens.first.flatMap(Output.displayID(of:)) ?? 0,
            name: TilingEngine.outputName(NSScreen.screens.first) ?? "primary",
            screen: NSScreen.screens.first)
    ]
    var focusedOutputIndex = 0
    var focusedOutput: Output { outputs[min(max(0, focusedOutputIndex), outputs.count - 1)] }

    var workspaces: [Workspace] {
        get { focusedOutput.workspaces }
        set { focusedOutput.workspaces = newValue }
    }
    var activeWorkspaceIndex: Int {
        get { focusedOutput.activeWorkspaceIndex }
        set { focusedOutput.activeWorkspaceIndex = newValue }
    }
    // Where the last focus-workspace jump CAME from (niri's
    // focus-workspace-previous) - updated inside focusWorkspace.
    var previousWorkspaceIndex: Int {
        get { focusedOutput.previousWorkspaceIndex }
        set { focusedOutput.previousWorkspaceIndex = newValue }
    }
    var workspace: Workspace { focusedOutput.activeWorkspace }

    // Every workspace across every output. The known-window index, the purge
    // and the title/refuse passes must span this - NOT just the focused
    // output's `workspaces` - or a window living on another monitor looks
    // brand-new every relayout and gets yanked onto the focused output.
    var allWorkspaces: [Workspace] { outputs.flatMap { $0.workspaces } }

    let watcher = WindowWatcher()
    let ring = FocusRingOverlay()
    let borders = InactiveDecorations()
    let tabIndicators = TabIndicators()
    // Declared here (early) because broadcast hooks live inside functions
    // defined long before the server is configured and started below.
    let msgServer = MsgServer()
    // One animation at a time; a newer one with different targets supersedes
    // the current one. Targets and completions travel together so a
    // superseded animation's completions can be fired as cancelled instead
    // of silently dropped, and an identical re-request can join the
    // in-flight animation instead of restarting it (see animateFrames).
    var frameAnimationTimer: DispatchSourceTimer?
    // Slow sweep that drops a reserved zone whose owner died without a terminate
    // notification (see start()). Retains the engine, which is fine: it is the
    // process's single long-lived instance.
    var strutPruneTimer: Timer?
    var frameAnimationTargets: [(window: ManagedWindow, frame: CGRect)] = []
    var frameAnimationCompletions: [(_ cancelled: Bool) -> Void] = []
    // Fire at the settle tick itself, BEFORE the verification breather -
    // for work that must not linger (hiding freshly-landed windows) and
    // doesn't need accurate read-backs. Dropped, not fired, when the
    // animation is superseded (settle never happened).
    var frameAnimationRawSettleHandlers: [() -> Void] = []
    // Per-window settle observers, shared state like the completions above
    // so a re-request that JOINS an in-flight identical animation (see
    // animateFrames' sameTargets) contributes its handler instead of having
    // it silently dropped - a joined workspace switch would otherwise never
    // park its landed strips. Dropped on supersede, like the raw handlers.
    var frameAnimationWindowSettledHandlers: [(ManagedWindow) -> Void] = []
    // Bumped whenever a new animation actually starts - a settled
    // animation's deferred verification pass (see animateFrames) uses it to
    // detect that a newer animation took over during the settle breather.
    var frameAnimationGeneration = 0
    // True while the workspace-switch animation is in flight. Layout
    // invalidations arriving during it are deferred (see scheduleRelayout):
    // a relayout would fold the mid-stash windows into the wrong workspace.
    // The flag cannot stick: animateFrames guarantees the completion that
    // clears it always fires, cancelled or not. The generation counter keeps
    // a SUPERSEDED switch's (cancelled) completion from clearing the flag
    // that now belongs to the newer switch still in flight.
    var isTransitioningWorkspace = false
    var workspaceTransitionGeneration = 0
    // Coalesced relayout bookkeeping (see scheduleRelayout).
    var pendingRelayout: DispatchWorkItem?
    var relayoutQueuedDuringTransition = false

    // niri's semantics: focusing a window switches to its workspace - here,
    // the user clicking a stashed app in the Dock or Cmd+Tabbing to it.
    // Deliberately NOT part of syncFocusIndex: right after switching to an
    // empty workspace macOS activates SOME app on its own (something always
    // has to be frontmost), and reacting to that residual focus bounced
    // straight back to the workspace just left. Only an app activation
    // clearly past the switch itself (grace period) counts as the user
    // asking for that window.
    var lastWorkspaceSwitch = Date.distantPast
    // When nigiri last raised a window itself (see the activation echo in
    // onAppActivated).
    var lastSelfInitiatedActivation = Date.distantPast
    // niri's focus-window-previous: the window focused before the current
    // one, wherever it lives.
    var previouslyFocusedWindow: ManagedWindow?
    var currentlyFocusedWindow: ManagedWindow?
    // input { warp-mouse-to-focus } - read by focusCurrentColumn, set by
    // applyConfig. Declared with the early state because the focus path
    // runs long before the config block executes.
    var warpMouseEnabled = false
    // Three-finger swipe -> action map (config gestures section), read by
    // the trackpad recognizer's callback; updated on every reload.
    let trackpadGestures = TrackpadGestures()
    // Owners of the two long-lived dispatch sources start() used to keep
    // alive with a stray `_ =` on a local.
    // Mod+drag in progress. One optional, so "no drag" is unrepresentable
    // as a half-set of four separate locals - which is what it was, hidden
    // inside start() where nothing else could see or cancel it.
    struct ModDragState {
        let window: ManagedWindow
        let isFloating: Bool
        let startFrame: CGRect
        let startPoint: CGPoint
    }
    var modDrag: ModDragState?
    let configWatcher = ConfigWatcher(path: NigiriConfig.path)
    let commandPipe = CommandPipe()
    var gestureSwipeLeft = "focus-column-right"
    var gestureSwipeRight = "focus-column-left"
    var gestureSwipeUp = "focus-workspace-up"
    var gestureSwipeDown = "focus-workspace-down"
    // Mod+wheel bindings (key "mod[-ctrl][-shift]-<dir>" -> action line),
    // read by the mouse tap's scroll handler; updated on every reload.
    var wheelActions: [String: String] = [:]
    var mouseActions: [String: String] = [:]
    var gestureFourLeft = ""
    var gestureFourRight = ""
    var gestureFourUp = ""
    var gestureFourDown = ""
    // Magic Mouse swipes, by finger count.
    var gestureMouseOne: [SwipeDirection: String] = [:]
    var gestureMouseTwo: [SwipeDirection: String] = [:]
    // The config's animations section (see animationCurve(named:)).
    var configuredAnimations: [String: AnimationCurve] = [:]
    var animationsOff = false
    var animationSlowdown: Double = 1
    // Per-bind last-fire time for niri's cooldown-ms (keyed by combo).
    var bindLastFire: [String: Date] = [:]
    // input { focus-follows-mouse } state - the global mouse monitor and its throttle.
    var mouseMonitor: Any?
    var lastMouseFocusTick = Date.distantPast
    // Overview mode (see enterOverview below) - declared early: the
    // relayout/activation guards read it long before it's ever set.
    var isOverviewActive = false
    // layout { empty-workspace-above-first }: a spare empty workspace is
    // kept before the first, so focus-workspace-up from the top has
    // somewhere to go.
    var emptyWorkspaceAboveFirst = false
    // Which column the camera was following last time: center-focused-column
    // "on-overflow" needs the column focus came FROM to decide whether the
    // two still fit together.
    var lastReflowedColumnIndex: Int?
    // The insert position the hint is currently showing, so the drop uses
    // exactly what the user saw rather than re-deciding at mouse-up.
    var pendingDrop: ColumnLayoutEngine.InsertPosition?
    // id -> title as last broadcast over the event stream, for the diff that
    // produces WindowOpenedOrChanged / WindowClosed.
    var lastBroadcastWindows: [UInt64: String] = [:]
    // screenshot-path, with strftime placeholders, for the screenshot actions.
    var screenshotPath = "~/Desktop/Screenshot %Y-%m-%d %H.%M.%S.png"
    let overviewChrome = OverviewChrome()
    let overviewPanel = OverviewPanel()
    let insertHint = InsertHintOverlay()
    let ghosts = WindowGhost()
    // niri's `window-close` needs the closing window's texture, and macOS only
    // tells us a window is gone once it IS gone. So the FOCUSED window keeps a
    // recent snapshot ready: closing one is overwhelmingly Cmd+W on the window
    // you are looking at. Keyed by window id, with the frame it was taken at.
    // Refreshed at most once per interval, and only for the focused window -
    // capturing every managed window continuously would be a screenshot of the
    // whole session, forever, for an animation that lasts 300ms.
    var closeSnapshots: [UInt64: (buffer: CVPixelBuffer, frame: CGRect)] = [:]
    var lastCloseSnapshot = Date.distantPast
    // Windows whose ghost already played, so the purge does not play it a
    // second time for the same close: the destroyed notification is the fast
    // path, the purge the fallback for an app that died whole (a dying
    // process never sends per-window destroyed notifications).
    var ghostedWindows: Set<UInt64> = []
    // The last desktop capture that actually came back. The capture is async
    // and the panel is shown immediately, so a fresh one is never ready for
    // the frame the overview opens on - which is why the backdrop flashed
    // grey (the flat backdrop-color, reported live). Keeping the previous one
    // means only the very first overview of a session can ever show it, and a
    // capture that fails outright leaves the last good picture up instead of
    // dropping to grey.
    var lastDesktopImage: CGImage?

    // Ask for the desktop behind everything, through the Screen Recording
    // grant the thumbnails already need. Reading the wallpaper FILE instead
    // asks for a separate permission, and a custom wallpaper app paints a
    // window anyway - the file would not be what is on screen.
    func refreshDesktopBackdrop() {
        guard #available(macOS 14.0, *), WindowCapture.hasPermission() else { return }
        WindowCapture.captureDesktop(size: usableScreen().frame.size) { image in
            if let image { self.lastDesktopImage = image }
            self.overviewPanel.setBackdrop(image ?? self.lastDesktopImage)
        }
    }
    // Last thumbnail captured per window id. The panel is rebuilt on every
    // model change while the overview is up (that is what makes it a live
    // mirror), and a rebuilt card starts with no image: without this every
    // rebuild blanked EVERY card until the captures came back - the blink.
    // The last still frame per window, retained: the surface must stay valid
    // while a layer shows it, and it is what re-seeds a rebuilt card without
    // keeping a second copy of every frame as a CGImage.
    var overviewStills: [UInt64: CVPixelBuffer] = [:]
    // Shape of the panel as last built (window ids + card boxes): a rebuild
    // only happens when this changes.
    var overviewPanelSignature: [UInt64] = []
    // Bare Escape closes the overview. RegisterEventHotKey is out: it
    // reports success for a no-modifier key yet macOS never delivers the
    // press (Escape is system-reserved - verified live, "registered: true"
    // but dead). So a short-lived NSEvent global monitor instead, alive
    // ONLY while the overview is up: it observes (never consumes, can't -
    // global monitors are read-only) on the Accessibility grant we already
    // hold, no Input Monitoring, no keyboard tap. Same mechanism as
    // focus-follows-mouse. Return/Enter DOES register (and consuming it
    // matters, so it does not leak into the app underneath); Escape rides
    // the monitor.
    var overviewKeyMonitor: Any?
    // The active workspace's fullscreen window (see Workspace).
    var fullscreenWindowRef: ManagedWindow? {
        get { workspace.fullscreenWindow }
        set { workspace.fullscreenWindow = newValue }
    }
    // Its own listener (own Carbon signature) so unregistering the
    // overview's Escape/Enter never touches the config's binds.
    let overviewKeys = HotkeyListener()
    var overviewKeysRegistered = false
    // Panel mode's flattened entry order (matches OverviewPanel.hitTest
    // indices) and which flavor the current overview session used.
    var overviewSelection: [(window: ManagedWindow, wsIndex: Int)] = []
    var overviewUsedPanel = false
    // Live navigation inside the panel overview: the selected entry (index
    // into overviewSelection / the panel's boxes) that the selection ring
    // frames, plus each entry's AX-space box for spatial neighbor search and
    // the index range of each workspace row for whole-row jumps.
    var overviewSelectedIndex = 0
    var overviewBoxes: [CGRect] = []
    var overviewRowRanges: [Range<Int>] = []
    // Each row's workspace and its clip band, so a scroll can pan the
    // workspace the cursor is actually over.
    var overviewRowBands: [(wsIndex: Int, band: CGRect)] = []
    // Set when an in-overview keyboard move reordered the model. Panel mode
    // leaves real windows in place, so on exit we must physically re-place
    // them to match the new arrangement (a lightweight focus-only exit would
    // leave model and screen desynced).
    // Mouse drag inside the overview: where the press started and which
    // entry it grabbed (nil = pressed empty space). Distinguishes a click
    // (select) from a drag (rearrange) on release.
    var overviewDragDownPoint: CGPoint?
    var overviewDragIndex: Int?
    // Periodic thumbnail refresh so live content (a playing video, a
    // running log) keeps moving in the panel. A capture-and-redraw every
    // ~0.8s, NOT a live SCStream per window (N streams at 30-60fps to look
    // at for two seconds is not worth the GPU) - the sweet spot between
    // "frozen screenshot" and "melts the machine".
    // The live-thumbnail loop. NOT a repeating Timer: the panel is rebuilt on
    // every relayout while the overview is up, and each rebuild used to
    // restart the timer AND fire a capture batch of its own - so the periodic
    // tick often never arrived at all (its countdown kept being reset) while
    // redundant batches piled up. A self-rescheduling loop cannot be reset by
    // anything but itself.
    // The window ids the resolved map was built with, and the generation of
    // the panel SHAPE (which changes on every rebuild, unlike the capture
    // loop's own generation, which only changes when the loop starts/stops).
    var overviewCaptureIDs: [UInt64] = []
    // Live per-window streams for the overview's cards (macOS 14+).
    private var _streamer: Any?
    @available(macOS 14.0, *)
    var streamer: WindowStreamer {
        if let existing = _streamer as? WindowStreamer { return existing }
        let created = WindowStreamer()
        created.onFrame = { [weak self] id, surface, buffer in
            self?.overviewPanel.setThumbnail(surface, forWindow: id)
            self?.streamedWindows.insert(id)
            // Kept for the next overview: the streams are torn down on exit,
            // so without this every card would open on its icon again.
            self?.overviewStills[id] = buffer
        }
        created.onStopped = { [weak self] id in
            // Back to stills for that window: a stream stops when the window
            // closes, when it is minimized (Apple pauses those), or when the
            // Screen Recording grant lapses - macOS re-asks monthly since
            // Sequoia, and then every stream dies at once.
            self?.streamedWindows.remove(id)
        }
        _streamer = created
        return created
    }
    // Windows that have delivered at least one live frame. The still-capture
    // loop skips these entirely.
    var streamedWindows: Set<UInt64> = []

    // The window being dragged in the overview, by identity.
    var overviewDragWindow: ManagedWindow?
    var overviewShapeGeneration = 0
    // Bumped to abandon the loop in flight (exit, or a new overview session).
    var overviewCaptureGeneration = 0
    // The debounced "make the selection the real focus" work item.
    var pendingOverviewRaise: DispatchWorkItem?
    // The resolved AX->SCWindow mapping the loop shoots, refreshed only when
    // the panel is rebuilt.
    var overviewCaptureWindows: [Int: SCWindow] = [:]
    func autoSwitchToFocusedWindowWorkspace(focusedElement: AXUIElement) {
        guard Date().timeIntervalSince(lastWorkspaceSwitch) > 1.5, !isOverviewActive else { return }
        if let wsIndex = workspaces.firstIndex(where: { ws in
            ws !== workspace && ws.allWindows.contains { CFEqual($0.axElement, focusedElement) }
        }) {
            print("auto-switch: focused window lives on workspace \(wsIndex + 1)")
            focusWorkspace(wsIndex + 1)
        }
    }

    // Latched per broken-state episode (reset if writes recover) so the
    // dead-grant diagnosis prints once, not on every relayout pass.
    var warnedDeadAccessibilityGrant = false

    // The single source of truth for "which window is focused right now" -
    // a column's windows[0] isn't necessarily it once a column can hold a
    // vertical stack (see Column.focusedWindowIndex).
    func focusedManagedWindow() -> ManagedWindow? {
        if workspace.isFloatingActive {
            guard workspace.floatingWindows.indices.contains(workspace.floatingFocusedIndex) else {
                return workspace.floatingWindows.first
            }
            return workspace.floatingWindows[workspace.floatingFocusedIndex]
        }
        guard workspace.columns.indices.contains(workspace.focusedIndex) else { return nil }
        let column = workspace.columns[workspace.focusedIndex]
        guard column.windows.indices.contains(column.focusedWindowIndex) else { return column.windows.first }
        return column.windows[column.focusedWindowIndex]
    }

    // The two prologs almost every tiled-only action shared, written once:
    // "the tiled group holds focus AND the focused column index is valid"
    // (and, one level deeper, "its focused stack slot is valid"). An action
    // that gets nil simply doesn't apply right now - identical to the
    // guard-and-return each call site previously spelled out by hand,
    // where a copy could (and did) drift out of sync with the rest.
    func focusedColumn() -> Column? {
        guard !workspace.isFloatingActive, workspace.columns.indices.contains(workspace.focusedIndex) else {
            return nil
        }
        return workspace.columns[workspace.focusedIndex]
    }
    func focusedStackWindow() -> ManagedWindow? {
        guard let column = focusedColumn(), column.windows.indices.contains(column.focusedWindowIndex) else {
            return nil
        }
        return column.windows[column.focusedWindowIndex]
    }

    // Screen frame + the usable strip width every layout computation derives
    // from it - previously recomputed as a two-line ritual at seven sites.
    // Screen-edge zones reserved over the IPC socket, keyed by the id the
    // requester passed so each can set and clear its own. Subtracted from the
    // usable area below - the single chokepoint every layout pass reads, so
    // honoring a reservation is just this one inset. See ScreenStruts.
    var reservedStruts: [String: ScreenStrut] = [:]

    func usableScreen() -> (frame: CGRect, usableWidth: CGFloat) {
        usableScreen(for: focusedOutput)
    }

    // The working area of a specific output (its raw visible frame minus any
    // reserved struts). The no-argument form above is the focused output, which
    // is what every existing single-output caller wants.
    func usableScreen(for output: Output) -> (frame: CGRect, usableWidth: CGFloat) {
        let frame = ScreenGeometry.workingAreaInAXSpace(
            for: output.screen, reserved: Array(reservedStruts.values))
        return (frame, frame.width - 2 * ColumnLayoutEngine.gap)
    }

    // The raw (pre-strut) visible frame of the focused output, in AX space -
    // the multi-monitor replacement for callers that used to reach straight for
    // the primary screen to park/stash windows on "the current" monitor.
    func currentRawScreenFrame() -> CGRect {
        ScreenGeometry.visibleFrameInAXSpace(for: focusedOutput.screen)
    }

    // Drop every zone a now-dead process reserved. Returns whether anything
    // was removed, so the caller only pays a relayout when it must. This is
    // what keeps a crashed or killed panel from leaving the layout shrunk
    // forever - the compositor releases the reservation when the client dies,
    // the same as a Wayland compositor dropping a layer surface's exclusive
    // zone on disconnect.
    @discardableResult
    func dropStruts(ownerPid pid: pid_t) -> Bool {
        let before = reservedStruts.count
        reservedStruts = reservedStruts.filter { $0.value.ownerPid != pid }
        return reservedStruts.count != before
    }

    // The backstop for dropStruts(ownerPid:): drop any reservation whose owning
    // process no longer exists. didTerminateApplicationNotification is the fast
    // path, but it is not guaranteed - a launchd helper that crash-loops, or a
    // process macOS never reported as an app, can die without it ever firing,
    // and a stuck strut then shrinks the layout with nothing on screen to
    // explain it (seen live). kill(pid, 0) probes existence without signalling:
    // ESRCH means the process is gone; EPERM means it is alive but ours to
    // signal it is not, so keep it. Returns whether anything was removed.
    @discardableResult
    func pruneDeadStruts() -> Bool {
        let before = reservedStruts.count
        reservedStruts = reservedStruts.filter { _, strut in
            guard let pid = strut.ownerPid else { return true }  // no owner: kept until clear-zone
            if kill(pid, 0) == 0 { return true }
            return errno != ESRCH
        }
        return reservedStruts.count != before
    }

    // A strut changes the usable HEIGHT, and the per-column height cache holds
    // absolute pixel heights that sum to the old usable height - so it must be
    // dropped or the layout reuses stale heights and only the window ORIGIN
    // moves, leaving windows the same height and hanging off the reserved edge
    // (measured: a top strut moved y but left h, so the window overran the
    // bottom). Membership changes already drop this cache; a usable-area change
    // is the other case that has to. Then relayout recomputes against the new
    // area, on every workspace so a switch doesn't reveal a stale one.
    func applyStrutChange() {
        for ws in workspaces {
            for column in ws.columns { column.cachedHeights = nil }
        }
        relayout()
    }

    // Frames of the windows floating ABOVE the tiled layer (dialogs,
    // installers, panels). A tiled window's decoration must not be painted
    // across one of them: our decorations are always-on-top overlays, so the
    // border of a window completely hidden behind a dialog still drew a
    // stripe over it.
    func coveringFloatingFrames() -> [CGRect] {
        workspace.floatingWindows.compactMap { WindowMover.currentFrame($0.axElement) }
    }

    // The decoration lives in the gap AROUND the window, so what matters is
    // whether that band is under a floating window.
    static func decorationIsCovered(_ frame: CGRect, by floating: [CGRect]) -> Bool {
        floating.contains { $0.intersects(frame.insetBy(dx: -focusRingWidth, dy: -focusRingWidth)) }
    }

    // One window as the decoration pass sees it. `depth` is its place in the
    // real WindowServer stack, 0 being frontmost, nil when it could not be
    // matched (see WindowStacking.depths).
    struct DecorationCandidate {
        let frame: CGRect
        let minimized: Bool
        let depth: Int?
    }

    // Which candidates get a border. Pure, and the SINGLE rule: the animator
    // tick used to carry its own copy that had drifted - it had lost the
    // minimized check, so a minimized window's slot kept a ghost border that
    // survived the settle. And a floating window was tested against a list
    // that INCLUDED itself, so every unfocused dialog covered itself and
    // never got one at all.
    //
    // Coverage is decided by the REAL stack, not by which windows float. The
    // old rule dropped a border when any floating window overlapped it, on
    // the assumption that floating means in front - true in niri, false on
    // macOS, where activating an app raises all of its windows. It therefore
    // missed the mirror case entirely: a floating window sitting BEHIND a
    // tiled one still got its border painted across it, outlining a window
    // nobody could see (Calculator behind Font Book, reported live).
    // The occluders are the WHOLE on-screen stack, not the candidate list.
    // Testing candidates against each other was the first attempt and it
    // failed on the exact case it was written for: the FOCUSED window is
    // excluded from the candidates (it wears the ring instead of a border),
    // so Calculator floating behind a focused Font Book was compared against
    // a set that did not contain the window covering it, and kept its border.
    // Asking the stack instead also covers windows nigiri does not manage at
    // all - another app's dialog over a tiled window hides its border too.
    static func decoratedFrames(
        _ candidates: [DecorationCandidate], occluders: [WindowStacking.Entry], screen: CGRect
    ) -> [CGRect] {
        candidates.compactMap { candidate in
            guard !candidate.minimized, decorationIsVisible(candidate.frame, on: screen) else { return nil }
            // An unmatched window keeps its border: drawing one that should
            // not be there is cosmetic, while dropping one for a window the
            // user is looking at reads as nigiri having lost the window.
            guard let depth = candidate.depth, depth <= occluders.count else { return candidate.frame }
            let band = candidate.frame.insetBy(dx: -focusRingWidth, dy: -focusRingWidth)
            // prefix(depth) is everything strictly in front of it, so the
            // candidate is never tested against itself.
            let covered = occluders.prefix(depth).contains { $0.frame.intersects(band) }
            return covered ? nil : candidate.frame
        }
    }

    // A window's decoration inputs BEFORE its depth: pid and frame (to match
    // it against the stack) and whether it is minimized. This is the expensive
    // half - two AX round-trips per window - so the animator reads it ONCE for
    // the windows it is not moving, then recomputes only their depths per tick
    // (a cheap WindowServer read) as the real z-order changes underneath.
    struct DecorationInfo {
        let pid: pid_t
        let frame: CGRect
        let minimized: Bool
    }

    func decorationInfo(excluding excluded: [ManagedWindow]) -> [DecorationInfo] {
        workspace.allWindows.compactMap { w in
            guard !excluded.contains(where: { $0 === w }), let frame = WindowMover.currentFrame(w.axElement)
            else { return nil }
            let minimized: Bool? = AX.attribute(w.axElement, kAXMinimizedAttribute as String)
            return DecorationInfo(pid: w.pid, frame: frame, minimized: minimized == true)
        }
    }

    // Info plus depth, resolved against a stack snapshot. Pure, so the depth
    // matching stays covered by the selftest.
    static func candidates(
        from info: [DecorationInfo], in stacking: [WindowStacking.Entry]
    )
        -> [DecorationCandidate]
    {
        let depths = WindowStacking.depths(of: info.map { (pid: $0.pid, frame: $0.frame) }, in: stacking)
        return info.enumerated().map { index, entry in
            DecorationCandidate(frame: entry.frame, minimized: entry.minimized, depth: depths[index])
        }
    }

    func decorationCandidates(
        excluding excluded: [ManagedWindow], stacking: [WindowStacking.Entry]? = nil
    ) -> [DecorationCandidate] {
        Self.candidates(
            from: decorationInfo(excluding: excluded), in: stacking ?? WindowStacking.onScreen())
    }

    func updateInactiveDecorations() {
        let focused = focusedManagedWindow()
        let screenFrame = usableScreen().frame
        let stacking = WindowStacking.onScreen()
        borders.update(
            frames: Self.decoratedFrames(
                decorationCandidates(excluding: focused.map { [$0] } ?? [], stacking: stacking),
                occluders: stacking, screen: screenFrame))
    }

    // Tab indicators for every visible tabbed column, refreshed with the
    // borders. The strip is placed relative to the COLUMN's full frame -
    // niri draws it outside the column, so the column keeps its whole
    // height (see TabBars).
    func updateTabIndicators() {
        var bars: [(frame: CGRect, count: Int, active: Int)] = []
        let (screenFrame, _) = usableScreen()
        // Through columnGeometry, like every other consumer: this was the
        // THIRD hand-rolled derivation of the same column->screen projection
        // and the only grantedX outside LayoutEngine.swift, which is exactly
        // how layout() and targetFrames drifted apart once already.
        let geometry = ColumnLayoutEngine.columnGeometry(
            columns: workspace.columns, in: screenFrame,
            maximizedIndex: workspace.maximizedIndex,
            viewOffset: workspace.viewOffset)
        for geo in geometry where geo.column.isTabbed {
            // Same rule as the borders: a column scrolled out of view would
            // otherwise paint its indicator across the visible windows.
            guard
                Self.decorationIsVisible(
                    CGRect(x: geo.x, y: screenFrame.minY, width: geo.width, height: 1),
                    on: screenFrame)
            else { continue }
            bars.append(
                (
                    frame: CGRect(x: geo.x, y: geo.y, width: geo.width, height: geo.height),
                    count: geo.column.windows.count,
                    active: min(geo.column.focusedWindowIndex, geo.column.windows.count - 1)
                ))
        }
        tabIndicators.update(bars: bars)
    }

    // Decorations are separate always-on-top windows, so a window that is
    // mostly off-screen (and therefore behind whatever is on screen) would
    // still paint its border over the visible windows. Decorate only what is
    // actually visible.
    static func decorationIsVisible(_ frame: CGRect, on screenFrame: CGRect) -> Bool {
        let visible = min(screenFrame.maxX, frame.maxX) - max(screenFrame.minX, frame.minX)
        return visible >= frame.width * 0.9
    }

    func updateRingImmediate() {
        // The overview owns the whole screen and paints its OWN selection
        // ring around the selected card - niri does the same: in its
        // zoomed-out view the focus ring is part of that view, never a
        // second one floating over it. Every chrome path funnels through
        // here, so this one guard covers them all; without it the real ring
        // came back mid-overview (the Dock/system-UI poll re-showing it, and
        // any focus change now that the selection genuinely activates its
        // window), reading as two windows selected at once and a ring
        // fighting the panel for z-order.
        guard !isOverviewActive else {
            ring.hide()
            borders.hideAll()
            tabIndicators.hideAll()
            return
        }
        // niri hides the focus ring on a fullscreened window (tile.rs:
        // "Hide the focus ring when maximized/fullscreened"), and here it
        // matters twice over: our decorations are separate always-on-top
        // windows, so every OTHER window's border would otherwise paint
        // across the fullscreen window covering them.
        if fullscreenWindowRef != nil {
            ring.hide()
            borders.hideAll()
            tabIndicators.hideAll()
            return
        }
        defer { updateInactiveDecorations(); updateTabIndicators() }
        guard let w = focusedManagedWindow() else {
            ring.hide()
            return
        }
        // A minimized window still exists in the AX tree and still reports a
        // frame (its pre-minimize one), so without this check the ring just
        // sat on that stale position instead of disappearing.
        let minimized: Bool? = AX.attribute(w.axElement, kAXMinimizedAttribute as String)
        guard minimized != true, let frame = WindowMover.currentFrame(w.axElement) else {
            ring.hide()
            return
        }
        ring.show(around: frame)
        snapshotForClose(w, frame: frame)
    }

    // Keep a fresh-enough texture of the focused window for its close
    // animation. Piggybacks on the ring update - which already runs on every
    // focus change and every layout pass - rather than adding a timer of its
    // own, and skips the capture if the last one is still recent.
    func snapshotForClose(_ w: ManagedWindow, frame: CGRect) {
        guard #available(macOS 14.0, *), WindowCapture.hasPermission() else { return }
        if case .off = animationCurve(named: "window-close") { return }
        guard Date().timeIntervalSince(lastCloseSnapshot) > 1.5 else { return }
        lastCloseSnapshot = Date()
        let id = w.id
        WindowCapture.resolve([(pid: w.pid, title: w.title, frame: frame)]) { resolved in
            WindowCapture.capture(resolved: resolved) { buffers in
                guard let buffer = buffers[0] else { return }
                // ~100ms passed between asking and answering, and the window
                // may have closed inside it: the purge already dropped its
                // entry, so writing now creates one nobody will ever read and
                // nobody can prune - a full-size CGImage retained until the
                // agent restarts.
                guard !self.ghostedWindows.contains(id),
                    self.workspaces.contains(where: { $0.allWindows.contains { $0.id == id } })
                else { return }
                self.closeSnapshots[id] = (buffer, frame)
            }
        }
    }

    // A focus change fires two separate paths in quick succession - the
    // lightweight didActivateApplicationNotification handler and, moments
    // later, a full relayout() from AXObserver's own focus-changed
    // notification - each repositioning the ring on its own. Applied back to
    // back, that reads as a visible little double-jump/shake instead of one
    // clean move. Debounce: cancel any pending update and schedule a fresh
    // one, so only the LAST call in a short burst actually moves the ring.
    var pendingRingUpdate: DispatchWorkItem?
    func updateRing() {
        pendingRingUpdate?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { self.updateRingImmediate() } }
        pendingRingUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    // How a discovered AX window participates in the layout: tiled into the
    // column strip, or managed as a floating dialog (never repositioned, but
    // fully part of the model: focus tracking, the focus ring, floating
    // navigation, per-workspace bookkeeping - a dialog just sitting outside
    // the system entirely was incoherent: no ring when focused, invisible
    // to every action).
    enum CollectedKind { case tiled, dialog }

    // Binds come from the config file (see NigiriConfig) - registration
    // happens in applyConfig, re-run on every live reload. The DEFAULT
    // config keeps letter keys unbound: letter combos collide with app
    // menu equivalents (Hide Others, Fullscreen) - a user editing their
    // config owns that tradeoff.
    let listener = HotkeyListener()

    var hotkeyOverlay = HotkeyOverlay(bindings: [])

    // The full action vocabulary as ONE list: performAction's switch
    // answers to exactly these names (plus niri's aliases, normalized in
    // applyConfig), and the overlay derives its unbound rows from whatever
    // the config leaves out - there is no second list to keep in sync.
    let actionCatalog = [
        "focus-column-left", "focus-column-right", "focus-window-up", "focus-window-down",
        "focus-column-first", "focus-column-last", "focus-workspace", "focus-workspace-previous",
        "focus-column-right-or-first", "focus-column-left-or-last", "focus-column",
        "focus-window-top", "focus-window-bottom", "focus-window-down-or-top",
        "focus-window-up-or-bottom", "focus-window-previous", "focus-floating", "focus-tiling",
        "swap-window-left", "swap-window-right", "move-column-to-index", "move-workspace-to-index",
        "move-window-to-workspace", "move-window-to-workspace-up", "move-window-to-workspace-down",
        "move-window-to-floating", "move-window-to-tiling", "center-window", "set-column-display",
        "set-workspace-name", "unset-workspace-name", "open-overview", "close-overview",
        "switch-preset-window-height-back", "switch-preset-window-width-back",
        "focus-workspace-up", "focus-workspace-down",
        "move-column-left", "move-column-right", "move-window-up", "move-window-down",
        "move-column-to-first", "move-column-to-last", "move-column-to-workspace",
        "move-column-to-workspace-up", "move-column-to-workspace-down",
        "move-workspace-up", "move-workspace-down",
        "consume-or-expel-window-left", "consume-or-expel-window-right",
        "consume-window-into-column", "expel-window-from-column",
        "maximize-column", "maximize-window-to-edges", "fullscreen-window",
        "toggle-windowed-fullscreen", "native-fullscreen", "close-window",
        "switch-preset-column-width", "switch-preset-column-width-back", "switch-preset-window-height",
        "switch-preset-window-width",
        "set-column-width", "set-window-height", "reset-window-height",
        "expand-column-to-available-width", "resize-edge",
        "center-column", "center-visible-columns",
        "toggle-window-floating", "switch-focus-between-floating-and-tiling",
        "toggle-column-tabbed-display", "toggle-overview",
        "screenshot", "screenshot-screen", "screenshot-window",
        "show-hotkey-overlay", "spawn", "quit",
    ]
    let actionAliases = [
        "consume-or-expel-left": "consume-or-expel-window-left",
        "consume-or-expel-right": "consume-or-expel-window-right",
        "spawn-sh": "spawn",
    ]

    init() {
        let rest = Array(cliArgs.dropFirst())
        let appsArg = parseFlag("--apps", in: rest) ?? "TextEdit,Preview"
        tileAll = appsArg.trimmingCharacters(in: .whitespaces).lowercased() == "all"
        watchedAppNames = appsArg.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // Dying with workspaces stashed used to leave every inactive window as
    // an invisible 1px line in the bottom-right corner until nigiri was
    // relaunched (which re-adopts everything into workspace 1) - the user's
    // windows just "disappeared" with the manager. Restore each parked
    // window to where it was stashed FROM before exiting. Only windows
    // actually sitting at the corner are touched: anything mid-screen
    // (crash recovery already moved it, the user dragged it) is left alone.
    func restoreStashedWindows() {
        let screenFrame = ScreenGeometry.primaryScreenVisibleFrameInAXSpace()
        for (i, ws) in workspaces.enumerated() where i != activeWorkspaceIndex {
            for w in ws.allWindows {
                guard let current = WindowMover.currentFrame(w.axElement),
                    current.origin.x >= screenFrame.maxX - 2
                else { continue }
                // Stash always precedes a park, so stashedFrame is normally
                // set; the fallback keeps even a hole in that invariant
                // from stranding a window invisibly.
                let fallback = CGRect(
                    x: screenFrame.midX - current.width / 2,
                    y: screenFrame.midY - current.height / 2,
                    width: current.width, height: current.height)
                try? WindowMover.setFrame(w.axElement, to: w.stashedFrame ?? fallback)
            }
        }
    }

    func start() -> Never {
        AX.setGlobalMessagingTimeout()
        watcher.onLayoutInvalidated = { self.scheduleRelayout() }
        watcher.onWindowDestroyed = { element in
            guard let window = self.knownWindow(for: element) else { return }
            self.playCloseGhost(window)
        }
        // Mission Control dismissed -> the ring re-frames the focused window.
        // The overlay only knows it hid itself; where the ring belongs is this
        // model's knowledge.
        ring.onSystemUIDismissed = { self.updateRing() }
        ring.onSystemUIShown = {
            self.borders.hideAll(); self.tabIndicators.hideAll()
        }

        // Lightweight path for cross-app focus changes: just re-point the ring,
        // without collectCurrentAXWindows()'s full re-scan of every app's
        // windows or a full relayout pass - that's what made following focus
        // feel slow, on top of being inconsistent. Skipped mid workspace
        // transition: focusCurrentColumn() inside the transition chain fires
        // this notification itself, and reacting to that echo here would start
        // a reflow competing with the transition's own.
        // The observer blocks are @Sendable in the current SDK; everything they
        // call is main-thread state (and queue: .main guarantees they run
        // there), so MainActor.assumeIsolated states that fact to the compiler
        // instead of scattering Sendable annotations over a single-threaded app.
        let onAppActivated = MainActorCallback {
            guard !self.isTransitioningWorkspace, !self.isOverviewActive else { return }
            // OUR OWN activation, echoed back: focusCurrentColumn calls
            // NSRunningApplication.activate, macOS notifies, and this handler
            // used to run a SECOND full reflow for a focus change nigiri had
            // just made itself - two reflows (and ~40 extra AX reads at ten
            // windows) per focus keypress. The ring still re-lands.
            if Date().timeIntervalSince(self.lastSelfInitiatedActivation) < 0.15 {
                self.updateRing()
                return
            }
            // Read once, use twice: the auto-switch and the focus sync both
            // wanted the frontmost app's focused window.
            guard let frontApp = NSWorkspace.shared.frontmostApplication,
                let focusedElement = AX.focusedWindow(ofPid: frontApp.processIdentifier)
            else { return }
            self.autoSwitchToFocusedWindowWorkspace(focusedElement: focusedElement)
            guard !self.isTransitioningWorkspace else { return }  // the auto-switch may have just started one
            self.syncFocusIndex(focusedElement: focusedElement)
            // Right after a workspace switch the strip was JUST laid out where
            // it belongs, and macOS's focus can transiently land on whichever
            // app happened to unhide/activate last - scrolling the strip to
            // chase that opinion glided every window sideways moments after
            // the vertical rise. Track the ring, but no strip scroll until the
            // dust settles; any real focus change re-scrolls via later events.
            guard Date().timeIntervalSince(self.lastWorkspaceSwitch) > 1.0 else {
                self.updateRing()
                return
            }
            // Clicking or Cmd-Tabbing to a window directly can change
            // focusedIndex outside any of our own hotkeys - keep the strip
            // scrolled to match. reflow() keeps the ring in sync itself, on
            // every animation step.
            self.reflow()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { onAppActivated.run() }
        }

        // Plugging in a display, changing resolution, or toggling the Dock's
        // auto-hide moves the working area under the whole layout - and every
        // cached answer was measured against the old one. Nothing observed this
        // before: the layout stayed wrong until an unrelated AX event.
        let onScreenChange = MainActorCallback {
            ColumnLayoutEngine.newEpoch()
            print("[layout] screen change: re-measuring everything")
            self.relayout()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { onScreenChange.run() }
        }

        // Switching input source moves every latin key to a different physical
        // position, so the hotkeys registered for the old layout now sit under
        // the wrong keys. Re-resolve and re-register (a no-op when the config
        // pins binds-layout).
        // NOT `?? NigiriConfig()`: a default config is destructive (it clears the
        // window rules, the workspace names, every wheel/mouse action, and
        // unregisters all 74 binds without registering any), and this fires on an
        // event nobody controls - switching keyboard layout while the file is
        // momentarily unreadable (stow re-linking, an editor between unlink and
        // rename) would leave the session with no shortcuts at all, and it does
        // not self-heal: this observer notifies on the layout change, not on the
        // file coming back. Same policy the config watcher already applies.
        let reloadForLayout = MainActorCallback {
            guard let config = NigiriConfig.load() else {
                print("[config] unreadable on keyboard layout change - keeping the previous one")
                // Re-apply what is already in force: the only thing this path
                // actually needs is the keycodes resolved against the new layout.
                if let current = self.lastAppliedConfig { self.applyConfig(current, initial: false) }
                return
            }
            self.applyConfig(config, initial: false)
        }
        DistributedNotificationCenter.default().addObserver(
            // The Carbon constant is not exposed to Swift; this is its value.
            forName: NSNotification.Name("AppleSelectedInputSourcesChangedNotification"),
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { reloadForLayout.run() }
        }

        // AXObserver only watches PIDs we already know about (registered the
        // first time collectCurrentAXWindows() sees that app) - a brand-new app
        // launching has no observer yet, so its windows appearing wouldn't
        // trigger anything without this. Same idea on quit, in case a whole
        // process dying doesn't fire per-window destroyed notifications.
        let requestRelayout = MainActorCallback { self.scheduleRelayout() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { _ in
            // The notification can fire before the app has actually created its
            // first window in the AX tree - a short delay avoids scanning too
            // early and missing it (a later relayout would still pick it up on
            // the next real event, but there's no reason not to get it right away).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated { requestRelayout.run() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { note in
            // The notification names the dead app - drop its AXObserver (a run
            // loop source serving a dead connection) instead of leaking one per
            // quit app for our whole lifetime.
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            MainActor.assumeIsolated {
                if let pid {
                    self.watcher.unwatch(pid: pid)
                    // Release any screen-edge zone this app had reserved: it is
                    // gone and can no longer clear its own (a killed or crashed
                    // panel). applyStrutChange re-tiles against the freed area;
                    // requestRelayout below is the general case for its windows.
                    if self.dropStruts(ownerPid: pid) { self.applyStrutChange() }
                }
                requestRelayout.run()
            }
        }

        // Backstop for a reservation whose owner died without the terminate
        // notification firing - a non-app process, or a helper that crash-looped
        // past it. didTerminate above is the fast path; this slow sweep catches
        // the rest so the layout can never stay shrunk with nothing on screen to
        // explain it. It only probes pids while a zone is actually reserved.
        strutPruneTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.reservedStruts.isEmpty else { return }
                if self.pruneDeadStruts() { self.applyStrutChange() }
            }
        }

        NigiriConfig.writeDefaultIfMissing()
        let initialConfig = NigiriConfig.load() ?? NigiriConfig()
        applyConfig(initialConfig, initial: true)
        // Startup-only, never re-run on reload (niri's semantics: these are
        // session companions, not supervised services).
        for command in initialConfig.spawnAtStartup { spawnShell(command) }

        // Live reload (see ConfigWatcher: editors save atomically, which kills
        // the watched inode, so it re-arms itself).
        configWatcher.start {
            if let config = NigiriConfig.load() {
                self.applyConfig(config, initial: false)
            } else {
                print("[config] reload failed - keeping the previous configuration")
            }
        }

        // niri's request shapes and the older bare-word ones, one entry point.
        msgServer.onRequest = { request in self.handleMsgRequest(request) }
        msgServer.onSubscribe = { self.currentStateLines() }
        msgServer.start()

        // ---- Mod+drag (mouse) ----

        let mouseDrag = MouseDragController()

        // A plain press during overview is claimed here (at mouse-down) so the
        // release can tell a click (select+exit) from a drag (rearrange). See
        // overviewDragStart/Move/End.
        mouseDrag.onPlainClick = { point in
            guard self.isOverviewActive else { return false }
            self.overviewDragStart(point)
            return true
        }
        mouseDrag.onPlainDrag = { point in self.overviewDragMove(point) }
        mouseDrag.onScroll = { dx, dy, point in self.overviewPan(dx: dx, dy: dy, at: point) }
        mouseDrag.onPlainUp = { point in self.overviewDragEnd(point) }
        mouseDrag.onBegin = { point, _ in
            guard !self.isTransitioningWorkspace, !self.isOverviewActive, self.modDrag == nil,
                let (w, floating) = self.managedWindowAt(point),
                let frame = WindowMover.currentFrame(w.axElement)
            else { return false }
            self.modDrag = ModDragState(window: w, isFloating: floating, startFrame: frame, startPoint: point)
            // Model focus follows the grab (niri does the same on drag start).
            if floating {
                if let idx = self.workspace.floatingWindows.firstIndex(where: { $0 === w }) {
                    self.workspace.isFloatingActive = true
                    self.workspace.focus(floating: idx)
                }
            } else if let ci = self.workspace.columns.firstIndex(where: { $0.windows.contains { $0 === w } })
            {
                self.workspace.isFloatingActive = false
                self.workspace.focus(column: ci)
                if let ri = self.workspace.columns[ci].windows.firstIndex(where: { $0 === w }) {
                    self.workspace.columns[ci].focus(row: ri)
                }
            }
            // Our own per-event writes must not feed the relayout loop.
            self.watcher.beginApplyingLayout()
            return true
        }
        mouseDrag.onMove = { point in
            guard let drag = self.modDrag else { return }
            let w = drag.window
            let dx = point.x - drag.startPoint.x
            let dy = point.y - drag.startPoint.y
            if mouseDrag.phase == .move {
                try? WindowMover.setPosition(
                    w.axElement,
                    to: CGPoint(x: drag.startFrame.origin.x + dx, y: drag.startFrame.origin.y + dy))
                // niri's insert hint: paint where this window would land.
                if !drag.isFloating, let preview = self.insertPreview(at: point) {
                    self.pendingDrop = preview.position
                    self.insertHint.show(preview.hint)
                }
            } else {
                try? WindowMover.setFrame(
                    w.axElement,
                    to: CGRect(
                        x: drag.startFrame.origin.x, y: drag.startFrame.origin.y,
                        width: max(50, drag.startFrame.width + dx),
                        height: max(50, drag.startFrame.height + dy)))
            }
        }
        mouseDrag.onEnd = { point in
            self.insertHint.hide()
            defer { self.pendingDrop = nil }
            guard let drag = self.modDrag else { return }
            let w = drag.window
            self.modDrag = nil
            self.watcher.endApplyingLayout()
            if drag.isFloating {
                // Floating: wherever the drag left it is where it lives.
                self.updateRingImmediate()
                print("mod-drag: floating \(mouseDrag.phase == .move ? "moved" : "resized") (\(w.title))")
                return
            }
            if mouseDrag.phase == .move {
                // niri's interactive move: the WINDOW lands where the hint said -
                // a new column between two, or a slot inside a column's stack.
                // The settle reflow snaps the ghost into place.
                let position = self.pendingDrop ?? self.insertPreview(at: point)?.position
                if let position, self.dropWindow(w, at: position) {
                    print("mod-drag: \(position)")
                }
                self.reflow()
                self.focusCurrentColumn()
            } else {
                // Resize drop: the dragged size becomes the model's truth -
                // width as the column's proportion (clamped like every other
                // width writer), height as a manual stack height.
                if let current = WindowMover.currentFrame(w.axElement),
                    let columnIndex = self.workspace.columns.firstIndex(where: {
                        $0.windows.contains { $0 === w }
                    })
                {
                    let column = self.workspace.columns[columnIndex]
                    let usableWidth = self.usableScreen().usableWidth
                    if usableWidth > 0 {
                        column.widthProportion = self.clampedProportion(
                            ColumnLayoutEngine.proportion(forWidth: current.width, usableWidth: usableWidth),
                            for: column)
                        column.presetWidthIndex = nil
                    }
                    if column.windows.count > 1, !column.isTabbed {
                        w.manualHeightPx = current.height
                        column.cachedHeights = nil
                    }
                    print(
                        "mod-drag: resized to \(Int(current.width))px (\(String(format: "%.0f%%", column.widthProportion * 100)))"
                    )
                }
                self.reflow()
            }
        }
        // Mod+wheel (mouse) -> the config-mapped action (read live).
        mouseDrag.onWheel = { key in
            guard let action = self.wheelActions[key], !action.isEmpty else {
                // Logged like the button path: a wheel bind that never fires is
                // otherwise indistinguishable from a wheel that reports nothing.
                debugLog("[mouse] wheel \(key) has no bind")
                return
            }
            self.performAction(action)
        }
        // Mouse buttons bound in the config (niri's Mod+MouseMiddle and
        // friends). Returns whether the press was claimed, so an unbound button
        // still reaches the app under the cursor.
        mouseDrag.onButton = { key in
            guard let action = self.mouseActions[key], !action.isEmpty else {
                // Logged unbound too: a mouse whose side buttons report a
                // different number than expected is otherwise indistinguishable
                // from a bind that never fired.
                debugLog("[mouse] \(key) has no bind")
                return false
            }
            print("[mouse] \(key) -> \(action)")
            self.performAction(action)
            return true
        }
        mouseDrag.start()

        // Three-finger swipes -> the config-mapped actions (read live, so a
        // reload re-maps them without restarting the recognizer).
        trackpadGestures.onSwipe = { direction, fingers, isMouse in
            // A Magic Mouse is a multitouch surface too, but with room for one
            // or two fingers - its swipes are their own bindings, empty by
            // default (one-finger vertical on that surface IS scrolling).
            let table: [SwipeDirection: String]
            if isMouse {
                table = fingers == 1 ? self.gestureMouseOne : self.gestureMouseTwo
            } else if fingers == 4 {
                table = [
                    .left: self.gestureFourLeft, .right: self.gestureFourRight,
                    .up: self.gestureFourUp, .down: self.gestureFourDown,
                ]
            } else {
                table = [
                    .left: self.gestureSwipeLeft, .right: self.gestureSwipeRight,
                    .up: self.gestureSwipeUp, .down: self.gestureSwipeDown,
                ]
            }
            if let action = table[direction], !action.isEmpty { self.performAction(action) }
        }
        trackpadGestures.start()

        if !listener.start() {
            print(
                "warning: failed to install the Carbon hotkey event handler - tiling will work, but hotkeys won't."
            )
        } else {
            print(
                "hotkeys active: \(initialConfig.binds.count) binds from \(NigiriConfig.path) (Cmd+Opt+/ = overlay)"
            )
        }

        // niri-style control channel (niri's is `niri msg action ...` over its
        // IPC socket): a FIFO other processes can write action lines into -
        // `echo "focus-workspace 2" > /tmp/nigiri-cmd`. Every action goes
        // through the exact same functions the hotkeys call, so anything
        // driven from here exercises the real paths. Also the only way to
        // drive nigiri programmatically (tests, scripts, a future `nigiri msg`
        // subcommand) without simulating keyboard input, which this project
        // never does.
        commandPipe.start { line in
            // Same router as the config binds: one vocabulary, two input
            // surfaces.
            self.performAction(line)
        }

        // DispatchSource, not signal(2) handlers: restoring windows needs AX
        // calls, which are nowhere near async-signal-safe - the source delivers
        // on the main queue, in normal execution context. SIG_IGN is required
        // for the source to receive the signal at all.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let terminationSignalSources = [SIGINT, SIGTERM].map { sig in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    self.restoreStashedWindows()
                    // SIGINT is a person pressing Ctrl+C: exit 0, stay quit (same as
                    // the `quit` action). SIGTERM is the SYSTEM killing us - macOS
                    // terminates an app whose Screen Recording / Accessibility
                    // permission just changed, and that arrived as a clean exit 0,
                    // so the KeepAlive-on-failure agent stayed dead: nigiri simply
                    // vanished the moment its checkbox was ticked, tiling and all
                    // (hit live). A distinct non-zero code makes launchd bring it
                    // straight back. launchd's own bootout also sends SIGTERM, but
                    // that REMOVES the job first, so there is nothing to respawn.
                    exit(sig == SIGTERM ? 75 : 0)
                }
            }
            source.resume()
            return source
        }
        _ = terminationSignalSources

        print(
            "nigiri tile: watching \(tileAll ? "all apps" : watchedAppNames.joined(separator: ", ")). Ctrl+C to quit."
        )
        relayout()
        // Warm the overview's backdrop, so even the FIRST overview of the session
        // opens onto the desktop instead of the flat colour. Deferred: the Screen
        // Recording grant is checked inside, and at this point in start() the
        // permission preflight may not have run yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.refreshDesktopBackdrop() }
        runResidentApp()
    }
}

func runTilingSession() -> Never {
    TilingEngine().start()
}

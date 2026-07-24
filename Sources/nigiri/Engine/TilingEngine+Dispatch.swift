import AppKit
import Foundation

// The action router (performAction) shared by binds/FIFO/socket, and applyConfig (live reload).
extension TilingEngine {
    // THE action router: every input surface - config binds, the FIFO -
    // dispatches through here, so the bindable vocabulary and the
    // scriptable vocabulary are the same thing by construction. niri's own
    // action names are accepted where ours historically differed, and
    // percent arguments take niri's quoted "+10%"/"-10%" form as well as
    // plain integers.
    // Returns whether the action was RECOGNIZED (niri's contract: an
    // unknown or undeserializable action is an Err over IPC, src/ipc/
    // server.rs:205-214 - answering Ok to garbage hid every client bug).
    // A recognized action that no-ops (focus at an edge) is still true,
    // exactly like niri.
    @discardableResult
    func performAction(_ line: String) -> Bool {
        let parts = line.split(separator: " ")
        guard let name = parts.first.map(String.init) else { return false }
        // niri's SizeChange, verbatim from its four forms: an argument that
        // STARTS with + or - adjusts, anything else SETS; ending in % means
        // a proportion, otherwise it is fixed pixels. nigiri used to strip
        // both signs and the % and always adjust, so `set-column-width
        // "50%"` GREW the column by half instead of setting it to half, and
        // a plain pixel count was silently read as a percentage.
        func sizeArg(_ index: Int) -> SizeChange? {
            guard parts.count > index else { return nil }
            return SizeChange.parse(String(parts[index]))
        }
        let intArg = parts.count > 1 ? Int(parts[1]) : nil
        // The optional window id most window actions carry (niri's
        // `id: Option<u64>`): resolved by windowTarget inside each handler.
        var windowIDArg: UInt64? { kvArg("id").flatMap { UInt64($0) } }
        // A niri reference arg carried as `id=5` / `index=2` / `name=x` (see the
        // Action decoder): pull the value for a given key out of the tokens.
        func kvArg(_ key: String) -> String? {
            let prefix = key + "="
            return parts.dropFirst().first { $0.hasPrefix(prefix) }.map {
                String($0.dropFirst(prefix.count))
            }
        }
        // Everything after the action verb, verbatim - for a trailing string
        // arg that the Action decoder flattens positionally and that may
        // contain spaces (a macOS display name), which the space-split parts
        // would truncate.
        func restOfLine() -> String {
            String(line.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
        }
        // A WorkspaceReferenceArg ({Id|Index|Name}, flattened by the decoder
        // to id=/index=/name=) resolved to a 1-based workspace number, with
        // the positional spellings as fallback. move-*-to-workspace only read
        // the positional forms, so the JSON shape - whose `focus` key sorts
        // BEFORE `reference` and pushes it out of position - moved nothing.
        func workspaceRefArg() -> Int? {
            if let ref = kvArg("id"), let id = UInt64(ref) {
                return workspaces.firstIndex { $0.id == id }.map { $0 + 1 }
            }
            if let ref = kvArg("index"), let n = Int(ref) { return n }
            if let ref = kvArg("name") { return workspaceIndex(named: ref).map { $0 + 1 } }
            if let n = intArg { return n }
            if parts.count > 1, !parts[1].contains("=") {
                return workspaceIndex(named: String(parts[1])).map { $0 + 1 }
            }
            return nil
        }
        // While the panel overview is up, navigation actions drive the
        // selection ring live (niri's zoomed-out camera) and a few window
        // actions (close, ...) act on the selection in place. Every OTHER
        // action runs on the selected window with the overview STAYING
        // OPEN, exactly like niri - the overview is just the zoomed-out
        // camera over the same scene, and src/input/mod.rs has no collapse
        // path (it closes only on toggle, click-through or gesture).
        // Collapsing on every non-navigation action was invented behavior
        // (audit ACT-8). The selection is synced into the model first (the
        // selection IS the focus), and the panel is rebuilt after the
        // action so the thumbnails show the mutated layout.
        var refreshOverviewAfterAction = false
        if isOverviewActive {
            if handleOverviewPanelAction(name, parts) { return true }
            // Infrastructure actions are not the user acting on a window
            // (a panel's periodic reserve-zone heartbeat must not touch the
            // overview), and the open/close/toggle actions manage the
            // overview themselves.
            let infrastructure: Set<String> = [
                "toggle-overview", "open-overview", "close-overview",
                "reserve-zone", "clear-zone",
            ]
            if !infrastructure.contains(name) {
                overviewFocusSelectedInModel()
                refreshOverviewAfterAction = true
            }
        }
        switch name {
        // With the floating layer active these four navigate GEOMETRICALLY,
        // like niri's floating space - the nearest window in that direction,
        // not the next entry in the list.
        case "focus-column-left":
            if workspace.isFloatingActive {
                focusFloatingGeometric(dx: -1, dy: 0)
            } else {
                focusColumn(delta: -1)
            }
        case "focus-column-right":
            if workspace.isFloatingActive {
                focusFloatingGeometric(dx: 1, dy: 0)
            } else {
                focusColumn(delta: 1)
            }
        case "focus-window-up":
            if workspace.isFloatingActive {
                focusFloatingGeometric(dx: 0, dy: -1)
            } else {
                focusWindowInStack(delta: -1)
            }
        case "focus-window-down":
            if workspace.isFloatingActive {
                focusFloatingGeometric(dx: 0, dy: 1)
            } else {
                focusWindowInStack(delta: 1)
            }
        case "focus-column-right-or-first": focusColumnWrapping(delta: 1)
        case "focus-column-left-or-last": focusColumnWrapping(delta: -1)
        case "focus-column":
            if let n = intArg { focusColumn(index: n) }
        case "focus-window-top": focusWindowEdge(top: true)
        case "focus-window-bottom": focusWindowEdge(top: false)
        case "focus-window-down-or-top": focusWindowWrapping(delta: 1)
        case "focus-window-up-or-bottom": focusWindowWrapping(delta: -1)
        // niri's compound -or- family (mod.rs:1975-2076): the inner move,
        // falling through when it did not move. They all landed on
        // unknown-action before.
        case "focus-window-in-column":
            if let n = intArg { focusWindowInColumn(n) }
        case "focus-window-down-or-column-left": focusWindowOrColumn(deltaY: 1, columnDelta: -1)
        case "focus-window-down-or-column-right": focusWindowOrColumn(deltaY: 1, columnDelta: 1)
        case "focus-window-up-or-column-left": focusWindowOrColumn(deltaY: -1, columnDelta: -1)
        case "focus-window-up-or-column-right": focusWindowOrColumn(deltaY: -1, columnDelta: 1)
        case "focus-window-or-workspace-down": focusWindowOrWorkspace(delta: 1)
        case "focus-window-or-workspace-up": focusWindowOrWorkspace(delta: -1)
        case "focus-column-or-monitor-left": focusColumnOrMonitor(delta: -1, direction: .left)
        case "focus-column-or-monitor-right": focusColumnOrMonitor(delta: 1, direction: .right)
        case "focus-window-or-monitor-up": focusWindowOrMonitor(delta: -1, direction: .up)
        case "focus-window-or-monitor-down": focusWindowOrMonitor(delta: 1, direction: .down)
        case "move-window-down-or-to-workspace-down": moveWindowOrToWorkspace(delta: 1)
        case "move-window-up-or-to-workspace-up": moveWindowOrToWorkspace(delta: -1)
        case "move-column-left-or-to-monitor-left": moveColumnOrToMonitor(delta: -1, direction: .left)
        case "move-column-right-or-to-monitor-right":
            moveColumnOrToMonitor(delta: 1, direction: .right)
        case "focus-window-previous": focusWindowPrevious()
        case "focus-window":
            // niri's FocusWindow { id } (niri-ipc/src/lib.rs). It used to
            // land on unknown-action - only the by-id spelling below
            // existed - so niri clients could not focus a window by id.
            if let id = kvArg("id").flatMap({ UInt64($0) }) {
                focusWindowByID(id)
            } else {
                print("[action] focus-window needs id=<window id>")
                return false
            }
        case "focus-floating": focusLayer(floating: true)
        case "focus-tiling": focusLayer(floating: false)
        case "swap-window-left": swapWindow(delta: -1)
        case "swap-window-right": swapWindow(delta: 1)
        case "move-column-to-index":
            if let n = intArg { moveColumnToIndex(n) }
        case "move-workspace-to-index":
            if let n = intArg { moveWorkspaceToIndex(n) }
        case "move-window-to-workspace":
            let follow = !parts.contains("focus=false")
            guard let n = workspaceRefArg() else {
                print("[action] move-window-to-workspace needs a workspace reference")
                return false
            }
            moveWindowToWorkspace(n, focus: follow, id: kvArg("window-id").flatMap { UInt64($0) })
        case "move-window-to-workspace-up": moveWindowToWorkspace(activeWorkspaceIndex)
        case "move-window-to-workspace-down": moveWindowToWorkspace(activeWorkspaceIndex + 2)
        case "move-window-to-floating": moveWindow(toFloating: true, id: windowIDArg)
        case "move-window-to-tiling": moveWindow(toFloating: false, id: windowIDArg)
        case "center-window": centerWindow(id: windowIDArg)
        case "move-floating-window":
            guard let x = sizeArg(1), let y = sizeArg(2) else {
                print("[action] move-floating-window <x> <y> (\"10\", \"+10\", \"-25\")")
                return false
            }
            return moveFloatingWindowPosition(
                x: x, y: y,
                of: windowIDArg.flatMap { id in
                    windowTarget(id: id, action: "move-floating-window")?.window
                })
        case "set-column-display":
            setColumnDisplay(tabbed: parts.count > 1 && parts[1] == "tabbed")
        case "set-workspace-name":
            if parts.count > 1 { setWorkspaceName(String(parts[1])) }
        case "unset-workspace-name": setWorkspaceName(nil)
        case "open-overview": if !isOverviewActive { enterOverview() }
        case "close-overview": if isOverviewActive { exitOverview() }
        case "switch-preset-window-height-back": switchPresetWindowHeight(delta: -1, id: windowIDArg)
        case "switch-preset-window-width-back": switchPresetWindowWidth(delta: -1, id: windowIDArg)
        case "focus-column-first": focusColumnEdge(first: true)
        case "focus-column-last": focusColumnEdge(first: false)
        // niri's focus-monitor-* / move-column-to-monitor-* (multi-monitor).
        // move-window-to-monitor is aliased to the column form.
        case "focus-monitor-next": focusMonitorRelative(1)
        case "focus-monitor-previous": focusMonitorRelative(-1)
        case "move-column-to-monitor-next", "move-window-to-monitor-next":
            moveColumnToMonitorRelative(1)
        case "move-column-to-monitor-previous", "move-window-to-monitor-previous":
            moveColumnToMonitorRelative(-1)
        case "move-workspace-to-monitor-left": moveWorkspaceToMonitor(.left)
        case "move-workspace-to-monitor-right": moveWorkspaceToMonitor(.right)
        case "move-workspace-to-monitor-up": moveWorkspaceToMonitor(.up)
        case "move-workspace-to-monitor-down": moveWorkspaceToMonitor(.down)
        case "move-workspace-to-monitor-next": moveWorkspaceToMonitorRelative(1)
        case "move-workspace-to-monitor-previous": moveWorkspaceToMonitorRelative(-1)
        // niri's switch-layout next/prev/<index>: the keyboard layout, not
        // a window layout - TIS is the macOS side of xkb.
        case "switch-layout":
            guard parts.count > 1, switchKeyboardLayout(String(parts[1])) else {
                print("[action] switch-layout: next, prev, or a 0-based index")
                return false
            }
        case "focus-monitor-left": focusMonitor(.left)
        case "focus-monitor-right": focusMonitor(.right)
        case "focus-monitor-up": focusMonitor(.up)
        case "focus-monitor-down": focusMonitor(.down)
        case "focus-monitor":
            // niri Action::FocusMonitor{output}: focus a specific NAMED output
            // (DMS's NiriService.focusMonitor sends this on multi-monitor
            // moves). Distinct from the directional focus-monitor-<dir> above.
            // The decoder flattens the string arg positionally, so the name is
            // the rest of the line (macOS display names carry spaces).
            var target = restOfLine()
            if target.hasPrefix("output=") { target = String(target.dropFirst("output=".count)) }
            guard !target.isEmpty, let index = outputs.firstIndex(where: { $0.name == target })
            else { return false }
            focusOutput(index)
        case "do-screen-transition":
            // niri Action::DoScreenTransition freezes the framebuffer and
            // crossfades to hide the surface flash of a Wayland theme reload
            // (DMS Theme.qml:1265 fires it on every theme switch). bento
            // re-renders its QML in place with no such flash on macOS, so
            // there is nothing to mask - accept the action (Handled) instead
            // of erroring quietly on each theme switch.
            return true
        case "move-column-to-monitor-left", "move-window-to-monitor-left": moveColumnToMonitor(.left)
        case "move-column-to-monitor-right", "move-window-to-monitor-right": moveColumnToMonitor(.right)
        case "move-column-to-monitor-up", "move-window-to-monitor-up": moveColumnToMonitor(.up)
        case "move-column-to-monitor-down", "move-window-to-monitor-down": moveColumnToMonitor(.down)
        case "focus-workspace":
            // niri's FocusWorkspace takes a reference by Id, Index or Name; a
            // bar clicking a workspace sends the stable Id, which is NOT the
            // 1-based position focusWorkspace expects, so resolve it.
            guard let n = workspaceRefArg() else {
                print("[action] focus-workspace needs a workspace reference")
                return false
            }
            focusWorkspace(n)
        case "focus-workspace-previous": focusWorkspacePrevious()
        case "focus-workspace-up": focusWorkspaceRelative(delta: -1)
        case "focus-workspace-down": focusWorkspaceRelative(delta: 1)
        case "move-column-left":
            if workspace.isFloatingActive {
                moveFloatingWindow(dx: -50, dy: 0)
            } else {
                moveColumn(delta: -1)
            }
        case "move-column-right":
            if workspace.isFloatingActive { moveFloatingWindow(dx: 50, dy: 0) } else { moveColumn(delta: 1) }
        case "move-window-up":
            if workspace.isFloatingActive {
                moveFloatingWindow(dx: 0, dy: -50)
            } else {
                moveWindowInStack(delta: -1)
            }
        case "move-window-down":
            if workspace.isFloatingActive {
                moveFloatingWindow(dx: 0, dy: 50)
            } else {
                moveWindowInStack(delta: 1)
            }
        case "move-column-to-first": moveColumnToEdge(first: true)
        case "move-column-to-last": moveColumnToEdge(first: false)
        case "move-column-to-workspace":
            // niri's `focus` parameter, default true (niri-ipc/src/lib.rs).
            let follow = !parts.contains("focus=false")
            guard let n = workspaceRefArg() else {
                print("[action] move-column-to-workspace needs a workspace reference")
                return false
            }
            moveColumnToWorkspace(n, focus: follow)
        case "move-column-to-workspace-up":
            moveColumnToWorkspace(activeWorkspaceIndex, focus: !parts.contains("focus=false"))
        case "move-column-to-workspace-down":
            moveColumnToWorkspace(activeWorkspaceIndex + 2, focus: !parts.contains("focus=false"))
        case "move-workspace-up": moveWorkspace(delta: -1)
        case "move-workspace-down": moveWorkspace(delta: 1)
        // Screen-edge reservation, the compositor side of niri's layer-shell
        // exclusive zone: `reserve-zone <id> <edge> <size> [pid]` shrinks the
        // tiling area, `clear-zone <id>` gives it back. Any client of this
        // socket can ask; nigiri does not care which. A zero or malformed size
        // clears, so a client dropping its reservation to 0 leaves no phantom
        // strut. The optional pid lets the reservation be dropped automatically
        // when that process dies (see the didTerminate handler).
        case "reserve-zone":
            if parts.count >= 4, let edge = ScreenStrut.Edge(rawValue: String(parts[2])),
                let size = Double(parts[3]), size > 0
            {
                let pid = parts.count >= 5 ? pid_t(parts[4]) : nil
                // Clamp to half the relevant screen dimension: a runaway zone
                // (a client bug) must never be able to swallow the whole
                // layout. Half still covers any real bar/dock/sidebar.
                let screen = ScreenGeometry.primaryScreenVisibleFrameInAXSpace()
                let limit =
                    (edge == .left || edge == .right) ? screen.width / 2 : screen.height / 2
                let clamped = min(CGFloat(size), max(1, limit))
                if pid == nil {
                    print(
                        "[strut] WARNING reserve \(parts[1]) has no owner pid: it will survive its client and only an explicit clear-zone removes it"
                    )
                }
                if clamped != CGFloat(size) {
                    print("[strut] reserve \(parts[1]) size \(Int(size)) clamped to \(Int(clamped))")
                }
                let strut = ScreenStrut(edge: edge, size: clamped, ownerPid: pid)
                // Heartbeat re-assertions re-send an IDENTICAL reservation
                // every few seconds; re-applying it cleared every height
                // cache and ran a full relayout each time, all day long.
                // Only an actual change pays for one.
                if reservedStruts[String(parts[1])] != strut {
                    reservedStruts[String(parts[1])] = strut
                    print(
                        "[strut] reserve \(parts[1]) \(edge.rawValue) \(Int(clamped)) pid=\(pid.map(String.init) ?? "-") (total: \(reservedStruts.count))"
                    )
                    applyStrutChange()
                }
            } else if parts.count >= 2 {
                if reservedStruts.removeValue(forKey: String(parts[1])) != nil {
                    print("[strut] clear \(parts[1]) via zero/malformed reserve")
                    applyStrutChange()
                }
            }
        case "clear-zone":
            if parts.count >= 2, reservedStruts.removeValue(forKey: String(parts[1])) != nil {
                print("[strut] clear \(parts[1]) (total: \(reservedStruts.count))")
                applyStrutChange()
            }
        case "consume-or-expel-window-left": consumeOrExpel(delta: -1, id: windowIDArg)
        case "consume-or-expel-window-right": consumeOrExpel(delta: 1, id: windowIDArg)
        case "consume-window-into-column": consumeWindowIntoColumn()
        case "expel-window-from-column": expelFromColumn()
        case "maximize-column": maximizeColumnToggle()
        case "maximize-window-to-edges": maximizeWindowToEdges(id: windowIDArg)
        case "fullscreen-window": fullscreenWindow(id: windowIDArg)
        case "toggle-windowed-fullscreen": toggleWindowedFullscreen(id: windowIDArg)
        // macOS-only escape hatch: the real fullscreen Space, which takes
        // the window OUT of the tiling model. niri has no counterpart.
        case "native-fullscreen": nativeFullscreenWindow()
        case "close-window": closeWindow(id: kvArg("id").flatMap { UInt64($0) })
        case "switch-preset-column-width": switchPresetColumnWidth()
        case "switch-preset-column-width-back": switchPresetColumnWidth(delta: -1)
        case "switch-preset-window-height": switchPresetWindowHeight(id: windowIDArg)
        case "switch-preset-window-width": switchPresetWindowWidth(id: windowIDArg)
        // set-window-width is niri's window-addressed spelling
        // (SetWindowWidth, scrolling.rs:2607): for a tiled window its width
        // IS its column's, and floating resizes the window - the same two
        // paths set-column-width takes here. It used to fall to
        // unknown-action, so a niri bind for it silently did nothing.
        case "set-column-width":
            guard let change = sizeArg(1) else {
                print("[action] \(name): \"50%\", \"+10%\", \"1000\" or \"+100\""); return false
            }
            if workspace.isFloatingActive {
                resizeFloatingWindow(width: change)
            } else {
                setColumnWidth(change)
            }
        case "set-window-width":
            guard let change = sizeArg(1) else {
                print("[action] \(name): \"50%\", \"+10%\", \"1000\" or \"+100\""); return false
            }
            setWindowWidth(change, id: windowIDArg)
        case "set-window-height":
            guard let change = sizeArg(1) else {
                print("[action] set-window-height: \"50%\", \"+10%\", \"1000\" or \"+100\""); return false
            }
            setWindowHeight(change, id: windowIDArg)
        case "reset-window-height": resetWindowHeight(id: windowIDArg)
        case "expand-column-to-available-width": expandColumnToAvailableWidth()
        case "center-column": centerColumn()
        case "center-visible-columns": centerVisibleColumns()
        case "toggle-window-floating": toggleWindowFloating(id: windowIDArg)
        case "switch-focus-between-floating-and-tiling": switchFocusBetweenFloatingAndTiling()
        case "toggle-column-tabbed-display": toggleColumnTabbedDisplay()
        case "toggle-overview": toggleOverview()
        case "show-hotkey-overlay": hotkeyOverlay.toggle()
        case "spawn":
            // argv, no shell - niri's spawn.
            let command = line.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { print("[action] spawn needs a command"); return false }
            spawn(command)
        case "spawn-sh":
            // the whole line through a shell - niri's spawn-sh.
            let command = line.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { print("[action] spawn-sh needs a command"); return false }
            spawnShell(command)
        // niri's screenshot arguments (lib.rs:224-285): show-pointer and
        // write-to-disk as flags, id for the window variant, and an
        // optional absolute path (positional after the decoder's flatten).
        case "screenshot", "screenshot-screen", "screenshot-window":
            let kind: ShotKind =
                name == "screenshot" ? .interactive : (name == "screenshot-screen" ? .screen : .window)
            takeScreenshot(
                kind,
                id: kvArg("id").flatMap { UInt64($0) },
                writeToDisk: kvArg("write-to-disk").map { $0 == "true" } ?? true,
                showPointer: kvArg("show-pointer").map { $0 == "true" },
                pathOverride: parts.dropFirst().first { !$0.contains("=") }.map(String.init))
        case "quit":
            // niri prompts before quitting unless skip-confirmation
            // (binds.rs, Quit { skip_confirmation }); this exited
            // unconditionally - one mistyped bind away from dropping the
            // whole session's layout.
            let skip = parts.contains { $0 == "skip-confirmation=true" || $0 == "--skip-confirmation" }
            if !skip {
                let alert = NSAlert()
                alert.messageText = "Quit nigiri?"
                alert.informativeText = "The window layout will be released."
                alert.addButton(withTitle: "Quit")
                alert.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else {
                    print("quit: cancelled")
                    return true
                }
            }
            print("quit: restoring stashed windows and exiting")
            restoreStashedWindows()
            exit(0)
        default:
            print("[action] unknown: \(line)")
            return false
        }

        // niri emits its window events the moment the state mutates. The
        // diff otherwise only runs at the tail of a full relayout, and many
        // actions animate through reflow without one - a moved column's
        // WindowOpenedOrChanged then waited for the NEXT unrelated relayout
        // (sometimes seconds late, or never on a quiet desktop). The diff is
        // a pure model walk - no AX reads - so running it after every action
        // is cheap, and a no-change action broadcasts nothing.
        broadcastWindowDiff()
        // The overview stayed open across the action (niri's contract);
        // rebuild the panel so it shows the layout the action produced.
        if refreshOverviewAfterAction, isOverviewActive {
            presentOverviewPanel(select: focusedManagedWindow())
        }
        return true
    }

    // Applies a loaded config: layout knobs, ring style, rules, and a full
    // re-registration of the binds (unregisterAll first - otherwise every
    // reload LAYERS registrations and removed binds never die). The overlay
    // is rebuilt from the same bind list, unbound vocabulary shown with an
    // empty combo column.
    func applyConfig(_ config: NigiriConfig, initial: Bool) {
        // Kept so a path that only needs to RE-RESOLVE (the keyboard-layout
        // observer) never has to re-read the file - and so a failed read can
        // fall back to what is already applied instead of to defaults.
        lastAppliedConfig = config
        // A reload can change gaps, widths and rules: whatever the apps
        // answered under the old numbers is no longer an answer to the
        // question we are about to ask.
        ColumnLayoutEngine.newEpoch()
        ColumnLayoutEngine.gap = config.gap
        ColumnLayoutEngine.presetColumnSizes = config.presetColumnSizes
        ScreenGeometry.struts = config.struts
        switch config.centerFocusedColumn {
        case .never: ColumnLayoutEngine.centerPolicy = .never
        case .always: ColumnLayoutEngine.centerPolicy = .always
        case .onOverflow: ColumnLayoutEngine.centerPolicy = .onOverflow
        }
        ColumnLayoutEngine.alwaysCenterSingleColumn = config.alwaysCenterSingleColumn
        Column.defaultTabbed = config.defaultColumnTabbed
        emptyWorkspaceAboveFirst = config.emptyWorkspaceAboveFirst
        workspaceAutoBackAndForth = config.workspaceAutoBackAndForth
        screenshotPath = config.screenshotPath
        Self.spawnEnvironmentOverrides = config.environment
        overviewPanel.applyStyle(
            zoom: config.overviewZoom, backdrop: config.overviewBackdrop,
            // The wallpaper behind the overview needs niri's own opt-in: a
            // layer-rule with place-within-backdrop (audit ACT-15).
            useWallpaper: config.backdropShowsWallpaper,
            ringColor: config.ringFrom, ringWidth: config.ringWidth,
            insertHintColor: config.insertHintColor)
        insertHint.applyStyle(off: config.insertHintOff, color: config.insertHintColor)
        ring.applyShadow(
            on: config.shadowOn, softness: config.shadowSoftness, spread: config.shadowSpread,
            offset: config.shadowOffset, color: config.shadowColor)
        ColumnLayoutEngine.presetWindowHeightSizes = config.presetWindowHeightSizes
        // Unset tab colors derive from the decoration the column wears
        // (tab_indicator.rs:363-406): the focus ring's, or the border's
        // when the ring is off and the border on.
        let tabBaseActive = config.ringOff && config.borderOn ? config.borderActiveColor : config.ringFrom
        let tabBaseInactive =
            config.ringOff && config.borderOn ? config.borderInactiveColor : config.ringInactiveColor
        tabIndicators.applyStyle(
            active: config.tabActiveColor ?? tabBaseActive,
            inactive: config.tabInactiveColor ?? tabBaseInactive,
            off: config.tabIndicatorOff,
            hideWhenSingleTab: config.tabHideWhenSingleTab,
            placeWithinColumn: config.tabPlaceWithinColumn,
            gap: config.tabGap, width: config.tabWidth,
            lengthProportion: config.tabLengthProportion,
            position: config.tabPosition,
            gapsBetweenTabs: config.tabGapsBetweenTabs,
            cornerRadius: config.tabCornerRadius)
        ColumnLayoutEngine.defaultColumnWidthSpec = config.defaultColumnWidth
        if case .proportion(let p) = config.defaultColumnWidth {
            ColumnLayoutEngine.defaultColumnWidth = p
        } else {
            // fixed/natural resolve per-window at adoption; 0.5 remains the
            // windowless fallback (drop hints).
            ColumnLayoutEngine.defaultColumnWidth = 0.5
        }
        // niri's `focus-ring { off }`, parsed since the section existed and
        // never applied: the ring kept being drawn at its configured width.
        // Width 0 is how every other decoration here spells "off" (see the
        // inactive borders below), so it needs no second switch.
        //
        // With the ring off and the border ON, niri's focused window wears
        // the border's ACTIVE color - rendered here through the ring
        // overlay, the layer that owns the focused window's decoration.
        // (With BOTH on, niri stacks border under ring; one overlay per
        // window here, so the ring wins on the focused window.)
        macOSWindowCornerRadius = config.cornerRadius
        if config.ringOff, config.borderOn {
            focusRingWidth = config.borderWidth
            ring.applyStyle(
                width: config.borderWidth,
                from: config.borderActiveColor, to: config.borderActiveColor)
        } else {
            let effectiveRingWidth = config.ringOff ? 0 : config.ringWidth
            focusRingWidth = effectiveRingWidth
            ring.applyStyle(
                width: effectiveRingWidth, from: config.ringFrom, to: config.ringTo,
                angle: config.ringAngle)
        }
        windowRules = config.rules
        // niri's reload contract for named workspaces (niri.rs:1446-1466):
        // a name REMOVED from the config is unnamed - the workspace stays,
        // now ordinary, and dies when it empties (unname_workspace); a name
        // still present keeps riding its Workspace object wherever
        // move-workspace-up/down took it; a name NEW to the config gets a
        // fresh empty workspace inserted at the TOP (ensure_named_workspace
        // -> insert_workspace(ws, 0)). The old stamping-by-position
        // relabelled whichever workspaces had been swapped and wiped
        // set-workspace-name names on every reload.
        for name in configNamedWorkspaces where !config.namedWorkspaces.contains(name) {
            workspaces.first { $0.name == name }?.name = nil
        }
        for name in config.namedWorkspaces where !workspaces.contains(where: { $0.name == name }) {
            let ws = Workspace()
            ws.name = name
            workspaces.insert(ws, at: 0)
            // The active workspace must not silently change identity.
            activeWorkspaceIndex += 1
            previousWorkspaceIndex += 1
        }
        configNamedWorkspaces = config.namedWorkspaces
        wheelActions = config.wheelBindings
        mouseActions = config.mouseBindings
        hotCornersOff = config.hotCornersOff
        hotCornerTopLeft = config.hotCornerTopLeft
        hotCornerTopRight = config.hotCornerTopRight
        hotCornerBottomLeft = config.hotCornerBottomLeft
        hotCornerBottomRight = config.hotCornerBottomRight
        MouseDragController.modMask = config.modKey
        configuredAnimations = config.animations
        animationsOff = config.animationsOff
        animationSlowdown = config.animationSlowdown
        // This overlay IS niri's `border`, and nothing else. niri draws the
        // border on every tile - the focused one in active-color, the rest in
        // inactive-color (src/layout/tile.rs:1283-1289, gated by
        // visual_border_width() which is None while the border is off) - and
        // it ships OFF (Border::default().off == true,
        // niri-config/src/appearance.rs:270-283).
        //
        // The focus ring is a SEPARATE decoration that niri emits for exactly
        // ONE tile per output: the active tile of the active column
        // (src/layout/scrolling.rs:2946, `let focus_ring = focus_ring && first`),
        // narrowed again to whichever layer is active
        // (src/layout/workspace.rs:1635 and :1654). focus-ring's
        // inactive-color paints that single ring on a NON-FOCUSED MONITOR; it
        // is never a second decoration on the same monitor.
        //
        // So under niri's defaults exactly one decoration exists on screen.
        // There used to be an `else if !config.ringOff` arm here that styled
        // this overlay with the ring's inactive-color, which put a 4px
        // rgb(80,80,80) frame around every unfocused window - the "every
        // window has a black border" report. It cited a niri model that does
        // not exist.
        if config.borderOn {
            borders.applyStyle(
                width: config.borderWidth, color: config.borderInactiveColor,
                activeColor: config.borderActiveColor)
            borderActiveEnabled = true
        } else {
            borders.applyStyle(width: 0, color: config.borderInactiveColor)
            borderActiveEnabled = false
        }
        configErrorNotification.disableFailed = config.configNotificationDisableFailed
        applyInputConfig(config)
        listener.unregisterAll()
        bindLastFire = [:]
        for bind in config.binds {
            let action = bind.action
            let combo = bind.combo
            let cooldown = bind.cooldownMs
            listener.register(bind.keyCode, modifiers: bind.modifiers, repeats: bind.repeats) {
                // niri's cooldown-ms: rate-limit repeat firings of this bind.
                if let cooldown {
                    let now = Date()
                    if let last = self.bindLastFire[combo],
                        now.timeIntervalSince(last) * 1000 < Double(cooldown)
                    {
                        return
                    }
                    self.bindLastFire[combo] = now
                }
                // The combo is logged with the action so "I pressed X and Y
                // happened" is answerable from the log instead of guessed:
                // the keycode table is US-layout, so on other layouts a
                // symbol bind can land on a different physical key.
                print("[bind] \(combo)")
                self.performAction(action)
            }
        }
        print(
            "binds resolved against layout: \(NigiriConfig.layoutKeyCodesSource)\(config.bindsLayout.map { " (pinned in config: \($0))" } ?? "")"
        )
        let wasVisible = hotkeyOverlay.isVisible
        if wasVisible { hotkeyOverlay.toggle() }
        // niri's CURATED "Important Hotkeys" list (hotkey_overlay.rs), not
        // the whole bind table; hotkey-overlay-title renames or (null)
        // hides a bind, hide-not-bound drops unbound entries.
        hotkeyOverlay = HotkeyOverlay(
            entries: HotkeyOverlay.curated(
                binds: config.binds.map { ($0.combo, $0.action, $0.title, $0.hiddenFromOverlay) },
                hideNotBound: config.hotkeyOverlayHideNotBound))
        if wasVisible { hotkeyOverlay.toggle() }
        if !initial {
            reflow()
            updateRingImmediate()
            print(
                "config reloaded: \(config.binds.count) binds, gap \(Int(config.gap)), \(config.rules.count) window rules"
            )
        }
    }
}

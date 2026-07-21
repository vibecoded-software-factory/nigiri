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
    func performAction(_ line: String) {
        let parts = line.split(separator: " ")
        guard let name = parts.first.map(String.init) else { return }
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
        // While the panel overview is up, navigation actions drive the
        // selection ring live (niri's zoomed-out camera) and a few window
        // actions (close, ...) act on the selection in place. EVERY other
        // keybinding bypasses to the SELECTED window: focus it in the model
        // first (synchronously, so a cross-workspace selection doesn't start
        // an animated switch that the isTransitioningWorkspace guards would
        // then swallow the action behind), then collapse the overview and let
        // the action run on it.
        if isOverviewActive {
            if handleOverviewPanelAction(name, parts) { return }
            if name != "toggle-overview" {
                overviewFocusSelectedInModel()
                exitOverview()
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
        case "focus-window-previous": focusWindowPrevious()
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
            if let n = intArg {
                moveWindowToWorkspace(n, focus: follow)
            } else if parts.count > 1, let idx = workspaceIndex(named: String(parts[1])) {
                moveWindowToWorkspace(idx + 1, focus: follow)
            }
        case "move-window-to-workspace-up": moveWindowToWorkspace(activeWorkspaceIndex)
        case "move-window-to-workspace-down": moveWindowToWorkspace(activeWorkspaceIndex + 2)
        case "move-window-to-floating": moveWindow(toFloating: true)
        case "move-window-to-tiling": moveWindow(toFloating: false)
        case "center-window": centerWindow()
        case "set-column-display":
            setColumnDisplay(tabbed: parts.count > 1 && parts[1] == "tabbed")
        case "set-workspace-name":
            if parts.count > 1 { setWorkspaceName(String(parts[1])) }
        case "unset-workspace-name": setWorkspaceName(nil)
        case "open-overview": if !isOverviewActive { enterOverview() }
        case "close-overview": if isOverviewActive { exitOverview() }
        case "switch-preset-window-height-back": switchPresetWindowHeight(delta: -1)
        case "switch-preset-window-width-back": switchPresetWindowWidth(delta: -1)
        case "focus-column-first": focusColumnEdge(first: true)
        case "focus-column-last": focusColumnEdge(first: false)
        case "focus-workspace":
            if let n = intArg {
                focusWorkspace(n)
            } else if parts.count > 1, let idx = workspaceIndex(named: String(parts[1])) {
                focusWorkspace(idx + 1)
            }
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
            if let n = intArg {
                moveColumnToWorkspace(n, focus: follow)
            } else if parts.count > 1, let idx = workspaceIndex(named: String(parts[1])) {
                moveColumnToWorkspace(idx + 1, focus: follow)
            }
        case "move-column-to-workspace-up":
            moveColumnToWorkspace(activeWorkspaceIndex, focus: !parts.contains("focus=false"))
        case "move-column-to-workspace-down":
            moveColumnToWorkspace(activeWorkspaceIndex + 2, focus: !parts.contains("focus=false"))
        case "move-workspace-up": moveWorkspace(delta: -1)
        case "move-workspace-down": moveWorkspace(delta: 1)
        case "consume-or-expel-window-left", "consume-or-expel-left": consumeOrExpel(delta: -1)
        case "consume-or-expel-window-right", "consume-or-expel-right": consumeOrExpel(delta: 1)
        case "consume-window-into-column": consumeWindowIntoColumn()
        case "expel-window-from-column": expelFromColumn()
        case "maximize-column": maximizeColumnToggle()
        case "maximize-window-to-edges": maximizeWindowToEdges()
        case "fullscreen-window": fullscreenWindow()
        case "toggle-windowed-fullscreen": toggleWindowedFullscreen()
        // macOS-only escape hatch: the real fullscreen Space, which takes
        // the window OUT of the tiling model. niri has no counterpart.
        case "native-fullscreen": nativeFullscreenWindow()
        case "close-window": closeWindow()
        case "switch-preset-column-width": switchPresetColumnWidth()
        case "switch-preset-column-width-back": switchPresetColumnWidth(delta: -1)
        case "switch-preset-window-height": switchPresetWindowHeight()
        case "switch-preset-window-width": switchPresetWindowWidth()
        case "set-column-width":
            guard let change = sizeArg(1) else {
                print("[action] set-column-width: \"50%\", \"+10%\", \"1000\" o \"+100\""); return
            }
            if workspace.isFloatingActive {
                resizeFloatingWindow(widthDeltaPercent: change.asFloatingDelta)
            } else {
                setColumnWidth(change)
            }
        case "set-window-height":
            guard let change = sizeArg(1) else {
                print("[action] set-window-height: \"50%\", \"+10%\", \"1000\" o \"+100\""); return
            }
            if workspace.isFloatingActive {
                resizeFloatingWindow(heightDeltaPercent: change.asFloatingDelta)
            } else {
                setWindowHeight(change)
            }
        case "reset-window-height": resetWindowHeight()
        case "expand-column-to-available-width": expandColumnToAvailableWidth()
        case "resize-edge":
            if parts.count > 2, let d = sizeArg(2)?.asFloatingDelta {
                resizeEdge(String(parts[1]), deltaPercent: d)
            } else {
                print("[action] usage: resize-edge <left|right|top|bottom> <±percent>")
            }
        case "center-column": centerColumn()
        case "center-visible-columns": centerVisibleColumns()
        case "toggle-window-floating": toggleWindowFloating()
        case "switch-focus-between-floating-and-tiling": switchFocusBetweenFloatingAndTiling()
        case "toggle-column-tabbed-display": toggleColumnTabbedDisplay()
        case "toggle-overview": toggleOverview()
        case "show-hotkey-overlay": hotkeyOverlay.toggle()
        case "spawn":
            // argv, no shell - niri's spawn.
            let command = line.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { print("[action] spawn needs a command"); return }
            spawn(command)
        case "spawn-sh":
            // the whole line through a shell - niri's spawn-sh.
            let command = line.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { print("[action] spawn-sh needs a command"); return }
            spawnShell(command)
        case "screenshot": takeScreenshot(.interactive)
        case "screenshot-screen": takeScreenshot(.screen)
        case "screenshot-window": takeScreenshot(.window)
        case "quit":
            print("quit: restoring stashed windows and exiting")
            restoreStashedWindows()
            exit(0)
        default: print("[action] unknown: \(line)")
        }
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
        screenshotPath = config.screenshotPath
        Self.spawnEnvironmentOverrides = config.environment
        overviewPanel.applyStyle(
            zoom: config.overviewZoom, backdrop: config.overviewBackdrop,
            useWallpaper: !config.overviewBackdropSet)
        insertHint.applyStyle(off: config.insertHintOff, color: config.insertHintColor)
        ring.applyShadow(
            on: config.shadowOn, softness: config.shadowSoftness,
            offset: config.shadowOffset, color: config.shadowColor)
        ColumnLayoutEngine.presetWindowHeightSizes = config.presetWindowHeightSizes
        tabIndicators.applyStyle(active: config.tabActiveColor, inactive: config.tabInactiveColor)
        ColumnLayoutEngine.defaultColumnWidth = config.defaultColumnWidth
        // niri's `focus-ring { off }`, parsed since the section existed and
        // never applied: the ring kept being drawn at its configured width.
        // Width 0 is how every other decoration here spells "off" (see the
        // inactive borders below), so it needs no second switch.
        let effectiveRingWidth = config.ringOff ? 0 : config.ringWidth
        focusRingWidth = effectiveRingWidth
        macOSWindowCornerRadius = config.cornerRadius
        ring.applyStyle(width: effectiveRingWidth, from: config.ringFrom, to: config.ringTo)
        windowRules = config.rules
        // niri's named workspaces: pre-create/name the first N slots so they
        // can be targeted by name. Never removes windows - only labels.
        // Cleared first: names travel with the Workspace object through
        // move-workspace-up/down, so re-stamping by position on every reload
        // relabelled whichever workspaces had been swapped, and a name
        // deleted from the config was never dropped.
        for ws in workspaces { ws.name = nil }
        for (i, name) in config.namedWorkspaces.enumerated() {
            while workspaces.count <= i { workspaces.append(Workspace()) }
            workspaces[i].name = name
        }
        gestureSwipeLeft = config.gestureSwipeLeft
        gestureSwipeRight = config.gestureSwipeRight
        gestureSwipeUp = config.gestureSwipeUp
        gestureSwipeDown = config.gestureSwipeDown
        wheelActions = config.wheelBindings
        mouseActions = config.mouseBindings
        gestureFourLeft = config.gestureFourLeft
        gestureFourRight = config.gestureFourRight
        gestureFourUp = config.gestureFourUp
        gestureFourDown = config.gestureFourDown
        gestureMouseOne = config.gestureMouseOne
        gestureMouseTwo = config.gestureMouseTwo
        MouseDragController.modMask = config.modKey
        configuredAnimations = config.animations
        animationsOff = config.animationsOff
        animationSlowdown = config.animationSlowdown
        // niri's model: the focus ring is drawn around EVERY window (active
        // colour vs inactive-color); `border` is a SEPARATE, off-by-default
        // decoration. nigiri only ever drew a ring on the focused window and
        // used the border overlay for the others, so `border { off }` - which
        // niri defaults to, and which this user sets - left every unfocused
        // window bare. The overlay is now driven by whichever decoration is
        // actually configured, ring first.
        if config.borderWidth > 0 {
            borders.applyStyle(width: config.borderWidth, color: config.borderInactiveColor)
        } else if !config.ringOff {
            borders.applyStyle(width: config.ringWidth, color: config.ringInactiveColor)
        } else {
            borders.applyStyle(width: 0, color: config.borderInactiveColor)
        }
        applyInputConfig(config)
        listener.unregisterAll()
        bindLastFire = [:]
        for bind in config.binds {
            let action = bind.action
            let combo = bind.combo
            let cooldown = bind.cooldownMs
            listener.register(bind.keyCode, modifiers: bind.modifiers) {
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
        let bound = Set(
            config.binds.compactMap { bind -> String? in
                guard let first = bind.action.split(separator: " ").first.map(String.init) else { return nil }
                return actionAliases[first] ?? first
            })
        let wasVisible = hotkeyOverlay.isVisible
        if wasVisible { hotkeyOverlay.toggle() }
        // niri's hotkey-overlay-title labels the bind in the overlay.
        hotkeyOverlay = HotkeyOverlay(
            bindings:
                config.binds.filter { !$0.hiddenFromOverlay }.map { ($0.combo, $0.title ?? $0.action) }
                + actionCatalog.filter { !bound.contains($0) }.map { ("", $0) })
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

import AppKit
import ApplicationServices

// Layout: applying the model to real windows (applyLayout, reflow) plus the
// AX collection pass that keeps the model honest - adopt/purge windows,
// preserve column groupings, apply window rules, coalesced scheduling.
extension TilingEngine {
    // Raw (AXUIElement, pid, title, kind) tuples in whatever order AX
    // currently reports them - which tracks z-order (front-to-back), NOT
    // column position. Never used directly to build columns; see relayout().
    // Whether an ACCESSORY app's window is a dialog the user has to answer,
    // rather than a surface that merely happens to be a window (a wallpaper,
    // an overlay, a menu bar panel). Pure enough to state as a rule: it has a
    // title, or it has the buttons that commit or cancel it.
    // The rule itself, apart from the AX reads so it can be checked: measured
    // live against the three shapes an accessory window comes in.
    static func isDialogLike(title: String, hasDefaultButton: Bool, hasCancelButton: Bool) -> Bool {
        !title.isEmpty || hasDefaultButton || hasCancelButton
    }

    static func dialogLikeAccessoryWindow(_ w: AXUIElement) -> Bool {
        isDialogLike(
            title: AX.attribute(w, kAXTitleAttribute as String) ?? "",
            hasDefaultButton: AX.hasAttribute(w, kAXDefaultButtonAttribute as String),
            hasCancelButton: AX.hasAttribute(w, kAXCancelButtonAttribute as String))
    }

    func collectCurrentAXWindows() -> [(AXUIElement, pid_t, String, CollectedKind)] {
        var result: [(AXUIElement, pid_t, String, CollectedKind)] = []
        for app in NSWorkspace.shared.runningApplications {
            // Every rejection is logged under NIGIRI_DEBUG: "my window didn't
            // get tiled" is otherwise a silent, unattributable dead end -
            // each of these guards drops a window with no trace at all.
            // An ACCESSORY app still puts real dialogs on screen: the
            // system's own permission prompts (Screen Recording, Accessibility,
            // location...), password sheets, "downloaded from the internet"
            // warnings, installer helpers. Those are windows the user has to
            // deal with, and they were escaping the window manager entirely -
            // floating over the layout, unmanaged, unfocusable by any bind.
            //
            // But most accessory windows are NOT that: a video wallpaper app
            // paints one, our own overlays are some, Control Center's panels
            // are more. Measured live, the discriminator is clean - a real
            // dialog carries a TITLE or COMMIT BUTTONS, and the rest carry
            // neither:
            //
            //   universalAccessAuthWarn  "Screen Recording"  AXDefaultButton  461x181
            //   iwallpaper               (no title)          no buttons      1370x822
            //   dev.nigiri (our chrome)  (no title)          no buttons       728x910
            //
            // So accessory apps are scanned too, and their windows are held to
            // that extra test below (dialogLikeAccessoryWindow). They always
            // land in the FLOATING layer: a prompt must never be tiled into a
            // column, and half of them refuse to be moved anyway.
            let isAccessory = app.activationPolicy == .accessory
            guard app.activationPolicy == .regular || isAccessory else {
                debugLog(
                    "[collect] skip pid \(app.processIdentifier) (\(app.localizedName ?? "?")): activationPolicy \(app.activationPolicy.rawValue)"
                )
                continue
            }
            // Never our own windows: the ring, the borders, the overview panel
            // and the close ghosts are all accessory windows of this process.
            if isAccessory, app.processIdentifier == ProcessInfo.processInfo.processIdentifier { continue }
            // macOS's system UI agents (Control Center, the Bluetooth
            // connection dialogs, Notification Center, the Dock...) put real
            // AXWindows on screen for things that are not windows at all -
            // niri never sees these because in Wayland they would be
            // layer-shell surfaces, not toplevels. activationPolicy is not
            // enough: BluetoothUIServer reports .regular while its dialog is
            // up, which is how a "Bluetooth" card ended up as a column.
            if let bundleID = app.bundleIdentifier,
                Self.systemUIAgentBundleIDs.contains(where: { bundleID.hasPrefix($0) })
            {
                debugLog("[collect] skip \(app.localizedName ?? "?"): system UI agent (\(bundleID))")
                continue
            }
            guard let name = app.localizedName,
                !neverTile.contains(where: { name.localizedCaseInsensitiveContains($0) }),
                tileAll || watchedAppNames.contains(where: { name.localizedCaseInsensitiveContains($0) })
            else {
                debugLog(
                    "[collect] skip pid \(app.processIdentifier) (\(app.localizedName ?? "?")): not watched / never-tile"
                )
                continue
            }
            guard let axWindows = AX.windows(ofPid: app.processIdentifier) else {
                debugLog("[collect] skip \(name): AX window list unreadable")
                continue
            }
            watcher.watch(pid: app.processIdentifier)
            for w in axWindows {
                if isAccessory, !Self.dialogLikeAccessoryWindow(w) {
                    debugLog("[collect] skip accessory window of \(name): doesn't look like a dialog")
                    continue
                }
                // Fast path for a window already in the model: its subrole,
                // close button and settable-ness cost four AX round-trips
                // apiece and practically never change, while the title
                // changes constantly. Re-probed in full every few seconds so
                // a window that genuinely changes shape (a dialog that
                // becomes resizable) is still reclassified.
                if let known = knownWindow(for: w),
                    Date().timeIntervalSince(known.lastFullProbe) < 3
                {
                    let title: String = AX.attribute(w, kAXTitleAttribute as String) ?? known.title
                    result.append(
                        (
                            w, app.processIdentifier, title.isEmpty ? known.title : title,
                            (isAccessory || known.isDialog) ? .dialog : .tiled
                        ))
                    watcher.watchForDestruction(w, pid: app.processIdentifier)
                    continue
                }
                knownWindow(for: w)?.lastFullProbe = Date()
                // Some apps implement menus/popovers/tooltips as their own
                // transient AXWindow-bearing panel (e.g. a Font panel reports
                // subrole AXFloatingWindow) - opening one would then look
                // like a brand-new window to us, invalidating the layout
                // cache and forcing a full re-probe of every column, and
                // closing it looks like a window closing, forcing another.
                // A real window's subrole isn't always stable across polls
                // (a document window can transiently read back as AXDialog
                // instead of AXStandardWindow), so this is a deny-list of
                // known-transient subroles rather than an allow-list.
                let subrole: String? = AX.attribute(w, kAXSubroleAttribute as String)
                let nonTileableSubroles: Set<String> = [
                    kAXFloatingWindowSubrole, kAXSystemFloatingWindowSubrole, kAXSystemDialogSubrole,
                ]
                if let subrole, nonTileableSubroles.contains(subrole) {
                    debugLog("[collect] skip \(name) window: transient subrole \(subrole)")
                    continue
                }

                let title: String = AX.attribute(w, kAXTitleAttribute as String) ?? ""

                // The close button splits real top-level windows from
                // everything else. With one: a tileable window. Without one:
                // either a genuine dialog (an Open/Save panel reports
                // subrole AXStandardWindow, title "Open", no close button -
                // probed live) which belongs in the floating layer, or
                // transient junk (a Chrome tooltip: subrole "AXUnknown",
                // empty title - the thing that once caused an infinite
                // adopt/close loop) which must stay excluded entirely.
                let hasCloseButton = AX.hasAttribute(w, kAXCloseButtonAttribute as String)

                // An accessory app's window never gets tiled, whatever shape
                // it has: it is a prompt, not a place to work.
                if isAccessory {
                    let title: String = AX.attribute(w, kAXTitleAttribute as String) ?? ""
                    result.append((w, app.processIdentifier, title.isEmpty ? (name) : title, .dialog))
                    watcher.watchForDestruction(w, pid: app.processIdentifier)
                    continue
                }

                if hasCloseButton {
                    // Windows that flatly refuse to move (Finder's desktop
                    // icon layer, some background/utility windows) would
                    // otherwise occupy a column slot forever, silently
                    // shrinking the ones that can actually resize.
                    guard AX.isSettable(w, kAXPositionAttribute as String) else {
                        debugLog("[collect] skip \(name) \"\(title)\": position not settable")
                        continue
                    }
                    // niri's compute_open_floating (src/window/mod.rs) opens
                    // fixed-size windows as floating - the AX equivalent of
                    // "min size == max size" is a non-settable size (About
                    // panels, alerts with a close button). Tiling one just
                    // fights a resize it can never win.
                    let kind: CollectedKind = AX.isSettable(w, kAXSizeAttribute as String) ? .tiled : .dialog
                    result.append((w, app.processIdentifier, title.isEmpty ? "(no title)" : title, kind))
                } else {
                    // No close button = transient/parented, niri's "windows
                    // with a parent (usually dialogs) open as floating".
                    guard
                        subrole == kAXDialogSubrole || (subrole == kAXStandardWindowSubrole && !title.isEmpty)
                    else {
                        debugLog(
                            "[collect] skip \(name) \"\(title)\": no close button, subrole \(subrole ?? "nil")"
                        )
                        continue
                    }
                    // ...EXCEPT a chrome-less real window (Alacritty with
                    // decorations "Buttonless", borderless media players):
                    // fully movable and resizable, but no close button, so
                    // the branch above never sees it - it was stuck floating
                    // as a "dialog" forever. What still separates it from an
                    // Open/Save panel (also AXStandardWindow, no close
                    // button, resizable - probed live) is the commit
                    // buttons: file panels expose AXDefaultButton/
                    // AXCancelButton (Open/Cancel), a chrome-less terminal
                    // exposes neither.
                    let hasCommitButtons =
                        AX.hasAttribute(w, kAXDefaultButtonAttribute as String)
                        || AX.hasAttribute(w, kAXCancelButtonAttribute as String)
                    if subrole == kAXStandardWindowSubrole,
                        AX.isSettable(w, kAXPositionAttribute as String),
                        AX.isSettable(w, kAXSizeAttribute as String),
                        !hasCommitButtons
                    {
                        result.append(
                            (w, app.processIdentifier, title.isEmpty ? "(no title)" : title, .tiled))
                    } else if Self.isDialogLike(
                        title: title,
                        hasDefaultButton: AX.hasAttribute(w, kAXDefaultButtonAttribute as String),
                        hasCancelButton: AX.hasAttribute(w, kAXCancelButtonAttribute as String))
                    {
                        result.append((w, app.processIdentifier, title.isEmpty ? "(dialog)" : title, .dialog))
                    } else {
                        // A dialog-subrole window with no title AND no commit
                        // buttons is not a real dialog - it is chrome: a shell
                        // panel or bar (borderless, no controls). Managing it
                        // would tile or, worse, draw an inactive border around a
                        // panel that is meant to be left completely alone -
                        // reported live. Real dialogs (Open/Save) always have a
                        // title or Open/Cancel buttons, so this excludes only
                        // chrome.
                        debugLog(
                            "[collect] skip \(name): dialog subrole, no title or buttons (panel/chrome)")
                        continue
                    }
                }
                watcher.watchForDestruction(w, pid: app.processIdentifier)
            }
        }
        return result
    }

    // workspace.focusedIndex only otherwise changes via our own
    // focus-column-left/right actions - clicking a different window (or
    // Cmd+Tabbing to a different app) changes REAL macOS focus without ever
    // touching that index. Not every app fires
    // kAXFocusedWindowChangedNotification consistently on that, which is why
    // the ring sometimes didn't follow - NSWorkspace's own app-activation
    // notification (wired up below) is the more reliable, faster signal for
    // cross-app switches specifically.
    func syncFocusIndex() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
            let focusedElement = AX.focusedWindow(ofPid: frontApp.processIdentifier)
        else { return }
        syncFocusIndex(focusedElement: focusedElement)
    }

    func syncFocusIndex(focusedElement: AXUIElement) {
        if let idx = workspace.columns.firstIndex(where: { col in
            col.windows.contains { CFEqual($0.axElement, focusedElement) }
        }) {
            // Real focus decides which group is active, not just which
            // column - clicking a tiled window while a floating dialog had
            // focus must move the ring (and all navigation) back to tiling.
            workspace.isFloatingActive = false
            workspace.focus(column: idx)
            if let windowIdx = workspace.columns[idx].windows.firstIndex(where: {
                CFEqual($0.axElement, focusedElement)
            }) {
                workspace.columns[idx].focus(row: windowIdx)
            }
            debugLog(
                "[focus-sync] focusedIndex -> \(idx) (\(workspace.columns[idx].windows.first?.title ?? "?"))")
        } else if let fidx = workspace.floatingWindows.firstIndex(where: {
            CFEqual($0.axElement, focusedElement)
        }) {
            workspace.isFloatingActive = true
            workspace.focus(floating: fidx)
            debugLog("[focus-sync] floating focus -> \(fidx) (\(workspace.floatingWindows[fidx].title))")
        }
    }

    // Where focus lands when it has nowhere better to go: the nearest
    // column (scanning outward from `index`) containing at least one window
    // the WindowServer actually has on this Space. Focus falling onto a
    // window that lives on another macOS Space framed an invisible window
    // with the ring AND scrolled the strip - pushing the user's REAL
    // windows off-screen in favor of one they can't see (hit twice during
    // the race-condition battery). A column merely scrolled out of view
    // still counts as a fallback candidate (focusing it scrolls it in),
    // so this never strands focus when nothing matches.
    func nearestVisiblyOccupiedColumnIndex(from index: Int) -> Int {
        guard !workspace.columns.isEmpty else { return 0 }
        let clamped = min(max(0, index), workspace.columns.count - 1)
        let onScreen = ScreenGeometry.onScreenWindowBoundsByPid()
        func columnVisible(_ column: Column) -> Bool {
            column.windows.contains { w in
                guard let bounds = onScreen[w.pid], let frame = WindowMover.currentFrame(w.axElement) else {
                    return false
                }
                return bounds.contains { ColumnLayoutEngine.isClose($0, frame, tolerance: 5) }
            }
        }
        for offset in 0..<workspace.columns.count {
            for candidate in [clamped - offset, clamped + offset]
            where workspace.columns.indices.contains(candidate) {
                if columnVisible(workspace.columns[candidate]) { return candidate }
            }
        }
        return clamped
    }

    func relayout() {
        // No screen, no layout. Deriving from a .zero frame gave every window
        // a 0x0 target written over AX (usableWidth becomes -20 and every
        // width and height clamps to 0), and the trigger is immediate: a
        // display disappearing fires didChangeScreenParameters, which calls
        // straight into here. It also used to leave no trace at all.
        guard ScreenGeometry.hasUsableScreen else {
            print("[layout] no screen at all: postponing the layout")
            return
        }
        // Keep the Output set in step with the live displays before laying
        // anything out - idempotent when nothing changed, and it re-homes the
        // focus and migrates windows when a monitor was plugged or unplugged.
        syncOutputs()
        let t0 = debugEnabled ? DispatchTime.now() : nil
        // Focus is tracked by IDENTITY across the purge/adopt below, not by
        // index: closing a column to the LEFT of the focused one shifted
        // every later index down, and a plain clamp then silently
        // re-pointed focus at whatever column slid into the old number.
        let previouslyFocusedColumn =
            workspace.columns.indices.contains(workspace.focusedIndex)
            ? workspace.columns[workspace.focusedIndex] : nil
        rebuildElementIndex()
        let current = collectCurrentAXWindows()
        if let t0 {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            print("[timing] collectCurrentAXWindows: \(String(format: "%.1f", ms))ms")
        }

        // Preserve existing column GROUPINGS across relayouts, not just
        // window identity, so a relayout triggered by anything else (a focus
        // ping, a window nudging back into place) doesn't undo a
        // consume-into-a-stack by flattening every column back to
        // one-window-per-column. Closed windows are removed from wherever
        // they were (collapsing any column left empty); survivors keep their
        // column and stack position; genuinely new windows become their own
        // new column at the end. Runs across EVERY workspace, not just the
        // active one - a window can close while its workspace is inactive
        // (hidden off-screen), and collectCurrentAXWindows() has no notion
        // of which workspace anything belongs to, so a window belonging to
        // an inactive workspace must still count as "known" below, or it'd
        // incorrectly look newly-opened and get folded into the active one.
        // Absence from a scan is NOT proof a window closed: a busy app can
        // time out mid-enumeration and report nothing for one poll, and
        // removing its windows on that single miss ejects them from their
        // columns - they then get re-adopted as brand-new (in the wrong
        // place, possibly the wrong kind) a moment later. But the direct
        // element probe alone is ALSO not enough: some apps keep serving a
        // CLOSED window's stale AX element (role reads answer .success
        // forever) while refusing every position write - a zombie that
        // occupies a column slot eternally, leaving a ghost gap in the
        // strip where nothing can ever be laid out (verified live: two
        // zombie Alacritty entries spamming "position not settable" on
        // every pass). Authoritative death test: the element no longer
        // appears in its OWN app's current window list. An unresponsive
        // app (list read fails) keeps its windows - absence of proof is
        // not proof of death.
        // ...and even THAT list is not instantly authoritative: an app
        // busy creating a second window can answer with only the new one for
        // a scan. The miss therefore has to repeat before it counts as
        // death (see ManagedWindow.absentFromAppListScans) - a zombie stays
        // absent forever and dies a couple of passes later, while a live
        // window reappears on the very next scan and resets the count.
        func isWindowDead(_ known: ManagedWindow) -> Bool {
            let (scans, dead) = TilingEngine.purgeVerdict(
                scans: known.absentFromAppListScans,
                verdict: isElementDead(known.axElement, pid: known.pid))
            known.absentFromAppListScans = scans
            return dead
        }
        func isElementDead(_ el: AXUIElement, pid: pid_t) -> TilingEngine.DeathVerdict {
            // A dead PROCESS never answers .invalidUIElement - its elements
            // fail with .cannotComplete, and its app-level window list read
            // below fails the same way, which the unresponsive-app guard
            // reads as "keep". Net effect: every window of a killed app
            // became an immortal zombie column (verified live - killed a
            // test Alacritty instance, its column survived every relayout,
            // eating position writes forever). Process liveness is the one
            // authoritative, always-answerable death test.
            if NSRunningApplication(processIdentifier: pid) == nil { return .dead }
            // Raw call, not AX.attribute: this is the one read that must
            // DISTINGUISH error codes - .invalidUIElement is proof of death,
            // any other failure is just an unresponsive app.
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &ref) == .invalidUIElement {
                return .dead
            }
            guard let appWindows = AX.windows(ofPid: pid) else { return .alive }
            return appWindows.contains { CFEqual($0, el) } ? .alive : .absentFromList
        }
        // "Consecutive" is enforced in TWO places, and both are load-bearing:
        // the counter is bumped here (through TilingEngine.purgeVerdict) and
        // RESET in the title loop further down, the one place that walks
        // every window this scan DID see. It cannot be reset inside the
        // predicate: the purge is `!present && isWindowDead(known)` and `&&`
        // short-circuits, so a window that is present never reaches it. When
        // it was only reset there, the counter was monotonic for the whole
        // session and three unrelated transient misses hours apart purged a
        // live window - the exact bug the counter exists to prevent. Deleting
        // or reordering that title loop reinstates it, with a green build.
        var purgedAnyWindow = false
        // Who left, so the close animation can play over the slot they held.
        // Collected from inside the predicate because that is where the
        // verdict is reached (and where the window is still in the model).
        var closed: [ManagedWindow] = []
        for ws in allWorkspaces {
            for column in ws.columns {
                // The height cache and the row focus are the mutator's job
                // now; a purge only has to say what left.
                let gone = column.removeWindows { known in
                    !current.contains { CFEqual($0.0, known.axElement) } && isWindowDead(known)
                }
                closed.append(contentsOf: gone)
                if !gone.isEmpty { purgedAnyWindow = true }
            }
            ws.removeEmptyColumns()
            // One call re-anchors every index of this workspace (column
            // focus, each column's row focus, the floating focus, and the
            // isFloatingActive flag) instead of four hand-written clamps
            // that inactive workspaces used to be left out of.
            ws.clampFocus()
            // Floating windows are tracked the same way, just outside any
            // column - otherwise a closed floating window would linger
            // forever, and a still-open one would look "newly opened" on
            // every relayout and get folded back into a tiled column below.
            ws.floatingWindows.removeAll { known in
                guard !current.contains(where: { CFEqual($0.0, known.axElement) }),
                    isWindowDead(known)
                else { return false }
                closed.append(known)
                return true
            }
            ws.focus(floating: ws.floatingFocusedIndex)
            if ws.floatingWindows.isEmpty { ws.isFloatingActive = false }
        }
        // niri's window-close: leave a ghost of what was there while the
        // neighbours slide in over it. Usually already played from the
        // destroyed notification by now; this catches whatever only the purge
        // noticed (an app that died whole).
        for window in closed { playCloseGhost(window) }
        // Whatever died takes its bookkeeping with it: the snapshot cache is
        // a one-frame buffer for a closing window, not a history of the
        // session, and a played ghost has nothing left to de-duplicate.
        for window in closed {
            closeSnapshots.removeValue(forKey: window.id)
            ghostedWindows.remove(window.id)
        }
        // A tiled window that keeps refusing to be moved holds a column slot
        // it can never fill - the gap in the strip where nothing lays out.
        // The adoption probe cannot catch all of these: a file panel answered
        // "position settable" when it was adopted and then refused every
        // single write (verified live, an Open panel that outlived its own
        // app's window list). What the writes report is the ground truth, so
        // three consecutive refusals demote it to the floating layer, where
        // nigiri never repositions anything.
        for ws in allWorkspaces {
            var demoted: [ManagedWindow] = []
            for column in ws.columns {
                demoted.append(contentsOf: column.removeWindows { $0.positionRefusals >= 3 })
            }
            guard !demoted.isEmpty else { continue }
            ws.removeEmptyColumns()
            ws.clampFocus()
            for window in demoted {
                window.positionRefusals = 0
                ws.floatingWindows.append(window)
                print("[layout] \(window.title): refuses to move, demoted to floating")
            }
            ColumnLayoutEngine.newEpoch()
        }

        // Titles are live, not a snapshot from adoption time: a terminal
        // retitles itself on every command, a browser on every tab switch.
        // Captured once, the model kept naming a window by whatever it was
        // called the instant it opened - which is what every log line, focus
        // event, and overview thumbnail label then reported, and made
        // "which window is this?" genuinely impossible to answer.
        // O(N) through the element index instead of rebuilding
        // `columns.flatMap + floatingWindows` for every scanned element x
        // every workspace. Folds in the two other per-element passes that
        // walked the whole model: the settable flag and the absent-scan
        // counter (a window present in this scan is, by definition, present).
        for (element, _, title, _) in current {
            guard let w = knownWindow(for: element) else { continue }
            w.title = title
            w.positionSettable = true
            w.absentFromAppListScans = 0
        }

        // The dialog classification comes from a live AX probe taken the
        // instant a window appeared - and an app still mapping its window can
        // answer "size not settable" / "no close button" for a beat, latching
        // a perfectly ordinary window as a dialog FOREVER: permanently
        // floating, and toggle-window-floating refuses to tile a dialog back,
        // so the only cure was restarting nigiri. Every relayout re-probes,
        // so a window that now reads as tileable, and that the probe ALONE
        // floated (never a window-rule, never the user's own toggle), is
        // promoted back into the columns. Never the reverse: a transient bad
        // read must not eject a tiled window into the floating layer.
        func probedTileable(_ window: ManagedWindow) -> Bool {
            current.contains { CFEqual($0.0, window.axElement) && $0.3 == .tiled }
        }
        for ws in allWorkspaces {
            for window in ws.tiledWindows where window.isDialog && probedTileable(window) {
                window.isDialog = false
            }
            let promotable = ws.floatingWindows.filter {
                $0.isDialog && $0.autoFloatedAsDialog && probedTileable($0)
            }
            guard !promotable.isEmpty else { continue }
            ws.floatingWindows.removeAll { w in promotable.contains { $0 === w } }
            ws.focus(floating: ws.floatingFocusedIndex)
            if ws.floatingWindows.isEmpty { ws.isFloatingActive = false }
            for window in promotable {
                window.isDialog = false
                window.autoFloatedAsDialog = false
                // It was never laid out while floating, so any memorized
                // request/answer pair predates tiling and would make the
                // first layout pass skip it as "already refused".
                window.lastRequestedFrame = nil
                window.lastActualFrame = nil
                let c = Column()
                c.setWindows([window])
                // Appended, not inserted: end-of-strip never shifts an
                // existing index (maximizedIndex included), and this is a
                // silent correction - it must not move anything under focus.
                ws.appendColumn(c)
                print("reclassified as tileable: \(window.title)")
            }
        }

        // A fullscreen window that closed would otherwise keep every other
        // window parked off-screen forever, with no decorations.
        for ws in allWorkspaces {
            if let full = ws.fullscreenWindow,
                !ws.allWindows.contains(where: { $0 === full })
            {
                ws.fullscreenWindow = nil
            }
        }

        let knownElements = allWorkspaces.flatMap { ws in ws.allWindows.map { $0.axElement } }
        // Genuinely new windows always open on the active workspace, and -
        // matching niri - as a new column immediately to the RIGHT of the
        // focused one, taking focus, so the strip scrolls to reveal them at
        // once. Waiting for macOS's own focus notifications instead was
        // racy: this relayout usually runs before the app has finished
        // activating, so syncFocusIndex still saw the OLD focused window,
        // left the view where it was, and the new window sat unarranged
        // until the next manual focus change. The initial adoption pass
        // (nothing known yet) is different: it's cataloguing windows that
        // already existed, in z-order, so it appends without touching focus.
        let newlyOpened = current.filter { entry in !knownElements.contains { CFEqual($0, entry.0) } }
        // A window opening or closing is the other honest moment to re-ask:
        // the layout is about to change shape anyway.
        if !newlyOpened.isEmpty || purgedAnyWindow { ColumnLayoutEngine.newEpoch() }
        let structurallyChanged = !newlyOpened.isEmpty || purgedAnyWindow
        let isInitialAdoption = knownElements.isEmpty
        var focusNewColumn = false
        for (element, pid, title, kind) in newlyOpened {
            let app = NSRunningApplication(processIdentifier: pid)
            let appName = app?.localizedName ?? ""
            // A window being adopted is not focused or floating yet, so the
            // state matchers see it as it opens - which is what niri's
            // open-* properties are resolved against.
            // Printed, not debugLog'd: when something junk gets adopted (a
            // system popup, a helper's stray panel) the FIRST question is
            // always "who owns it", and reproducing a transient popup on
            // demand to answer that is not always possible.
            print(
                "[adopt] \(appName) [\(app?.bundleIdentifier ?? "no bundle id")] \"\(title)\" \(kind == .dialog ? "floating" : "tiled")"
            )
            let rule = matchingWindowRule(appName: appName, bundleID: app?.bundleIdentifier, title: title)
            let window = ManagedWindow(axElement: element, pid: pid, title: title)
            window.isDialog = kind == .dialog
            // On INITIAL adoption (cataloguing an existing session) a window
            // belongs to the output it is physically on, so windows already on
            // the external monitor are not yanked onto the primary. A genuinely
            // new window opens on the focused output, niri-style.
            let adoptWorkspace =
                isInitialAdoption
                ? (outputContaining(WindowMover.currentFrame(element)) ?? focusedOutput).activeWorkspace
                : workspace
            // A rule can force either way; with no rule, dialogs float
            // (niri's compute_open_floating). Floating means part of the
            // model - focus ring, floating navigation, workspace
            // bookkeeping - just never repositioned by the layout engine.
            let shouldFloat = rule?.openFloating ?? (kind == .dialog)
            // Only a float that came purely from the live probe is
            // reclassifiable later (see ManagedWindow.autoFloatedAsDialog).
            window.autoFloatedAsDialog = rule?.openFloating == nil && kind == .dialog
            // Width-rule constraints seed a fresh tiled column below; a
            // helper applies them wherever the column gets built.
            func applyWidthRule(_ c: Column) {
                if let mn = rule?.minWidthPx { c.cachedMinWidth = mn }
                if let mx = rule?.maxWidthPx { c.maxWidthPx = mx }
            }
            // niri's default-floating-position, and open-fullscreen (macOS
            // native fullscreen). Both are deferred a beat so the app has
            // finished mapping the window; skipped on initial adoption.
            func applyOpenState() {
                guard !isInitialAdoption else { return }
                if shouldFloat, let pos = rule?.defaultFloatingPosition,
                    let f = WindowMover.currentFrame(element)
                {
                    window.stashedFrame = CGRect(origin: pos, size: f.size)
                    try? WindowMover.setPosition(element, to: pos)
                }
                if rule?.openFullscreen == true {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        MainActor.assumeIsolated {
                            _ = AXUIElementSetAttributeValue(
                                element, "AXFullScreen" as CFString, true as CFBoolean)
                        }
                    }
                }
            }
            // niri's open-on-workspace: adopt straight into that workspace,
            // parked out of sight - it never steals focus from the active
            // one. By number, or by named workspace (resolved to its slot).
            // Skipped during initial adoption (cataloguing an existing
            // session shouldn't teleport windows around).
            let ruledWorkspace =
                rule?.openOnWorkspace
                ?? rule?.openOnWorkspaceName.flatMap { workspaceIndex(named: $0).map { $0 + 1 } }
            if let wsNumber = ruledWorkspace, wsNumber >= 1, wsNumber - 1 != activeWorkspaceIndex,
                !isInitialAdoption
            {
                while workspaces.count <= wsNumber - 1 { workspaces.append(Workspace()) }
                let target = workspaces[wsNumber - 1]
                if shouldFloat {
                    target.floatingWindows.append(window)
                } else {
                    let c = Column()
                    if let proportion = rule?.defaultWidthProportion { c.widthProportion = proportion }
                    applyWidthRule(c)
                    c.setWindows([window])
                    target.appendColumn(c)
                    if rule?.openMaximized == true { target.maximizedIndex = target.columns.count - 1 }
                }
                if let frame = WindowMover.currentFrame(element) {
                    window.stashedFrame = frame
                    _ = ColumnLayoutEngine.applyFrame(
                        window,
                        target: parkedOffScreen(
                            frame, screenFrame: currentRawScreenFrame()))
                }
                applyOpenState()
                print("window-rule: \(window.title) -> workspace \(wsNumber)")
                continue
            }
            if shouldFloat {
                adoptWorkspace.floatingWindows.append(window)
                if !isInitialAdoption {
                    // macOS focuses a freshly-opened dialog itself; mirror
                    // that in the model so the ring lands on it immediately.
                    workspace.focus(floating: workspace.floatingWindows.count - 1)
                    workspace.isFloatingActive = true
                }
                applyOpenState()
            } else {
                let c = Column()
                if let proportion = rule?.defaultWidthProportion {
                    c.widthProportion = proportion
                }
                applyWidthRule(c)
                c.setWindows([window])
                if isInitialAdoption {
                    adoptWorkspace.appendColumn(c)
                } else {
                    let insertAt =
                        workspace.columns.isEmpty
                        ? 0 : min(workspace.focusedIndex + 1, workspace.columns.count)
                    // activating: focusing it separately would clear the
                    // "closing this one hands focus back left" memory that
                    // inserting right of the focus just recorded.
                    workspace.insertColumn(c, at: insertAt, activating: true)
                    // The new tiled column takes focus even if a floating
                    // dialog held it - without this, focusCurrentColumn
                    // below re-focuses the OLD floating window (the model's
                    // focus reads through isFloatingActive first).
                    workspace.isFloatingActive = false
                    focusNewColumn = true
                    // niri's open-maximized, on the just-inserted column
                    // (insertColumn already shifted any previous index).
                    if rule?.openMaximized == true {
                        workspace.maximizedIndex = insertAt
                    }
                }
                applyOpenState()
            }
        }
        let managed = workspace.tiledWindows

        // AXIsProcessTrusted at startup is NOT proof the grant stays alive:
        // rebuilding the binary invalidates the ad-hoc signature TCC tied
        // the grant to, and tccd caches the resulting denial PER PROCESS -
        // a running instance then passes the trust check yet gets every
        // write refused, forever (verified live: an instance that adopted
        // windows fine, then spent its whole life logging "position not
        // settable" for all of them while a freshly-launched process moved
        // the same windows without issue). Every managed window refusing
        // kAXPosition at once is that systemic dead-grant state, not a
        // per-window quirk - detect it and say so, instead of silently
        // limping as a layout engine nothing obeys.
        if !managed.isEmpty {
            let anyWritable = managed.contains { AX.isSettable($0.axElement, kAXPositionAttribute as String) }
            if !anyWritable {
                if !warnedDeadAccessibilityGrant {
                    warnedDeadAccessibilityGrant = true
                    print(
                        """
                        ERROR: every managed window refuses position writes - this process's \
                        Accessibility grant is dead (typically: the binary was rebuilt, which \
                        invalidates the signature TCC tied the grant to, and tccd caches the \
                        denial for this process's lifetime). Restart nigiri; if it persists, \
                        toggle nigiri off and on in System Settings > Privacy & Security > \
                        Accessibility.
                        """)
                }
            } else {
                warnedDeadAccessibilityGrant = false
            }
        }

        // Re-anchor focus after the rebuild. A freshly-adopted column's
        // explicit focus intent wins; otherwise the previously-focused
        // column is found again BY IDENTITY (indices may have shifted);
        // only if that column is gone entirely does focus genuinely fall -
        // and then it falls to the nearest column the user can SEE.
        if focusNewColumn {
            // adoption already pointed focusedIndex at the new column
        } else if let prev = previouslyFocusedColumn,
            let idx = workspace.columns.firstIndex(where: { $0 === prev })
        {
            workspace.focus(column: idx)
        } else {
            workspace.focus(column: nearestVisiblyOccupiedColumnIndex(from: workspace.focusedIndex))
        }
        if let mi = workspace.maximizedIndex, !workspace.columns.indices.contains(mi) {
            workspace.maximizedIndex = nil
        }
        if focusNewColumn {
            // Our explicit focus intent wins over whatever macOS considers
            // focused right now (usually still the old window, mid-launch) -
            // syncFocusIndex here would immediately undo the insert-and-focus.
            focusCurrentColumn()
        } else {
            syncFocusIndex()
        }
        compactWorkspaces()
        // The overview owns real window geometry while it is up (windows are
        // scaled/parked for the thumbnails), so the physical tiling pass is
        // replaced by a panel rebuild: the model adoption above already ran,
        // so a window opened WHILE the overview is up shows up in it at once
        // instead of only after leaving - the overview mirrors the desktop
        // live, in both directions. The deferred relayout on exit then lays
        // everything out for real.
        // A relayout fires on every moved/resized/created notification from
        // every watched app, and used to end in a full spring animation of
        // every window even when the scan found nothing new. Skip it when
        // nothing was adopted or purged AND every window already sits at the
        // frame the model wants. It costs two AX reads per window (see
        // below) - cheap next to the alternative, which is animating every
        // window on every relayout, but not free.
        if !structurallyChanged, !isOverviewActive, frameAnimationTimer == nil {
            let (screenFrame, _) = usableScreen()
            let wanted = ColumnLayoutEngine.targetFrames(
                columns: workspace.columns, in: screenFrame,
                maximizedIndex: workspace.maximizedIndex, viewOffset: workspace.viewOffset)
            // Against the REAL frames, not the memorized ones: a window
            // dragged by its title bar (no Mod) is exactly the case this
            // relayout exists to correct, and the memo would still claim it
            // is where we left it. Two AX reads per window, versus a full
            // spring animation of every window.
            let allInPlace =
                !wanted.isEmpty
                && wanted.allSatisfy { entry in
                    guard let actual = WindowMover.currentFrame(entry.window.axElement) else { return false }
                    return ColumnLayoutEngine.isClose(actual, entry.frame, tolerance: 2)
                }
            if allInPlace {
                updateRing()
                return
            }
        }

        if isOverviewActive {
            if overviewUsedPanel, overviewDragIndex == nil {
                presentOverviewPanel(select: overviewSelectedWindow())
                // A window opened or closed while the overview is up: place
                // the survivors for real now, behind the panel, so leaving
                // the overview never uncovers a layout that still has to
                // move. Only on a STRUCTURAL change - a title change must
                // not re-animate the whole strip.
                if structurallyChanged { applyOverviewRearrangement() }
            }
            relayoutQueuedDuringTransition = true
        } else {
            reflow()
        }
        // `managed` is the TILED windows - that is what the line below
        // reports - but "found nothing" has to mean the workspace is actually
        // empty: a workspace holding only dialogs announced itself as having
        // no windows at all.
        if workspace.allWindows.isEmpty {
            print(
                "no windows found yet for: \(tileAll ? "all apps" : watchedAppNames.joined(separator: ", "))")
        } else if managed.isEmpty {
            print("tiled 0 column(s): \(workspace.floatingWindows.count) floating")
        } else {
            print(
                "tiled \(workspace.columns.count) column(s): \(managed.map { $0.title }.joined(separator: ", "))"
            )
        }
        msgServer.broadcast(
            "{\"event\":\"layout\",\"workspace\":\(activeWorkspaceIndex + 1),\"columns\":\(workspace.columns.count)}"
        )
        broadcastWindowDiff()
        // The focused output was just laid out above; every OTHER output's
        // active workspace still needs its windows placed on its own monitor.
        layoutAllOutputs()
        if let t0 {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            print("[timing] full relayout(): \(String(format: "%.1f", ms))ms")
        }
    }

    // All notification-driven relayouts funnel through here rather than
    // calling relayout() directly: a single real event usually arrives as a
    // burst of notifications (every window of a quitting app, a move AND a
    // resize for one frame change), and each relayout is a full AX re-scan -
    // coalescing a burst into one pass. During a workspace transition the
    // model is deliberately mid-change (half the windows minimizing, the
    // index switching) - a relayout reading that state folds windows into
    // the wrong workspace, so it's deferred until the transition completes.
    func scheduleRelayout() {
        if isTransitioningWorkspace {
            relayoutQueuedDuringTransition = true
            return
        }
        // The overview does NOT defer: a window opening or dying while it is
        // up must appear/disappear in the thumbnails immediately (relayout's
        // tail swaps the physical tiling pass for a panel rebuild). Only a
        // drag in progress defers - rebuilding mid-drag would yank the
        // thumbnail out from under the cursor.
        if isOverviewActive, overviewDragIndex != nil {
            relayoutQueuedDuringTransition = true
            refreshOverviewForDeadWindows()
            return
        }
        pendingRelayout?.cancel()
        // The transition check repeats INSIDE the work item: a relayout
        // scheduled just before a workspace switch starts would otherwise
        // fire mid-transition, folding mid-stash windows into the wrong
        // workspace and superseding the switch's animation. Overview mode
        // defers identically - the model is deliberately scattered.
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                if self.isTransitioningWorkspace || (self.isOverviewActive && self.overviewDragIndex != nil) {
                    self.relayoutQueuedDuringTransition = true
                } else {
                    self.relayout()
                }
            }
        }
        pendingRelayout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    // Scrolls the strip the minimum amount to keep the focused column fully
    // in view (niri's center-focused-column "never"), then lays out every
    // column at its resulting screen position - the single call site that
    // actually touches window frames, so every action funnels through here.
    // Passes layout()'s discovery flag through: true means placements moved
    // under the caller's feet and its scroll/ring state is stale.
    @discardableResult
    func applyLayout(screenFrame: CGRect) -> Bool {
        // Never measure a window that is still moving: the min-width
        // discovery would read a frame from the middle of a spring and
        // memorize it as the column's floor.
        guard frameAnimationTimer == nil else {
            watcher.applyingLayout {
                if let full = fullscreenWindowRef {
                    _ = ColumnLayoutEngine.applyFrame(
                        full, target: currentRawScreenFrame())
                }
            }
            return false
        }
        // Fullscreen sends every other window out of view rather than under
        // the fullscreen one: a translucent window shows what is behind it,
        // so covered != hidden. Same mechanism as a column scrolled out of
        // the strip (grantedX, 1px in).
        if let full = fullscreenWindowRef {
            watcher.applyingLayout {
                _ = ColumnLayoutEngine.applyFrame(
                    full, target: currentRawScreenFrame())
                for w in workspace.allWindows where w !== full {
                    guard let current = WindowMover.currentFrame(w.axElement) else { continue }
                    // Floating windows are never re-laid-out by the tiling
                    // pass, so their pre-fullscreen frame is the only record
                    // of where they belong - and it must be recorded only the
                    // first time, or the second pass saves the parking spot.
                    if let home = FullscreenStash.homeToRecord(
                        isFloating: workspace.floatingWindows.contains { $0 === w },
                        existingHome: w.fullscreenHome, currentFrame: current)
                    {
                        w.fullscreenHome = home
                    }
                    _ = ColumnLayoutEngine.applyFrame(
                        w, target: FullscreenStash.parked(current, screenFrame: screenFrame))
                }
            }
            // Nothing to discover on this path: the fullscreen window takes
            // the whole screen and everyone else is parked, so no column
            // reports a new minimum. It used to be a `var` set to false in two
            // places and returned - a constant wearing a result's clothes.
            return false
        }
        var discovered = false
        watcher.applyingLayout {
            discovered = ColumnLayoutEngine.layout(
                columns: workspace.columns, in: screenFrame, maximizedIndex: workspace.maximizedIndex,
                viewOffset: workspace.viewOffset, skipping: fullscreenWindowRef)
        }
        return discovered
    }

    // `explicitViewOffset`, when given, skips the usual minimal-scroll-into-
    // view computation (niri's center-focused-column "never") and uses this
    // value as-is instead - for the two actions that deliberately DO center
    // things on demand (center-column, center-visible-columns), which is a
    // different, explicit user action from the passive auto-follow policy.
    // `onSettled`, when given, fires exactly once, when the layout genuinely
    // stops moving - either this reflow's animation settled, or a newer
    // animation superseded it (in which case THAT one now owns the
    // authoritative settle). It must never be silently dropped: the
    // workspace-switch curtain waits on it to reveal the screen.
    func reflow(explicitViewOffset: CGFloat? = nil, onSettled: (() -> Void)? = nil) {
        debugLog(
            "[reflow] focusedIndex=\(workspace.focusedIndex) viewOffset=\(Int(workspace.viewOffset)) transitioning=\(isTransitioningWorkspace)"
        )
        let (screenFrame, usableWidth) = usableScreen()
        var targetOffset = explicitViewOffset ?? workspace.viewOffset
        if explicitViewOffset == nil, workspace.columns.indices.contains(workspace.focusedIndex) {
            let placements = ColumnLayoutEngine.columnPlacements(
                columns: workspace.columns, usableWidth: usableWidth, maximizedIndex: workspace.maximizedIndex
            )
            targetOffset = ColumnLayoutEngine.scrollOffset(
                toShow: workspace.focusedIndex, placements: placements, currentOffset: workspace.viewOffset,
                usableWidth: usableWidth, previousIndex: lastReflowedColumnIndex)
        }
        lastReflowedColumnIndex = workspace.focusedIndex
        workspace.viewOffset = targetOffset
        var targets = ColumnLayoutEngine.targetFrames(
            columns: workspace.columns, in: screenFrame, maximizedIndex: workspace.maximizedIndex,
            viewOffset: targetOffset)
        // niri's windowed fullscreen: this ONE window covers the raw screen
        // frame (no gaps), and the strip underneath keeps its own layout -
        // leaving fullscreen restores everything without a re-tile.
        if let full = fullscreenWindowRef {
            let raw = currentRawScreenFrame()
            if let idx = targets.firstIndex(where: { $0.window === full }) {
                targets[idx].frame = raw
            } else {
                targets.append((window: full, frame: raw))
            }
            // Same rule as applyLayout's fullscreen branch.
            for i in targets.indices where targets[i].window !== full {
                targets[i].frame.origin.x = screenFrame.maxX - 1
            }
        }
        // applyLayout below IS the authoritative write+memorize pass for this
        // path, so the animator's own verification re-write is skipped: the
        // two of them firing back-to-back was what let a heavy app drop the
        // second and memorize a permanent lie about its own geometry.
        animateFrames(targets, verifyOnSettle: false) { cancelled in
            // Settle with the real, authoritative layout pass - it probes
            // and caches the true stuck/flexible height split for any stack
            // shape targetFrames had to approximate. Skipped when a newer
            // animation superseded this one: writing the superseded layout's
            // frames now would snap windows back against the newer animation.
            if !cancelled {
                if self.applyLayout(screenFrame: screenFrame) {
                    // The settle pass DISCOVERED a minimum width: placements
                    // grew, the strip may no longer show the focused column,
                    // and the ring frames a pre-discovery target. Re-run the
                    // whole scroll+animate against the now-cached truth
                    // (bounded: the cache means it can't re-discover) and
                    // hand it the settle obligation.
                    self.reflow(onSettled: onSettled)
                    return
                }
                // The settle pass can still nudge windows (height probes,
                // clamped stacks) after the ring already landed - re-frame
                // it from reality, not from the animation's target.
                self.updateRingImmediate()
            }
            onSettled?()
        }
    }
}

extension TilingEngine {
    // niri's `window-close`, played over the slot the window just left. Only
    // once per window: the destroyed notification and the relayout's purge
    // both report the same close, one fast and one late.
    func playCloseGhost(_ window: ManagedWindow) {
        guard !isOverviewActive, ghostedWindows.insert(window.id).inserted else { return }
        let curve = animationCurve(named: "window-close")
        if case .off = curve { return }
        let snapshot = closeSnapshots[window.id]
        // Where it last WAS, preferred over where it was photographed: a
        // window that moved after its snapshot must still fade out over the
        // slot it actually occupied.
        guard let frame = window.lastActualFrame ?? snapshot?.frame ?? window.lastRequestedFrame else {
            print("[close] \(window.title): no known frame, no ghost")
            return
        }
        print("[close] ghost of \(window.title)" + (snapshot == nil ? " (no snapshot)" : ""))
        let contents: Any? = snapshot.flatMap { CVPixelBufferGetIOSurface($0.buffer) }
            .map { unsafeBitCast($0.takeUnretainedValue(), to: IOSurface.self) }
        ghosts.play(contents: contents, retaining: snapshot?.buffer, axFrame: frame, curve: curve)
    }
}

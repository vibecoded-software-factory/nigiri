import AppKit
import Carbon
import Foundation

// niri's IPC shape (niri-ipc/src/lib.rs), so a client written against niri
// works here unmodified: a JSON request in, {"Ok": <reply>} / {"Err": "..."}
// out, and events as single-key objects.
//
// The bare-word requests (windows, workspaces, focused-window,
// event-stream, action <line>) are a DOCUMENTED nigiri extension, not
// upstream vocabulary: the shell runtime (bento) subscribes and commands
// through them, so they stay - answering in their flat legacy shape,
// never colliding with real niri clients (the JSON forms parse first).
enum NiriProtocol {
    // A parsed request. The bare-word forms map onto the same cases, with
    // `legacy` marking the ones that must answer in the old shape.
    enum Request {
        case version
        case windows
        case workspaces
        case focusedWindow
        case outputs
        case focusedOutput
        case overviewState
        case pickWindow
        case layers
        case keyboardLayouts
        case pickColor
        case output(String)
        case returnError
        case casts
        case action(String)
        case eventStream
        case unknown(String)
    }

    struct Parsed {
        let request: Request
        // true for the bare-word protocol: reply flat, without the Ok/Err
        // envelope.
        let legacy: Bool
    }

    static func parse(_ line: String) -> Parsed {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Bare words first: they are unambiguous and cheap.
        switch trimmed {
        case "windows": return Parsed(request: .windows, legacy: true)
        case "workspaces": return Parsed(request: .workspaces, legacy: true)
        case "focused-window": return Parsed(request: .focusedWindow, legacy: true)
        case "event-stream": return Parsed(request: .eventStream, legacy: true)
        default: break
        }
        if trimmed.hasPrefix("action ") {
            return Parsed(request: .action(String(trimmed.dropFirst("action ".count))), legacy: true)
        }
        // niri's own shape: either a bare string ("Version") or a one-key
        // object ({"Action": {...}}).
        guard let data = trimmed.data(using: .utf8),
            // .fragmentsAllowed: niri's argument-less requests are bare
            // JSON strings ("Windows"), which are not valid top-level
            // JSON documents without it - they parsed as garbage.
            let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            return Parsed(request: .unknown(trimmed), legacy: true)
        }
        if let name = json as? String {
            return Parsed(request: named(name, payload: nil), legacy: false)
        }
        if let object = json as? [String: Any], let key = object.keys.first {
            return Parsed(request: named(key, payload: object[key]), legacy: false)
        }
        return Parsed(request: .unknown(trimmed), legacy: false)
    }

    private static func named(_ key: String, payload: Any?) -> Request {
        switch key {
        case "Version": return .version
        case "Windows": return .windows
        case "Workspaces": return .workspaces
        case "FocusedWindow": return .focusedWindow
        case "Outputs": return .outputs
        case "FocusedOutput": return .focusedOutput
        case "OverviewState": return .overviewState
        case "PickWindow": return .pickWindow
        case "Layers": return .layers
        case "KeyboardLayouts": return .keyboardLayouts
        case "PickColor": return .pickColor
        case "ReturnError": return .returnError
        case "Casts": return .casts
        case "Output":
            // Request::Output { output, action }: the target name decides
            // between Applied and OutputWasMissing (lib.rs:107-116).
            if let object = payload as? [String: Any], let name = object["output"] as? String {
                return .output(name)
            }
            return .output("")
        case "EventStream": return .eventStream
        case "Action":
            // niri's Action is a tagged enum ({"FocusColumnLeft":{}}); the
            // action vocabulary here is the line-based one the config and
            // the FIFO share, so the tag becomes that line. An extra
            // {"line": "..."} escape hatch carries arguments verbatim.
            if let object = payload as? [String: Any] {
                if let line = object["line"] as? String { return .action(line) }
                if let tag = object.keys.first {
                    var line = kebab(tag)
                    if let args = object[tag] as? [String: Any] {
                        // Positional-ish: niri's action payloads are small
                        // ({"index": 2}), and the line parser reads numbers
                        // and key=value alike.
                        for (k, v) in args.sorted(by: { $0.key < $1.key }) {
                            // BOOLEANS FIRST. JSONSerialization hands back
                            // __NSCFBoolean, and `as? Int` matches it (true
                            // becomes 1) - so Quit{skip_confirmation:true}
                            // and MoveWindowToWorkspace{focus:true} flattened
                            // to a positional 1 that the handler read as a
                            // workspace NUMBER. Verified empirically before
                            // the fix: the window went to workspace 1, with
                            // an {"Ok":"Handled"} reply.
                            if isJSONBool(v), let b = v as? Bool {
                                line += " \(kebab(k))=\(b)"
                            } else if let n = v as? Int {
                                // niri's window-targeting payloads carry
                                // {"id": N} and the line vocabulary spells
                                // that id=N (close-window id=5). Flattened
                                // positionally, the handler's kvArg("id")
                                // never saw it and CloseWindow{id} closed
                                // the FOCUSED window instead. window_id is
                                // kv for the same reason: positional, it was
                                // read as the WORKSPACE number. Index-like
                                // args (FocusColumn {index}) stay positional.
                                line +=
                                    k == "id" ? " id=\(n)" : k == "window_id" ? " window-id=\(n)" : " \(n)"
                            } else if let d = v as? Double {
                                line += " \(trimNumber(d))"
                            } else if let s = v as? String {
                                line += " \(s)"
                            } else if let items = v as? [Any] {
                                // Spawn{command: ["cmd","arg"]} - argv as a
                                // JSON array. Dropped entirely before: no
                                // branch matched an array, so `spawn` arrived
                                // bare and no-opped with an Ok reply.
                                line += items.map { item in " \(item)" }.joined()
                            } else if let ref = v as? [String: Any], let (rk, rv) = ref.first {
                                // Two dict shapes. niri's SizeChange
                                // ({SetProportion: 50.0} etc., lib.rs:751-765)
                                // maps to its own string form, the one
                                // SizeChange.parse reads - flattened as
                                // set-proportion=50.0 it parsed to nil and
                                // the action no-opped with an Ok reply.
                                if let change = sizeChangeArg(rk, rv) {
                                    line += " \(change)"
                                } else {
                                    // A reference arg ({Id: 5} / {Index: 2} /
                                    // {Name: "x"}), e.g. FocusWorkspace's -
                                    // key=value so the handler resolves it.
                                    line += " \(kebab(rk))=\(rv)"
                                }
                            }
                            // NSNull (window_id: null) is deliberately dropped.
                        }
                    }
                    return .action(line)
                }
            }
            if let line = payload as? String { return .action(kebab(line)) }
            return .unknown(key)
        default: return .unknown(key)
        }
    }

    // FocusColumnLeft -> focus-column-left, skip_confirmation ->
    // skip-confirmation. niri names actions in CamelCase over IPC and in
    // kebab-case in the config, and its payload FIELDS are snake_case on the
    // wire (serde) - one vocabulary, three spellings.
    static func kebab(_ camel: String) -> String {
        var out = ""
        for (i, ch) in camel.enumerated() {
            if ch.isUppercase {
                if i > 0 { out.append("-") }
                out.append(Character(ch.lowercased()))
            } else if ch == "_" {
                out.append("-")
            } else {
                out.append(ch)
            }
        }
        return out
    }

    // True only for a real JSON boolean. `as? Bool` alone is not enough on
    // the other side of the coin either: NSNumber(1) also answers `as? Bool`
    // as true, so the type id is the only reliable discriminator.
    static func isJSONBool(_ v: Any) -> Bool {
        CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID()
    }

    // 50.0 -> "50", 33.5 -> "33.5": SizeChange.parse and the positional int
    // readers expect integer spellings for integer values.
    static func trimNumber(_ d: Double) -> String {
        d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
    }

    // niri's SizeChange over IPC is a tagged enum ({"SetProportion": 50.0},
    // {"AdjustFixed": -100}, lib.rs:751-765); its string form - what
    // SizeChange.parse and the config read - is "50%", "+10%", "500", "-100".
    static func sizeChangeArg(_ tag: String, _ value: Any) -> String? {
        let number: Double
        if isJSONBool(value) { return nil }
        if let d = value as? Double {
            number = d
        } else if let n = value as? Int {
            number = Double(n)
        } else {
            return nil
        }
        switch tag {
        case "SetProportion": return "\(trimNumber(number))%"
        case "SetFixed": return trimNumber(number)
        case "AdjustProportion": return number < 0 ? "\(trimNumber(number))%" : "+\(trimNumber(number))%"
        case "AdjustFixed": return number < 0 ? trimNumber(number) : "+\(trimNumber(number))"
        default: return nil
        }
    }
}

extension TilingEngine {
    // Reported by the Version request; bumped by hand with the protocol.
    static let version = "nigiri 0.1"

    // niri identifies outputs by connector name; macOS gives a display name.
    static func outputName(_ screen: NSScreen?) -> String? {
        screen?.localizedName
    }

    // ---- niri-shaped serialization ----

    // niri's Window: id, title, app_id, pid, workspace_id, is_focused,
    // is_floating, layout (niri-ipc/src/lib.rs, Window + WindowLayout).
    func niriWindow(
        _ w: ManagedWindow, workspace: Workspace, column: Int?, row: Int?, floating: Bool
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "id": Int(w.id),
            "title": w.title,
            "app_id": NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier ?? "",
            "pid": Int(w.pid),
            "workspace_id": Int(workspace.id),
            "is_focused": w === focusedManagedWindow(),
            "is_floating": floating,
            // Mandatory in niri's Window (is_urgent: bool, not an Option) - a
            // Rust client fails to deserialize the whole response without it.
            // No urgency machinery here yet, so honestly false.
            "is_urgent": false,
            // Option<Timestamp> upstream, fed by a debounced MRU tracker
            // nigiri doesn't have; null is the honest answer, and it keeps
            // strict clients deserializing.
            "focus_timestamp": NSNull(),
        ]
        entry["layout"] = niriWindowLayout(w, in: workspace, column: column, row: row)
        return entry
    }

    // niri's WindowLayout, field for field. This used to be an invented
    // {x,y,width,height} rect under niri's field name - the most
    // misleading kind of divergence, because the key promised a shape it
    // didn't have - plus invented top-level 0-based column/row (niri
    // encodes that as layout.pos_in_scrolling_layout, 1-based). The tile
    // and the window coincide here: nigiri's decorations are overlays
    // OUTSIDE the window, not part of a tile, so tile_size == window
    // size and the offset within the tile is zero.
    func niriWindowLayout(_ w: ManagedWindow, in ws: Workspace, column: Int?, row: Int?) -> [String: Any] {
        let frame = WindowMover.currentFrame(w.axElement)
        let pos: Any = (column != nil && row != nil) ? [column! + 1, row! + 1] : NSNull()
        // tile_pos_in_workspace_view is relative to the WORKSPACE VIEW (the
        // same view gradients' relative-to means, lib.rs:1417-1420), not an
        // absolute screen position. On the active workspace that view IS
        // the working area, so the origin subtracts out; a parked window's
        // AX position is a parking spot, not a view position - the field is
        // an Option upstream, and null beats garbage.
        let onActiveWorkspace =
            workspaces.indices.contains(activeWorkspaceIndex)
            && ws === workspaces[activeWorkspaceIndex]
        let tilePos: Any
        if let frame, onActiveWorkspace {
            let origin = usableScreen().frame.origin
            tilePos = [Double(frame.origin.x - origin.x), Double(frame.origin.y - origin.y)]
        } else {
            tilePos = NSNull()
        }
        return [
            "pos_in_scrolling_layout": pos,
            "tile_size": [Double(frame?.width ?? 0), Double(frame?.height ?? 0)],
            "window_size": [Int(frame?.width ?? 0), Int(frame?.height ?? 0)],
            "tile_pos_in_workspace_view": tilePos,
            "window_offset_in_tile": [0.0, 0.0],
        ]
    }

    // The one Window serializer for the single-window replies. The
    // hand-rolled partial coordinates (FocusedWindow with row: nil,
    // PickWindow with both nil) made the SAME window answer
    // pos_in_scrolling_layout differently per request; upstream serves one
    // Window everywhere (server.rs:337-342).
    func niriWindowLocated(_ w: ManagedWindow) -> [String: Any]? {
        guard let location = locate(w) else { return nil }
        switch location {
        case .tiled(let ws, let column, let row):
            return niriWindow(w, workspace: workspaces[ws], column: column, row: row, floating: false)
        case .floating(let ws, _):
            return niriWindow(w, workspace: workspaces[ws], column: nil, row: nil, floating: true)
        }
    }

    func niriWindows() -> [[String: Any]] {
        var result: [[String: Any]] = []
        for ws in workspaces {
            for (ci, column) in ws.columns.enumerated() {
                for (ri, w) in column.windows.enumerated() {
                    result.append(niriWindow(w, workspace: ws, column: ci, row: ri, floating: false))
                }
            }
            for w in ws.floatingWindows {
                result.append(niriWindow(w, workspace: ws, column: nil, row: nil, floating: true))
            }
        }
        return result
    }

    // niri's Workspace: id, idx (1-based per output), name, output,
    // is_active (per output), is_focused (active AND on the focused
    // output), active_window_id.
    func niriWorkspace(
        _ ws: Workspace, index: Int, output: Output, focusedOutput: Bool
    ) -> [String: Any] {
        let active = index == output.activeWorkspaceIndex
        var entry: [String: Any] = [
            "id": Int(ws.id),
            "idx": index + 1,
            "name": ws.name as Any,
            // The workspace's OWN output - it used to claim the first
            // screen for every workspace regardless of where it lived.
            "output": output.name,
            "is_active": active,
            "is_focused": active && focusedOutput,
            // niri reports urgency per workspace; no urgency machinery here
            // yet (backlog 38), so honestly false rather than absent.
            "is_urgent": false,
        ]
        // niri fills active_window_id for EVERY workspace (each tracks its
        // own focus), not only the active one.
        if let id = activeWindowId(of: ws) { entry["active_window_id"] = Int(id) }
        return entry
    }

    // ALL outputs' workspaces, like upstream's Workspaces reply - not just
    // the focused output's.
    func niriWorkspaces() -> [[String: Any]] {
        var entries: [[String: Any]] = []
        for (oi, output) in outputs.enumerated() {
            for (wi, ws) in output.workspaces.enumerated() {
                entries.append(
                    niriWorkspace(ws, index: wi, output: output, focusedOutput: oi == focusedOutputIndex))
            }
        }
        return entries
    }

    // niri's Output struct, field for field (niri-ipc/lib.rs:1210): the
    // invented is_focused is gone (niri's Output has no such field), and
    // the mode/vrr fields answer honestly for a display macOS abstracts
    // away. Single Output object; the map shape is built at the request.
    func niriOutput(_ screen: NSScreen, index: Int) -> [String: Any] {
        let frame = screen.frame
        let name = Self.outputName(screen) ?? "display-\(index)"
        return [
            "name": name,
            "make": "Apple",
            "model": name,
            "serial": NSNull(),
            "physical_size": NSNull(),
            "modes": [[String: Any]](),
            "current_mode": NSNull(),
            "is_custom_mode": false,
            "vrr_supported": false,
            "vrr_enabled": false,
            "logical": [
                "x": Int(frame.origin.x), "y": Int(frame.origin.y),
                "width": Int(frame.width), "height": Int(frame.height),
                "scale": Double(screen.backingScaleFactor),
                // niri's Transform enum has NO rename_all: the wire format is
                // "Normal"/"Flipped"/"Flipped90" (only the rotations rename to
                // "90"/"180"/"270"). Lowercase "normal" is the CONFIG spelling
                // and fails deserialization in real clients.
                "transform": "Normal",
            ],
        ]
    }

    func niriOutputs() -> [[String: Any]] {
        NSScreen.screens.enumerated().map { index, screen in niriOutput(screen, index: index) }
    }

    // ---- requests ----

    func handleMsgRequest(_ line: String) -> String {
        let parsed = NiriProtocol.parse(line)
        switch parsed.request {
        case .version:
            // niri's Response::Version is a bare STRING ({"Ok":{"Version":
            // "25.05"}}), not an object (niri-ipc/lib.rs:140).
            return ok(["Version": Self.version], legacy: parsed.legacy)
        case .windows:
            return parsed.legacy ? jsonLine(windowsSnapshot()) : ok(["Windows": niriWindows()], legacy: false)
        case .workspaces:
            return parsed.legacy
                ? jsonLine(workspacesSnapshot()) : ok(["Workspaces": niriWorkspaces()], legacy: false)
        case .focusedWindow:
            guard let w = focusedManagedWindow() else {
                return parsed.legacy ? "null" : ok(["FocusedWindow": NSNull()], legacy: false)
            }
            if parsed.legacy {
                return jsonLine(
                    windowSnapshot(
                        w, workspaceIndex: activeWorkspaceIndex,
                        column: workspace.isFloatingActive ? nil : workspace.focusedIndex,
                        row: nil, floating: workspace.isFloatingActive))
            }
            return ok(["FocusedWindow": niriWindowLocated(w).map { $0 as Any } ?? NSNull()], legacy: false)
        case .outputs:
            // niri's Response::Outputs is a MAP keyed by connector name
            // (HashMap<String, Output>, lib.rs:145), not an array.
            var byName: [String: Any] = [:]
            for output in niriOutputs() { byName[output["name"] as? String ?? "?"] = output }
            return ok(["Outputs": byName], legacy: parsed.legacy)
        case .focusedOutput:
            return ok(["FocusedOutput": niriOutputs().first as Any], legacy: parsed.legacy)
        case .overviewState:
            return ok(["OverviewState": ["is_open": isOverviewActive]], legacy: parsed.legacy)
        case .pickWindow:
            // niri blocks until the user clicks a window. Doing that here
            // would mean holding a socket open across an interactive pick;
            // the honest answer is the window under the cursor right now.
            let point = NSEvent.mouseLocation
            guard let primary = NSScreen.screens.first else {
                return err("no display", legacy: parsed.legacy)
            }
            let axPoint = CGPoint(x: point.x, y: primary.frame.height - point.y)
            guard let hit = windowUnderPoint(axPoint), let entry = niriWindowLocated(hit.window)
            else {
                return ok(["PickedWindow": NSNull()], legacy: parsed.legacy)
            }
            return ok(["PickedWindow": entry], legacy: parsed.legacy)
        case .layers:
            // No layer-shell on macOS: an empty list is the honest answer,
            // in the exact shape server.rs:290-330 builds.
            return ok(["Layers": [[String: Any]]()], legacy: parsed.legacy)
        case .keyboardLayouts:
            return ok(["KeyboardLayouts": keyboardLayoutsPayload()], legacy: parsed.legacy)
        case .pickColor:
            // niri grabs the pointer and samples interactively; the capture
            // path here is async-to-main (ScreenCaptureKit), so a
            // synchronous sample would deadlock the request. Upstream's
            // "nothing picked" is null - honest over invented.
            print("pick-color: interactive sampling is not implemented; answering null")
            return ok(["PickedColor": NSNull()], legacy: parsed.legacy)
        case .returnError:
            // Verbatim upstream (server.rs:273).
            return err("example compositor error", legacy: parsed.legacy)
        case .casts:
            return ok(["Casts": [[String: Any]]()], legacy: parsed.legacy)
        case .output(let name):
            // Display modes/scale/rotation belong to macOS, not to nigiri:
            // an unknown target still answers OutputWasMissing faithfully
            // (OutputConfigChanged, lib.rs:1432-1437); an existing one gets
            // an honest Err instead of a fake Applied.
            let exists = NSScreen.screens.contains { Self.outputName($0) == name }
            if !exists {
                return ok(["OutputConfigChanged": "OutputWasMissing"], legacy: parsed.legacy)
            }
            return err("output configuration is not supported on macOS", legacy: parsed.legacy)
        case .action(let actionLine):
            // niri answers Err for an action it cannot parse or does not
            // support (src/ipc/server.rs:205-214, validate_action) - an
            // unconditional Ok here turned every client bug into silence.
            guard performAction(actionLine) else {
                return err("unknown or malformed action: \(actionLine)", legacy: parsed.legacy)
            }
            return parsed.legacy ? "{\"ok\":true}" : ok("Handled", legacy: false)
        case .eventStream:
            // The server owns the subscription; this branch is never reached
            // through here, but a client that asks twice gets a real answer.
            return ok("Handled", legacy: parsed.legacy)
        case .unknown(let what):
            return err("unknown request: \(what)", legacy: parsed.legacy)
        }
    }

    private func ok(_ payload: Any, legacy: Bool) -> String {
        legacy ? jsonLine(payload as? [String: Any] ?? ["value": payload]) : jsonLine(["Ok": payload])
    }

    private func err(_ message: String, legacy: Bool) -> String {
        legacy ? jsonLine(["error": message]) : jsonLine(["Err": message])
    }

    // The window whose frame contains this AX point, floating layer first
    // (it sits above the tiled one).
    func windowUnderPoint(_ point: CGPoint) -> (window: ManagedWindow, floating: Bool)? {
        for w in workspace.floatingWindows {
            if let frame = WindowMover.currentFrame(w.axElement), frame.contains(point) { return (w, true) }
        }
        for column in workspace.columns {
            for w in column.windows {
                if let frame = WindowMover.currentFrame(w.axElement), frame.contains(point) {
                    return (w, false)
                }
            }
        }
        return nil
    }

    // ---- events ----
    //
    // niri's event names, one key per event. The legacy short events
    // ({"event":"focus"}) go through broadcastLegacy to bare-word
    // subscribers ONLY: niri's stream carries exclusively Event enum JSON,
    // and a strict client dies on the first foreign line.

    func emitWindowChanged(_ w: ManagedWindow) {
        guard let entry = niriWindowLocated(w) else { return }
        msgServer.broadcast(jsonLine(["WindowOpenedOrChanged": ["window": entry]]))
    }

    // niri emits WindowOpenedOrChanged / WindowClosed per window; the model
    // here is rebuilt wholesale by relayout, so the events come from a diff
    // against the last broadcast rather than from a dozen mutation sites.
    // The snapshot covers everything niri's Window carries that can change:
    // a title-only diff (the original) silently swallowed workspace moves,
    // floating flips and column/row reshuffles, leaving IPC clients stale.
    func broadcastWindowDiff() {
        // settledFrame: the in-flight animation's TARGET when one exists
        // (the resting truth, no mid-flight noise), else the real frame.
        // NOT lastActualFrame - that is the refusal memo, nil by design for
        // well-behaved windows (applyFrame's isClose fast path never
        // memoizes), which kept this diff permanently blind to geometry.
        func rounded(_ f: CGRect?) -> CGRect? {
            f.map {
                CGRect(
                    x: $0.origin.x.rounded(), y: $0.origin.y.rounded(),
                    width: $0.width.rounded(), height: $0.height.rounded())
            }
        }
        var seen: [UInt64: WindowBroadcastSnapshot] = [:]
        for ws in workspaces {
            for (ci, column) in ws.columns.enumerated() {
                for (ri, w) in column.windows.enumerated() {
                    seen[w.id] = WindowBroadcastSnapshot(
                        title: w.title, workspaceId: ws.id, floating: false, column: ci, row: ri,
                        frame: rounded(settledFrame(of: w)))
                }
            }
            for w in ws.floatingWindows {
                seen[w.id] = WindowBroadcastSnapshot(
                    title: w.title, workspaceId: ws.id, floating: true, column: nil, row: nil,
                    frame: rounded(settledFrame(of: w)))
            }
        }
        let diff = WindowBroadcastDiff.changes(old: lastBroadcastWindows, new: seen)
        for id in diff.changed {
            if let w = windowWithID(id) { emitWindowChanged(w) }
        }
        // Geometry-only movement batches into ONE WindowLayoutsChanged with
        // (id, WindowLayout) pairs, exactly upstream's shape (a serde tuple
        // is a two-element array on the wire).
        let layoutPairs: [[Any]] = diff.layoutChanged.compactMap { id in
            guard let w = windowWithID(id), let location = locate(w) else { return nil }
            switch location {
            case .tiled(let ws, let column, let row):
                return [Int(id), niriWindowLayout(w, in: workspaces[ws], column: column, row: row)]
            case .floating(let ws, _):
                return [Int(id), niriWindowLayout(w, in: workspaces[ws], column: nil, row: nil)]
            }
        }
        if !layoutPairs.isEmpty {
            msgServer.broadcast(jsonLine(["WindowLayoutsChanged": ["changes": layoutPairs]]))
        }
        for id in diff.closed { emitWindowClosed(id) }
        lastBroadcastWindows = seen
        broadcastWorkspaceActiveWindowDiff()
    }

    // Which window a workspace considers active - its own focus state, valid
    // even while the workspace is not the active one (niri tracks the same).
    func activeWindowId(of ws: Workspace) -> UInt64? {
        guard ws.columns.indices.contains(ws.focusedIndex) else {
            return ws.floatingWindows.first?.id
        }
        return ws.columns[ws.focusedIndex].focusedWindow?.id
    }

    // niri's WorkspaceActiveWindowChanged: emitted whenever a workspace's
    // active window changes, including workspaces that are not focused.
    func broadcastWorkspaceActiveWindowDiff() {
        var current: [UInt64: UInt64] = [:]
        for ws in workspaces {
            if let id = activeWindowId(of: ws) { current[ws.id] = id }
        }
        for ws in workspaces {
            let previous = lastBroadcastActiveWindows[ws.id]
            let now = current[ws.id]
            if previous != now {
                msgServer.broadcast(
                    jsonLine([
                        "WorkspaceActiveWindowChanged": [
                            "workspace_id": Int(ws.id),
                            "active_window_id": now.map(Int.init) as Any,
                        ]
                    ]))
            }
        }
        lastBroadcastActiveWindows = current
    }

    func windowWithID(_ id: UInt64) -> ManagedWindow? {
        for ws in workspaces {
            for column in ws.columns {
                if let w = column.windows.first(where: { $0.id == id }) { return w }
            }
            if let w = ws.floatingWindows.first(where: { $0.id == id }) { return w }
        }
        return nil
    }

    func emitWindowClosed(_ id: UInt64) {
        msgServer.broadcast(jsonLine(["WindowClosed": ["id": Int(id)]]))
    }

    func emitWindowFocusChanged(_ w: ManagedWindow?) {
        msgServer.broadcast(jsonLine(["WindowFocusChanged": ["id": w.map { Int($0.id) } as Any]]))
    }

    func emitWorkspacesChanged() {
        msgServer.broadcast(jsonLine(["WorkspacesChanged": ["workspaces": niriWorkspaces()]]))
    }

    // `focused` distinguishes an activation that carries keyboard focus
    // from a workspace merely becoming active on a non-focused output
    // (server.rs:643-651). The single-focused-workspace model here means
    // every activation today carries focus - but the CALLER states that,
    // instead of the wire field being hardwired.
    func emitWorkspaceActivated(_ index: Int, focused: Bool) {
        guard workspaces.indices.contains(index) else { return }
        msgServer.broadcast(
            jsonLine(["WorkspaceActivated": ["id": Int(workspaces[index].id), "focused": focused]]))
    }

    // niri's KeyboardLayouts (lib.rs:1483-1488): the configured layouts and
    // the active index. The macOS analog of xkb's configured layouts is the
    // set of enabled keyboard input sources.
    func keyboardLayoutsPayload() -> [String: Any] {
        let (names, current) = TilingEngine.keyboardInputSources()
        return ["names": names, "current_idx": current]
    }

    nonisolated static func keyboardInputSources() -> ([String], Int) {
        let filter =
            [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource] as CFDictionary
        func name(_ s: TISInputSource) -> String? {
            guard let raw = TISGetInputSourceProperty(s, kTISPropertyLocalizedName) else { return nil }
            return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        }
        guard
            let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue()
                as? [TISInputSource]
        else { return (["unknown"], 0) }
        let names = list.compactMap(name)
        var current = 0
        if let active = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
            let activeName = name(active), let idx = names.firstIndex(of: activeName)
        {
            current = idx
        }
        return (names.isEmpty ? ["unknown"] : names, current)
    }

    // niri's KeyboardLayoutsChanged vs KeyboardLayoutSwitched: the SET
    // changing broadcasts the former, the active index the latter
    // (lib.rs:1690-1701). Called from the input-source observer.
    func emitKeyboardLayoutChange() {
        let (names, current) = TilingEngine.keyboardInputSources()
        if names != lastKeyboardLayoutNames {
            lastKeyboardLayoutNames = names
            msgServer.broadcast(
                jsonLine([
                    "KeyboardLayoutsChanged": [
                        "keyboard_layouts": ["names": names, "current_idx": current]
                    ]
                ]))
        } else {
            msgServer.broadcast(jsonLine(["KeyboardLayoutSwitched": ["idx": current]]))
        }
    }

    // niri's switch-layout next/prev (Action::SwitchLayout): the macOS
    // analog cycles the enabled keyboard input sources via TIS. Returns
    // whether a switch happened; the observer then broadcasts
    // KeyboardLayoutSwitched like any external change.
    func switchKeyboardLayout(_ target: String) -> Bool {
        let filter =
            [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource] as CFDictionary
        guard
            let all = TISCreateInputSourceList(filter, false)?.takeRetainedValue()
                as? [TISInputSource]
        else { return false }
        func selectable(_ s: TISInputSource) -> Bool {
            guard let raw = TISGetInputSourceProperty(s, kTISPropertyInputSourceIsSelectCapable)
            else { return false }
            return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
        }
        let list = all.filter(selectable)
        guard list.count > 1 else { return !list.isEmpty }
        func sourceID(_ s: TISInputSource) -> String? {
            guard let raw = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else {
                return nil
            }
            return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        }
        let currentID = TISCopyCurrentKeyboardInputSource().map { sourceID($0.takeRetainedValue()) }
        let currentIdx = list.firstIndex { sourceID($0) == currentID } ?? 0
        let next: Int
        switch target {
        case "prev", "Prev", "previous": next = (currentIdx - 1 + list.count) % list.count
        case "next", "Next": next = (currentIdx + 1) % list.count
        default:
            // niri also takes an index (LayoutSwitchTarget::Index, 0-based).
            guard let idx = Int(target), list.indices.contains(idx) else { return false }
            next = idx
        }
        return TISSelectInputSource(list[next]) == noErr
    }

    // niri's ScreenshotCaptured (lib.rs): path when written to disk, null
    // for a clipboard-only capture.
    func emitScreenshotCaptured(path: String?) {
        msgServer.broadcast(
            jsonLine(["ScreenshotCaptured": ["path": path.map { $0 as Any } ?? NSNull()]]))
    }

    func emitOverviewChanged(_ open: Bool) {
        msgServer.broadcast(jsonLine(["OverviewOpenedOrClosed": ["is_open": open]]))
    }

    // niri broadcasts ConfigLoaded on every reload attempt, success or
    // failure (src/ipc/server.rs).
    func emitConfigLoaded() {
        msgServer.broadcast(jsonLine(["ConfigLoaded": ["failed": configLoadFailed]]))
    }

    // The whole current state as a list of the same event lines a subscriber
    // would have received to reach it: every workspace, every window, the
    // focused window, the overview flag. Replayed once to each new event-stream
    // subscriber (MsgServer.onSubscribe) so a client is fully populated before
    // the first live change and never has to poll a separate snapshot - the
    // way niri seeds its own event stream.
    // Every window as a niri Window entry, in workspace/column order.
    func allNiriWindows() -> [[String: Any]] {
        var entries: [[String: Any]] = []
        for ws in workspaces {
            for (ci, column) in ws.columns.enumerated() {
                for (ri, w) in column.windows.enumerated() {
                    entries.append(niriWindow(w, workspace: ws, column: ci, row: ri, floating: false))
                }
            }
            for w in ws.floatingWindows {
                entries.append(niriWindow(w, workspace: ws, column: nil, row: nil, floating: true))
            }
        }
        return entries
    }

    func currentStateLines() -> [String] {
        // niri's replicate() order, member for member (niri-ipc/src/
        // state.rs:96-106): workspaces, windows, keyboard layouts, overview,
        // config, casts. ConfigLoaded is always present (clients wait for it
        // before rendering) - fifth, not first; the WindowFocusChanged that
        // used to ride along is NOT part of upstream's seed - the focus
        // arrives inside WindowsChanged's is_focused fields.
        var lines: [String] = []
        lines.append(jsonLine(["WorkspacesChanged": ["workspaces": niriWorkspaces()]]))
        // niri seeds a new subscriber with ONE bulk WindowsChanged, not a
        // window-by-window replay - the bulk is also the only sane way for a
        // client to drop windows that vanished while it was disconnected.
        lines.append(jsonLine(["WindowsChanged": ["windows": allNiriWindows()]]))
        lines.append(
            jsonLine(["KeyboardLayoutsChanged": ["keyboard_layouts": keyboardLayoutsPayload()]]))
        lines.append(jsonLine(["OverviewOpenedOrClosed": ["is_open": isOverviewActive]]))
        lines.append(jsonLine(["ConfigLoaded": ["failed": configLoadFailed]]))
        lines.append(jsonLine(["CastsChanged": ["casts": [[String: Any]]()]]))
        return lines
    }
}

// The per-window broadcast state: everything niri's Window event carries
// that can change. Pure and Equatable so the diff below is selftestable.
struct WindowBroadcastSnapshot: Equatable {
    let title: String
    let workspaceId: UInt64
    let floating: Bool
    let column: Int?
    let row: Int?
    // The last frame applyFrame saw the app ACCEPT, rounded - a cached
    // answer, deliberately not a fresh AX read (the diff runs after every
    // action and must stay a pure model walk). A geometry-only change
    // broadcasts WindowLayoutsChanged, the event clients size their
    // previews from (server.rs:734-765) - it never fired before.
    let frame: CGRect?
}

enum WindowBroadcastDiff {
    // Which windows need a WindowOpenedOrChanged (new or any field changed)
    // and which need a WindowClosed (gone).
    static func changes(
        old: [UInt64: WindowBroadcastSnapshot], new: [UInt64: WindowBroadcastSnapshot]
    ) -> (changed: [UInt64], layoutChanged: [UInt64], closed: [UInt64]) {
        var changed: [UInt64] = []
        var layoutChanged: [UInt64] = []
        for (id, snapshot) in new {
            guard let previous = old[id] else {
                changed.append(id)
                continue
            }
            if previous == snapshot { continue }
            // Same everything but the frame: niri broadcasts that as
            // WindowLayoutsChanged, not a full WindowOpenedOrChanged.
            let onlyFrame =
                previous.title == snapshot.title && previous.workspaceId == snapshot.workspaceId
                && previous.floating == snapshot.floating && previous.column == snapshot.column
                && previous.row == snapshot.row
            if onlyFrame { layoutChanged.append(id) } else { changed.append(id) }
        }
        var closed: [UInt64] = []
        for id in old.keys where new[id] == nil {
            closed.append(id)
        }
        return (changed.sorted(), layoutChanged.sorted(), closed.sorted())
    }
}

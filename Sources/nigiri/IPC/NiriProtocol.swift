import AppKit
import Foundation

// niri's IPC shape (niri-ipc/src/lib.rs), so a client written against niri
// works here unmodified: a JSON request in, {"Ok": <reply>} / {"Err": "..."}
// out, and events as single-key objects.
//
// The old bare-word requests (windows, workspaces, focused-window,
// action <line>) still answer, in their old flat shape: scripts already
// written against nigiri must not break.
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
        // nigiri-only diagnostics: the live reservation table and the
        // strut-adjusted usable frame - the state that silently shapes every
        // layout and used to be unobservable from outside.
        case struts
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
        case "struts": return Parsed(request: .struts, legacy: true)
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
                            if let n = v as? Int {
                                line += " \(n)"
                            } else if let s = v as? String {
                                line += " \(s)"
                            } else if let b = v as? Bool {
                                line += " \(kebab(k))=\(b)"
                            } else if let ref = v as? [String: Any], let (rk, rv) = ref.first {
                                // A niri reference arg ({Id: 5} / {Index: 2} /
                                // {Name: "x"}), e.g. FocusWorkspace's - carry the
                                // inner tag and value as key=value so the action
                                // handler can resolve it (id=5, index=2, name=x).
                                line += " \(kebab(rk))=\(rv)"
                            }
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

    // FocusColumnLeft -> focus-column-left. niri names actions in CamelCase
    // over IPC and in kebab-case in the config; one vocabulary, two spellings.
    static func kebab(_ camel: String) -> String {
        var out = ""
        for (i, ch) in camel.enumerated() {
            if ch.isUppercase {
                if i > 0 { out.append("-") }
                out.append(Character(ch.lowercased()))
            } else {
                out.append(ch)
            }
        }
        return out
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
    // is_floating, plus the layout position this compositor actually has.
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
        ]
        if let column { entry["column"] = column }
        if let row { entry["row"] = row }
        if let frame = WindowMover.currentFrame(w.axElement) {
            entry["layout"] = [
                "x": Int(frame.origin.x), "y": Int(frame.origin.y),
                "width": Int(frame.width), "height": Int(frame.height),
            ]
        }
        return entry
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

    // niri's Workspace: id, idx (1-based), name, output, is_active,
    // is_focused, active_window_id.
    func niriWorkspace(_ ws: Workspace, index: Int) -> [String: Any] {
        let active = index == activeWorkspaceIndex
        var entry: [String: Any] = [
            "id": Int(ws.id),
            "idx": index + 1,
            "name": ws.name as Any,
            "output": Self.outputName(NSScreen.screens.first) as Any,
            "is_active": active,
            "is_focused": active,
        ]
        if active, let focused = focusedManagedWindow() { entry["active_window_id"] = Int(focused.id) }
        return entry
    }

    func niriWorkspaces() -> [[String: Any]] {
        workspaces.enumerated().map { niriWorkspace($1, index: $0) }
    }

    // niri's Output. macOS is single-display here (multi-monitor is not
    // implemented), so this reports the one nigiri lays out on.
    func niriOutputs() -> [[String: Any]] {
        NSScreen.screens.enumerated().map { index, screen in
            let frame = screen.frame
            return [
                "name": Self.outputName(screen) ?? "display-\(index)",
                "make": "Apple",
                "model": Self.outputName(screen) ?? "display-\(index)",
                "logical": [
                    "x": Int(frame.origin.x), "y": Int(frame.origin.y),
                    "width": Int(frame.width), "height": Int(frame.height),
                    "scale": Double(screen.backingScaleFactor),
                ],
                "is_focused": index == 0,
            ]
        }
    }

    // ---- requests ----

    func handleMsgRequest(_ line: String) -> String {
        let parsed = NiriProtocol.parse(line)
        switch parsed.request {
        case .version:
            return ok(["Version": ["version": Self.version]], legacy: parsed.legacy)
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
            return ok(
                [
                    "FocusedWindow": niriWindow(
                        w, workspace: workspace,
                        column: workspace.isFloatingActive ? nil : workspace.focusedIndex,
                        row: nil, floating: workspace.isFloatingActive)
                ], legacy: false)
        case .outputs:
            return ok(["Outputs": niriOutputs()], legacy: parsed.legacy)
        case .focusedOutput:
            return ok(["FocusedOutput": niriOutputs().first as Any], legacy: parsed.legacy)
        case .overviewState:
            return ok(["OverviewState": ["is_open": isOverviewActive]], legacy: parsed.legacy)
        case .struts:
            let usable = usableScreen().frame
            let entries = reservedStruts.map { id, strut -> [String: Any] in
                [
                    "id": id, "edge": strut.edge.rawValue, "size": strut.size,
                    "pid": strut.ownerPid.map(Int.init) as Any,
                ]
            }
            return ok(
                [
                    "struts": entries,
                    "usable": [
                        "x": usable.origin.x, "y": usable.origin.y,
                        "width": usable.width, "height": usable.height,
                    ],
                ], legacy: parsed.legacy)
        case .pickWindow:
            // niri blocks until the user clicks a window. Doing that here
            // would mean holding a socket open across an interactive pick;
            // the honest answer is the window under the cursor right now.
            let point = NSEvent.mouseLocation
            guard let primary = NSScreen.screens.first else {
                return err("no display", legacy: parsed.legacy)
            }
            let axPoint = CGPoint(x: point.x, y: primary.frame.height - point.y)
            guard let hit = windowUnderPoint(axPoint), let location = locate(hit.window) else {
                return ok(["PickedWindow": NSNull()], legacy: parsed.legacy)
            }
            return ok(
                [
                    "PickedWindow": niriWindow(
                        hit.window, workspace: workspaces[location.workspaceIndex],
                        column: nil, row: nil, floating: hit.floating)
                ], legacy: parsed.legacy)
        case .action(let actionLine):
            performAction(actionLine)
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
    // ({"event":"focus"}) are still broadcast alongside, so existing
    // subscribers keep working.

    func emitWindowChanged(_ w: ManagedWindow) {
        guard let location = locate(w) else { return }
        let entry: [String: Any]
        switch location {
        case .tiled(let ws, let column, let row):
            entry = niriWindow(w, workspace: workspaces[ws], column: column, row: row, floating: false)
        case .floating(let ws, _):
            entry = niriWindow(w, workspace: workspaces[ws], column: nil, row: nil, floating: true)
        }
        msgServer.broadcast(jsonLine(["WindowOpenedOrChanged": ["window": entry]]))
    }

    // niri emits WindowOpenedOrChanged / WindowClosed per window; the model
    // here is rebuilt wholesale by relayout, so the events come from a diff
    // against the last broadcast rather than from a dozen mutation sites.
    // The snapshot covers everything niri's Window carries that can change:
    // a title-only diff (the original) silently swallowed workspace moves,
    // floating flips and column/row reshuffles, leaving IPC clients stale.
    func broadcastWindowDiff() {
        var seen: [UInt64: WindowBroadcastSnapshot] = [:]
        for ws in workspaces {
            for (ci, column) in ws.columns.enumerated() {
                for (ri, w) in column.windows.enumerated() {
                    seen[w.id] = WindowBroadcastSnapshot(
                        title: w.title, workspaceId: ws.id, floating: false, column: ci, row: ri)
                }
            }
            for w in ws.floatingWindows {
                seen[w.id] = WindowBroadcastSnapshot(
                    title: w.title, workspaceId: ws.id, floating: true, column: nil, row: nil)
            }
        }
        let diff = WindowBroadcastDiff.changes(old: lastBroadcastWindows, new: seen)
        for id in diff.changed {
            if let w = windowWithID(id) { emitWindowChanged(w) }
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

    func emitWorkspaceActivated(_ index: Int) {
        guard workspaces.indices.contains(index) else { return }
        msgServer.broadcast(
            jsonLine(["WorkspaceActivated": ["id": Int(workspaces[index].id), "focused": true]]))
    }

    func emitOverviewChanged(_ open: Bool) {
        msgServer.broadcast(jsonLine(["OverviewOpenedOrClosed": ["is_open": open]]))
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
        var lines: [String] = []
        lines.append(jsonLine(["WorkspacesChanged": ["workspaces": niriWorkspaces()]]))
        // niri seeds a new subscriber with ONE bulk WindowsChanged, not a
        // window-by-window replay - the bulk is also the only sane way for a
        // client to drop windows that vanished while it was disconnected.
        lines.append(jsonLine(["WindowsChanged": ["windows": allNiriWindows()]]))
        lines.append(
            jsonLine(["WindowFocusChanged": ["id": focusedManagedWindow().map { Int($0.id) } as Any]]))
        lines.append(jsonLine(["OverviewOpenedOrClosed": ["is_open": isOverviewActive]]))
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
}

enum WindowBroadcastDiff {
    // Which windows need a WindowOpenedOrChanged (new or any field changed)
    // and which need a WindowClosed (gone).
    static func changes(
        old: [UInt64: WindowBroadcastSnapshot], new: [UInt64: WindowBroadcastSnapshot]
    ) -> (changed: [UInt64], closed: [UInt64]) {
        var changed: [UInt64] = []
        for (id, snapshot) in new where old[id] != snapshot {
            changed.append(id)
        }
        var closed: [UInt64] = []
        for id in old.keys where new[id] == nil {
            closed.append(id)
        }
        return (changed.sorted(), closed.sorted())
    }
}

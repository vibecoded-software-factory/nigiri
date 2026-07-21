import AppKit
import Foundation

// IPC state snapshots (nigiri msg): windows/workspaces/focused-window as JSON.
extension TilingEngine {
    // ---- IPC queries and events (niri msg) ----

    func jsonLine(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    func windowSnapshot(_ w: ManagedWindow, workspaceIndex: Int, column: Int?, row: Int?, floating: Bool) -> [String: Any] {
        var entry: [String: Any] = [
            "title": w.title,
            "pid": Int(w.pid),
            "workspace": workspaceIndex + 1,
            "floating": floating,
            "focused": workspaceIndex == activeWorkspaceIndex && w === focusedManagedWindow(),
        ]
        if let column { entry["column"] = column }
        if let row { entry["row"] = row }
        if let frame = WindowMover.currentFrame(w.axElement) {
            entry["frame"] = ["x": Int(frame.origin.x), "y": Int(frame.origin.y), "w": Int(frame.width), "h": Int(frame.height)]
        }
        return entry
    }

    func windowsSnapshot() -> [[String: Any]] {
        var result: [[String: Any]] = []
        for (wi, ws) in workspaces.enumerated() {
            for (ci, column) in ws.columns.enumerated() {
                for (ri, w) in column.windows.enumerated() {
                    result.append(windowSnapshot(w, workspaceIndex: wi, column: ci, row: ri, floating: false))
                }
            }
            for w in ws.floatingWindows {
                result.append(windowSnapshot(w, workspaceIndex: wi, column: nil, row: nil, floating: true))
            }
        }
        return result
    }

    func workspacesSnapshot() -> [[String: Any]] {
        workspaces.enumerated().map { i, ws in
            [
                "index": i + 1,
                "name": ws.name as Any,
                "active": i == activeWorkspaceIndex,
                "columns": ws.columns.count,
                "windows": ws.columns.reduce(0) { $0 + $1.windows.count } + ws.floatingWindows.count,
            ]
        }
    }
}

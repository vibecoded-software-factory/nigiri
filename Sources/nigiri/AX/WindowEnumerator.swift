import AppKit
import ApplicationServices

struct WindowInfo {
    let appName: String
    let pid: pid_t
    let title: String
    let frame: CGRect
}

enum WindowEnumerator {
    static func listAllWindows() -> [WindowInfo] {
        var results: [WindowInfo] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let windows = AX.windows(ofPid: app.processIdentifier) else { continue }
            for w in windows {
                // A window that won't report a frame is skipped, not force-cast —
                // some panels/sheets return unexpected attribute shapes.
                guard let frame = WindowMover.currentFrame(w) else { continue }
                let title: String = AX.attribute(w, kAXTitleAttribute as String) ?? "(no title)"
                results.append(
                    WindowInfo(
                        appName: app.localizedName ?? "?", pid: app.processIdentifier, title: title,
                        frame: frame))
            }
        }
        return results
    }
}

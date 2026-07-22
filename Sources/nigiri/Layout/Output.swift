import AppKit

// A monitor. niri's model: every output owns its OWN stack of workspaces and
// its own active/previous index, and one output is focused at a time. nigiri
// was single-output (a flat workspace list on the primary display); this is the
// per-output container that makes the model multi-monitor.
//
// Identity is the CGDirectDisplayID, which is stable across relayouts and
// re-plugs of the same port - NSScreen instances are recreated on every
// reconfiguration and cannot be compared by reference. `screen` is re-resolved
// against the live NSScreen list whenever the display arrangement changes.
final class Output {
    let displayID: CGDirectDisplayID
    var name: String
    var screen: NSScreen?

    // The same flat model nigiri used to keep on the engine, moved here so each
    // output has its own. The engine's `workspaces`/`activeWorkspaceIndex`/
    // `previousWorkspaceIndex`/`workspace` are now proxies onto the FOCUSED
    // output, so every existing single-output call site keeps working unchanged.
    var workspaces: [Workspace] = [Workspace()]
    var activeWorkspaceIndex = 0
    var previousWorkspaceIndex = 0
    var activeWorkspace: Workspace { workspaces[activeWorkspaceIndex] }

    init(displayID: CGDirectDisplayID, name: String, screen: NSScreen?) {
        self.displayID = displayID
        self.name = name
        self.screen = screen
    }

    // The display id macOS assigns this screen, or nil if the description is
    // missing it (has not been observed in practice, but the key is optional).
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }
}

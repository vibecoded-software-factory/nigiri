import AppKit
import Foundation

// niri's screenshot actions, on top of /usr/sbin/screencapture (the only
// public path to a screen bitmap that does not need its own capture grant
// wired through nigiri's own process).
extension TilingEngine {
    enum ShotKind {
        case interactive  // niri's `screenshot`: pick a region
        case screen  // `screenshot-screen`
        case window  // `screenshot-window`: the focused window
    }

    // screenshot-path with strftime placeholders, ~ expanded. An empty path
    // means niri's "do not save to disk" - the clipboard still gets it.
    func expandedScreenshotPath() -> String? {
        let raw = screenshotPath.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        var t = time(nil)
        var tmVal = tm()
        localtime_r(&t, &tmVal)
        var buffer = [Int8](repeating: 0, count: 1024)
        let n = strftime(&buffer, buffer.count, raw, &tmVal)
        let formatted = n > 0 ? String(cString: buffer) : raw
        return NSString(string: formatted).expandingTildeInPath
    }

    func takeScreenshot(_ kind: ShotKind) {
        var args: [String] = []
        switch kind {
        case .interactive: args = ["-i"]
        case .screen: args = ["-x"]
        case .window:
            // No -l <windowid>: the AX API never exposes the CGWindowID, so
            // the focused window is captured by its rect instead.
            guard let window = focusedManagedWindow(),
                let frame = WindowMover.currentFrame(window.axElement)
            else {
                print("screenshot-window: no hay ventana enfocada")
                return
            }
            // -R takes AppKit's bottom-left screen space.
            guard let primary = NSScreen.screens.first else { return }
            let y = primary.frame.height - frame.maxY
            args = ["-x", "-R\(Int(frame.minX)),\(Int(y)),\(Int(frame.width)),\(Int(frame.height))"]
        }
        guard let path = expandedScreenshotPath() else {
            // No path configured: clipboard only, like niri.
            runScreencapture(args + ["-c"])
            print("screenshot -> portapapeles")
            return
        }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        runScreencapture(args + [path])
        print("screenshot -> \(path)")
    }

    private func runScreencapture(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = args
        process.environment = Self.spawnEnvironment()
        do { try process.run() } catch { print("screenshot: no se pudo ejecutar screencapture") }
    }
}

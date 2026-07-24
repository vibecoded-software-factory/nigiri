import AppKit
import Foundation

// niri's screenshot actions, on top of /usr/sbin/screencapture (the only
// public path to a screen bitmap that does not need its own capture grant
// wired through nigiri's own process).
//
// The action contract is niri's (niri-ipc/src/lib.rs:224-285):
// - the CLIPBOARD always gets the shot; `write-to-disk` (default true)
//   additionally saves it per screenshot-path / the `path` argument;
// - `show-pointer` defaults true for screen shots and false for window
//   shots, exactly upstream's defaults;
// - screenshot-window takes an optional `id`; screenshot-screen captures
//   the FOCUSED output, not the primary one.
// It used to save without copying, accept no arguments, and always shoot
// the primary display (audit ACT-7).
extension TilingEngine {
    enum ShotKind {
        case interactive  // niri's `screenshot`: pick a region
        case screen  // `screenshot-screen`
        case window  // `screenshot-window`
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

    func takeScreenshot(
        _ kind: ShotKind, id: UInt64? = nil, writeToDisk: Bool = true,
        showPointer: Bool? = nil, pathOverride: String? = nil
    ) {
        var args: [String] = []
        switch kind {
        case .interactive:
            args = ["-i"]
        case .screen:
            // The FOCUSED output (upstream screenshots the focused screen);
            // -D indexes NSScreen.screens 1-based.
            let index = focusedOutput.screen.flatMap { NSScreen.screens.firstIndex(of: $0) } ?? 0
            args = ["-x", "-D\(index + 1)"]
            // show-pointer defaults TRUE for the screen shot (lib.rs:246).
            if showPointer ?? true { args.append("-C") }
        case .window:
            // No -l <windowid>: the AX API never exposes the CGWindowID, so
            // the window is captured by its rect instead. niri's optional
            // `id` picks any window; nil is the focused one.
            guard let window = id.flatMap({ windowWithID($0) }) ?? focusedManagedWindow(),
                let frame = WindowMover.currentFrame(window.axElement)
            else {
                print("screenshot-window: no such window")
                return
            }
            // -R takes AppKit's bottom-left screen space.
            guard let primary = NSScreen.screens.first else { return }
            let y = primary.frame.height - frame.maxY
            args = ["-x", "-R\(Int(frame.minX)),\(Int(y)),\(Int(frame.width)),\(Int(frame.height))"]
            // show-pointer defaults FALSE for the window shot (lib.rs:275).
            if showPointer == true { args.append("-C") }
        }
        let path =
            pathOverride.map { NSString(string: $0).expandingTildeInPath }
            ?? expandedScreenshotPath()
        guard writeToDisk, let path else {
            // Clipboard only: disk writing disabled by argument or by
            // `screenshot-path null`. ScreenshotCaptured carries a null
            // path in that case (lib.rs, Event::ScreenshotCaptured).
            runScreencapture(args + ["-c"], announcing: .some(nil))
            print("screenshot -> clipboard")
            return
        }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        // Disk AND clipboard: screencapture writes one destination per run,
        // so the file lands first and the pasteboard is fed from it.
        runScreencapture(args + [path], thenCopyToClipboard: path, announcing: .some(path))
    }

    // `announcing` is the ScreenshotCaptured event's path payload: .some(p)
    // after a disk write, .some(nil) for clipboard-only, nil = no event
    // (nothing captured).
    private func runScreencapture(
        _ args: [String], thenCopyToClipboard path: String? = nil, announcing: String?? = nil
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = args
        process.environment = Self.spawnEnvironment()
        process.terminationHandler = { proc in
            DispatchQueue.main.async {
                if let path {
                    guard let image = NSImage(contentsOfFile: path) else {
                        // Interactive shots can be cancelled: no file, no shot.
                        print("screenshot: nothing captured")
                        return
                    }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects([image])
                    print("screenshot -> clipboard + \(path)")
                }
                // niri broadcasts ScreenshotCaptured after every successful
                // capture; a cancelled interactive run exits non-zero.
                if let announcing, proc.terminationStatus == 0 {
                    self.emitScreenshotCaptured(path: announcing)
                }
            }
        }
        do { try process.run() } catch { print("screenshot: could not run screencapture") }
    }
}

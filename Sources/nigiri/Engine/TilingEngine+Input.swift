import AppKit
import Foundation

// Input: spawn/spawn-sh, focus-follows-mouse, warp-mouse-to-focus.
extension TilingEngine {
    // niri's spawn: execvp with an argv ARRAY - no shell, so no word
    // splitting. `spawn open -a "Google Chrome"` must reach the exec as
    // THREE arguments; routing it through a shell after the config
    // tokenizer had already eaten the quotes turned it into
    // `open -a Google Chrome`, which opens nothing (verified: "the file
    // .../Chrome does not exist"). Quotes are honoured here too, so the
    // FIFO/socket path - which hands over a raw line - behaves the same.
    // Split respecting quotes - the config tokenizer drops the quote
    // characters, so `spawn open -a "Google Chrome"` has to survive as three
    // arguments (it collapsed to `open -a Google Chrome`, which opens
    // nothing).
    static func spawnArgv(_ command: String) -> [String] {
        var argv: [String] = []
        var current = ""
        var quote: Character? = nil
        for c in command {
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
            } else if c == "'" || c == "\"" {
                quote = c
            } else if c == " " || c == "\t" {
                if !current.isEmpty { argv.append(current); current = "" }
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { argv.append(current) }
        return argv
    }

    // niri's environment {}: variables layered over the inherited ones for
    // everything nigiri spawns. Empty value = unset, like niri.
    static func spawnEnvironment() -> [String: String]? {
        guard !spawnEnvironmentOverrides.isEmpty else { return nil }
        var env = ProcessInfo.processInfo.environment
        for (k, v) in spawnEnvironmentOverrides {
            if v.isEmpty { env.removeValue(forKey: k) } else { env[k] = v }
        }
        return env
    }
    nonisolated(unsafe) static var spawnEnvironmentOverrides: [String: String] = [:]

    func spawn(_ command: String) {
        let argv = Self.spawnArgv(command)
        guard let executable = argv.first else { return }
        let process = Process()
        process.environment = Self.spawnEnvironment()
        // A bare name (`open`, `alacritty`) resolves against PATH the way
        // execvp does; an absolute path is used as given.
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = Array(argv.dropFirst())
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = argv
        }
        do {
            try process.run()
            print("spawn: \(argv.joined(separator: " ⎵ "))")
        } catch {
            print("spawn failed: \(command)")
        }
    }

    // niri's spawn-sh: the whole line handed to a shell, pipes and all.
    func spawnShell(_ command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = Self.spawnEnvironment()
        do {
            try process.run()
            print("spawn: \(command)")
        } catch {
            print("spawn failed: \(command)")
        }
    }

    // input { focus-follows-mouse }: a global mouse-moved monitor (covered
    // by the Accessibility grant nigiri already holds - no Input Monitoring
    // involved; global monitors observe, they can't tap or modify). Focus
    // only changes when the cursor rests over a DIFFERENT managed window,
    // throttled, never mid-drag or mid-transition.
    // Which managed window is under a point. Was a local function inside
    // start(), so the focus-follows-mouse tick could not reach it and grew a
    // fourth copy of the walk - one that went tiled-first and therefore
    // answered a different window than every other caller.
    func managedWindowAt(_ point: CGPoint) -> (window: ManagedWindow, floating: Bool)? {
        // Floating first: they sit above the tiled layer.
        for w in workspace.floatingWindows {
            if let frame = WindowMover.currentFrame(w.axElement), frame.contains(point) { return (w, true) }
        }
        for w in workspace.tiledWindows {
            if let frame = WindowMover.currentFrame(w.axElement), frame.contains(point) { return (w, false) }
        }
        return nil
    }

    // Whether a pointer move should move focus at all. Pure so the rule can
    // be read (and tested) without a mouse: the overview guard is the one
    // that was missing - the panel owns the whole screen there and drives its
    // own selection, so this tick was overriding raiseOverviewSelection's
    // focus and flapping against the relayout every ~0.15s.
    // onAppActivated has the same guard; this one was forgotten.
    static func shouldFocusFollowMouse(
        overviewActive: Bool, transitioning: Bool,
        buttonsDown: Int, sinceLastTick: TimeInterval
    ) -> Bool {
        sinceLastTick > 0.15 && !overviewActive && !transitioning && buttonsDown == 0
    }

    func focusFollowMouseTick() {
        guard
            Self.shouldFocusFollowMouse(
                overviewActive: isOverviewActive,
                transitioning: isTransitioningWorkspace,
                buttonsDown: NSEvent.pressedMouseButtons,
                sinceLastTick: Date().timeIntervalSince(lastMouseFocusTick))
        else { return }
        lastMouseFocusTick = Date()
        guard let primary = NSScreen.screens.first else { return }
        // NSEvent.mouseLocation is AppKit bottom-left space - flip to AX.
        let location = NSEvent.mouseLocation
        let point = CGPoint(x: location.x, y: primary.frame.height - location.y)
        // managedWindowAt, not a fourth hand-rolled walk: this one went
        // TILED-FIRST and returned on the first hit, so pointing at a dialog
        // sitting over a tiled window focused the window UNDERNEATH and
        // raised it, sinking the dialog the user was aiming at.
        guard let (w, floating) = managedWindowAt(point), w !== focusedManagedWindow() else { return }
        WindowMover.focus(w.axElement, pid: w.pid)
        // Bring the whole floating layer up only when the pointer lands ON a
        // floating window - focusing a tiled window leaves the floating layer
        // where it is. Raising it here on every tiled focus was the same
        // "floating flashes forward as you move" bug as the keyboard path;
        // macOS cannot hold a background window above the active one anyway.
        if floating { raiseFloatingLayer(above: w) }
    }
    func applyInputConfig(_ config: NigiriConfig) {
        warpMouseEnabled = config.warpMouseToFocus
        if config.focusFollowsMouse, mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { _ in
                MainActor.assumeIsolated { self.focusFollowMouseTick() }
            }
        } else if !config.focusFollowsMouse, let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }
}

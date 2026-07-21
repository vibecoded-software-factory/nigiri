import AppKit
import ApplicationServices
import QuartzCore

setvbuf(stdout, nil, _IOLBF, 0)  // line-buffer even when stdout is redirected to a file/pipe

let cliArgs = Array(CommandLine.arguments.dropFirst())

// `nigiri msg <request>` - the IPC client (niri's `niri msg`). Talks to
// the RUNNING instance over its socket, so it needs no Accessibility
// grant of its own - which is why it runs before the trust guard below.
if cliArgs.first == "msg" {
    let request = cliArgs.dropFirst().joined(separator: " ")
    guard !request.isEmpty else {
        print("usage: nigiri msg <windows|workspaces|focused-window|action <name...>|event-stream>")
        exit(1)
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = MsgServer.makeAddress()
    let connected = withUnsafePointer(to: &address) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else {
        print("nigiri msg: no running nigiri at \(MsgServer.socketPath)")
        exit(1)
    }
    let line = request + "\n"
    _ = line.utf8CString.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count - 1) }
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &chunk, 4096)
        guard n > 0 else { break }
        FileHandle.standardOutput.write(Data(chunk[0..<n]))
    }
    exit(0)
}

// `nigiri selftest`: the pure-logic suite. Runs BEFORE the trust guard -
// none of it touches AX, so it needs no permission and no windows.
if cliArgs.first == "selftest" {
    SelfTest.run()
}

// `nigiri check-config [path]`: parses and counts what it understood, without
// touching windows or asking for permissions. A file the parser silently
// breaks on shows up here (the warnings go to stdout) instead of being
// discovered because the binds don't respond.
if cliArgs.first == "check-config" {
    let path = (cliArgs.count > 1 ? cliArgs[1] : "~/.config/nigiri/config.kdl")
        .replacingOccurrences(of: "~", with: NSHomeDirectory())
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("cannot read \(path)")
        exit(1)
    }
    var visited: Set<String> = []
    let expanded = NigiriConfig.expandIncludes(
        text, baseDir: (path as NSString).deletingLastPathComponent, visited: &visited)
    let parsed = NigiriConfig.parse(expanded)
    print("--- \(path)")
    print("mod-key: \(parsed.modKey)")
    print(
        "binds: \(parsed.binds.count) keyboard, \(parsed.mouseBindings.count) mouse, \(parsed.wheelBindings.count) wheel"
    )
    print("window-rules: \(parsed.rules.count) | animations: \(parsed.animations.count)")
    print(
        "gaps: \(parsed.gap) | default width: \(parsed.defaultColumnWidth) | focus-ring: \(parsed.ringWidth)"
    )
    print("spawn-at-startup: \(parsed.spawnAtStartup.count) | environment: \(parsed.environment.count)")
    exit(0)
}

guard Permissions.ensureAccessibilityTrusted(prompt: true) else {
    print("nigiri needs Accessibility access.")
    print("Grant it in System Settings -> Privacy & Security -> Accessibility, then run nigiri again.")
    exit(1)
}

func parseFlag(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

// Carbon's hotkey dispatch needs an actual running NSApplication event loop,
// not a bare CFRunLoopRun() - same as every real app that registers global
// hotkeys (Hammerspoon included, a full AppKit app, never a bare CLI loop).
// .accessory keeps this background-agent-like: no Dock icon, no menu bar,
// never steals focus.
func runResidentApp() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.run()
    exit(0)  // unreachable in practice; app.run() only returns on NSApp.terminate()
}

if cliArgs.first == "move" {
    let rest = Array(cliArgs.dropFirst())
    let app = parseFlag("--app", in: rest) ?? ""
    let title = parseFlag("--title", in: rest) ?? ""
    guard let xs = parseFlag("--x", in: rest), let x = Double(xs),
        let ys = parseFlag("--y", in: rest), let y = Double(ys),
        let ws = parseFlag("--w", in: rest), let w = Double(ws),
        let hs = parseFlag("--h", in: rest), let h = Double(hs),
        !app.isEmpty
    else {
        print("usage: nigiri move --app <name> [--title <substring>] --x <n> --y <n> --w <n> --h <n>")
        exit(1)
    }
    guard let window = WindowMover.findWindow(appContains: app, titleContains: title) else {
        print(
            "error: \(WindowMover.MoveError.notFound.description) (app contains \"\(app)\", title contains \"\(title)\")"
        )
        exit(1)
    }
    do {
        try WindowMover.setFrame(window, to: CGRect(x: x, y: y, width: w, height: h))
        print("moved \(app) window to (\(Int(x)), \(Int(y))) \(Int(w))x\(Int(h))")
    } catch let error as WindowMover.MoveError {
        print("error: \(error.description)")
        exit(1)
    }
    exit(0)
}

if cliArgs.first == "listen" {
    let listener = HotkeyListener()
    let keyNine: CGKeyCode = 0x19
    listener.register(keyNine, modifiers: [.command, .option]) {
        print("hello from nigiri (Cmd+Option+9 fired)")
    }
    guard listener.start() else {
        print("nigiri: failed to install the Carbon hotkey event handler.")
        exit(1)
    }
    print("listening: Cmd+Option+9. Ctrl+C to quit.")
    runResidentApp()
}

if cliArgs.first == "ring" {
    let rest = Array(cliArgs.dropFirst())
    let x = Double(parseFlag("--x", in: rest) ?? "100") ?? 100
    let y = Double(parseFlag("--y", in: rest) ?? "100") ?? 100
    let w = Double(parseFlag("--w", in: rest) ?? "600") ?? 600
    let h = Double(parseFlag("--h", in: rest) ?? "400") ?? 400

    let overlay = FocusRingOverlay()
    overlay.show(around: CGRect(x: x, y: y, width: w, height: h))
    print("ring shown at (\(Int(x)), \(Int(y))) \(Int(w))x\(Int(h)). Ctrl+C to quit.")
    runResidentApp()
}

// A MainActor-isolated box holding a callback. @Sendable system closures
// (notification observer blocks) can capture THIS - a global-actor-isolated
// class is Sendable - and hop back onto the main actor to run it, whereas
// capturing a main-actor local function directly in a @Sendable closure is
// (rightly) flagged by the compiler.
@MainActor final class MainActorCallback {
    // nonisolated(unsafe) is sound here: written exactly once in init,
    // only ever read via the MainActor-isolated run().
    private nonisolated(unsafe) let body: @MainActor () -> Void
    // nonisolated: creating the box just stores the closure - only run()
    // needs the main actor. Top-level script code is not itself
    // MainActor-isolated, so an isolated init couldn't be called there.
    nonisolated init(_ body: @escaping @MainActor () -> Void) { self.body = body }
    func run() { body() }
}

if cliArgs.first == "tile" {
    runTilingSession()
}

print("=== nigiri: windows via Accessibility API ===")
let windows = WindowEnumerator.listAllWindows()
if windows.isEmpty {
    print("(no windows found - is anything open?)")
} else {
    for w in windows {
        let f = w.frame
        print(
            "[\(w.appName) pid=\(w.pid)] \"\(w.title)\" @ (\(Int(f.origin.x)), \(Int(f.origin.y))) \(Int(f.width))x\(Int(f.height))"
        )
    }
}

print("")
print("=== [CGWindowList] cross-check (titles may be blank without Screen Recording permission) ===")
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
if let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: AnyObject]] {
    for entry in list {
        let owner = entry[kCGWindowOwnerName as String] as? String ?? "?"
        let name = entry[kCGWindowName as String] as? String ?? ""
        let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        let x = Int(boundsDict["X"] ?? 0)
        let y = Int(boundsDict["Y"] ?? 0)
        let w = Int(boundsDict["Width"] ?? 0)
        let h = Int(boundsDict["Height"] ?? 0)
        print("[\(owner)] \"\(name)\" @ (\(x), \(y)) \(w)x\(h)")
    }
} else {
    print("(CGWindowListCopyWindowInfo returned nothing)")
}

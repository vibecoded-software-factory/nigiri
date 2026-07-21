import AppKit
import Carbon

// nigiri's config file: ~/.config/nigiri/config.kdl, live-reloaded on save.
// The syntax MIRRORS niri's real config.kdl as closely as the feature set
// allows - same section names, same nesting, same bind shape - so moving
// between the two configs is copy-paste, not translation:
//
//   layout {
//       gaps 10
//       center-focused-column "never"
//       preset-column-widths {
//           proportion 0.33333
//           proportion 0.5
//       }
//       default-column-width { proportion 0.5; }
//       focus-ring {
//           width 4
//           active-gradient from="#7355a6" to="#cba6f7" angle=45
//       }
//   }
//   window-rule {
//       match title="Picture-in-Picture"
//       open-floating true
//   }
//   binds {
//       Mod+Left  { focus-column-left; }
//       Mod+Minus { set-column-width "-10%"; }
//   }
//
// Hand-parsed KDL subset, zero dependencies: a tokenizer that understands
// quotes, braces, semicolons and // comments, and a cursor parser over the
// stream. Actions are the same vocabulary the FIFO accepts (both dispatch
// through performAction), including niri's own aliases.
struct NigiriConfig {
    // One `match` / `exclude` line. niri's matchers are REGEXES, and any
    // field left out matches everything - a matcher with no field at all is
    // how niri writes "applies to every window".
    struct Matcher {
        var app: Regex?
        var title: Regex?
        // niri's state matchers.
        var isActive: Bool?
        var isFloating: Bool?
        var atStartup: Bool?

        func matches(
            app appName: String, bundleID: String?, title windowTitle: String,
            isActive active: Bool, isFloating floating: Bool, atStartup startup: Bool
        ) -> Bool {
            // app-id is reverse-DNS on Wayland, so the bundle identifier is
            // its macOS counterpart; the display name is accepted too, since
            // that is what a config written here would reach for first.
            if let app {
                let matchesApp = app.matches(appName) || (bundleID.map { app.matches($0) } ?? false)
                if !matchesApp { return false }
            }
            if let title, !title.matches(windowTitle) { return false }
            if let isActive, isActive != active { return false }
            if let isFloating, isFloating != floating { return false }
            if let atStartup, atStartup != startup { return false }
            return true
        }
    }

    struct Rule {
        // niri ORs multiple `match` lines within one window-rule, and a rule
        // with NO match applies to every window.
        var matchers: [Matcher] = []
        // niri's exclude: any hit vetoes the rule.
        var excludes: [Matcher] = []
        var openFloating: Bool?
        var defaultWidthProportion: CGFloat?
        // niri's open-on-workspace - by number, or by named workspace.
        var openOnWorkspace: Int?
        var openOnWorkspaceName: String?
        var openMaximized: Bool = false
        // niri's open-fullscreen (macOS native fullscreen on adoption).
        var openFullscreen: Bool = false
        // niri's default-floating-position "x y" (AX/CG top-left space),
        // applied when the window opens floating.
        var defaultFloatingPosition: CGPoint?
        // niri's min-width/max-width, as pixels: min-width seeds the
        // column's discovered minimum (skips the probe); max-width caps how
        // wide set/preset-column-width can grow it.
        var minWidthPx: CGFloat?
        var maxWidthPx: CGFloat?
    }
    struct Bind {
        var combo: String
        var keyCode: CGKeyCode
        var modifiers: HotkeyListener.Modifiers
        var action: String
        // niri's per-bind properties. cooldown-ms rate-limits repeat
        // firings; hotkey-overlay-title labels it in the overlay. repeat/
        // allow-when-locked/allow-inhibiting are parsed but inert on macOS
        // (Carbon hotkeys don't auto-repeat and there's no lock hook).
        var cooldownMs: Int?
        var title: String?
        // niri's hotkey-overlay-title=null: the bind works, but the
        // "Important Hotkeys" overlay does not list it.
        var hiddenFromOverlay: Bool = false
    }

    var gap: CGFloat = 10
    // niri keeps ONE ordered Vec<PresetSize> per list (niri-config
    // layout.rs), and the order is the whole point: it is the cycle
    // Mod+R walks. Splitting it into "the proportions" and "the pixels"
    // reordered a mixed list (0.25, 1920px, 0.75 cycled 25% -> 75% -> 1920)
    // and made a fixed-only list look empty, so the defaults were injected
    // on top of it - five presets where the user declared two.
    enum PresetSize: Equatable {
        case proportion(CGFloat)
        case fixed(CGFloat)
    }
    var presetColumnSizes: [PresetSize] = [.proportion(1.0 / 3.0), .proportion(0.5), .proportion(2.0 / 3.0)]
    var presetWindowHeightSizes: [PresetSize] = [
        .proportion(1.0 / 3.0), .proportion(0.5), .proportion(2.0 / 3.0),
    ]
    var presetColumnWidths: [CGFloat] = [1.0 / 3.0, 0.5, 2.0 / 3.0]
    // niri's `preset-column-widths { fixed 1200; }` - pixels, converted to
    // niri's preset-window-heights: its OWN list, not the widths reused.
    var defaultColumnWidth: CGFloat = 0.5
    var ringWidth: CGFloat = 4
    // See macOSWindowCornerRadius: the radius the ring/border round their
    // corners by, matching macOS's own window corner. Measured, not guessed.
    var cornerRadius: CGFloat = 19
    var ringFrom: NSColor = NSColor(
        calibratedRed: 0x73 / 255.0, green: 0x55 / 255.0, blue: 0xa6 / 255.0, alpha: 1)
    var ringTo: NSColor = NSColor(
        calibratedRed: 0xcb / 255.0, green: 0xa6 / 255.0, blue: 0xf7 / 255.0, alpha: 1)
    // niri draws the focus ring around EVERY window - active colour on the
    // focused one, inactive-color on the rest. nigiri used to have no
    // inactive ring at all, so with `border { off }` (niri's default, and
    // this user's config) non-focused windows wore no decoration whatsoever.
    var ringInactiveColor: NSColor = NSColor(
        calibratedRed: 0x2a / 255.0, green: 0x2a / 255.0, blue: 0x3a / 255.0, alpha: 1)
    var ringOff: Bool = false
    // layout { tab-indicator { active-gradient / active-color / inactive-color } }
    var tabActiveColor: NSColor = NSColor(
        calibratedRed: 0xcb / 255.0, green: 0xa6 / 255.0, blue: 0xf7 / 255.0, alpha: 1)
    var tabInactiveColor: NSColor = NSColor(
        calibratedRed: 0x2a / 255.0, green: 0x2a / 255.0, blue: 0x3a / 255.0, alpha: 1)
    var rules: [Rule] = []
    var binds: [Bind] = []
    // niri's layout.border: a plain stroke on NON-focused windows (the
    // focused one wears the focus ring). Width 0 = off, niri's default.
    var borderWidth: CGFloat = 0
    var borderInactiveColor: NSColor = NSColor(
        calibratedRed: 0x58 / 255.0, green: 0x5B / 255.0, blue: 0x70 / 255.0, alpha: 1)
    // niri's input section, the parts with an AX-world equivalent.
    var focusFollowsMouse: Bool = false
    var warpMouseToFocus: Bool = false
    // niri's spawn-at-startup - run once at launch, never on reload.
    var spawnAtStartup: [String] = []
    // niri's named workspaces, in declaration order: `workspace "chat"`.
    // Pre-created 1..N at those positions so focus/move/open-on-workspace
    // can target them by name.
    var namedWorkspaces: [String] = []
    // Three-finger trackpad swipe actions (MultitouchSupport). Each is an
    // action line run through performAction; empty disables that swipe.
    // Defaults: horizontal walks the column strip, vertical the workspaces.
    var gestureSwipeLeft = "focus-column-right"
    var gestureSwipeRight = "focus-column-left"
    var gestureSwipeUp = "focus-workspace-up"
    var gestureSwipeDown = "focus-workspace-down"
    // Four-finger swipes. Empty = that swipe does nothing (niri's overview
    // gesture is the obvious use, and it is what the default config shows).
    var gestureFourLeft = ""
    var gestureFourRight = ""
    var gestureFourUp = ""
    var gestureFourDown = ""
    // Magic Mouse (or any mouse with a touch surface). Empty by default: on
    // that surface a one-finger vertical drag is the scroll gesture, so
    // binding it blind would fire on every scroll.
    var gestureMouseOne: [SwipeDirection: String] = [:]
    var gestureMouseTwo: [SwipeDirection: String] = [:]
    // Mod+wheel bindings (niri's Mod+WheelScroll*, mouse wheel only). Keyed
    // by "<mods>-<dir>": mods is mod / mod-ctrl / mod-shift, dir is
    // up/down/left/right. Value is an action line.
    var wheelBindings: [String: String] = [:]
    // niri's MouseLeft/MouseRight/MouseMiddle/MouseBack/MouseForward binds,
    // keyed the same way as the wheel ones ("mod-middle", "ctrl-back", ...).
    var mouseBindings: [String: String] = [:]
    // input { keyboard { binds-layout "Workman" } } - pin bind resolution to
    // one layout, like niri resolving against its first xkb layout.
    var bindsLayout: String? = nil
    // input { mod-key "Ctrl" }: what `Mod+` means. niri's Mod is Super, which
    // macOS reserves, so the default stays Cmd+Opt.
    var modKey: HotkeyListener.Modifiers = [.command, .option]
    // niri's animations section. Keyed by niri's own animation names
    // (workspace-switch, window-movement, window-resize,
    // horizontal-view-movement, overview-open-close, window-open,
    // window-close). `animationsOff` is the section-level `off`, and
    // `animationSlowdown` multiplies every duration.
    var animations: [String: AnimationCurve] = [:]
    var animationsOff = false
    var animationSlowdown: Double = 1
    // niri's layout { struts }: insets carved out of the working area.
    var struts = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    // niri's layout { center-focused-column } and always-center-single-column.
    enum CenterFocusedColumn: String { case never, always, onOverflow }
    var centerFocusedColumn: CenterFocusedColumn = .never
    var alwaysCenterSingleColumn = false
    // niri's layout { empty-workspace-above-first }.
    var emptyWorkspaceAboveFirst = false
    // niri's layout { default-column-display "tabbed" }.
    var defaultColumnTabbed = false
    // niri's overview section. zoom is how much of the screen a workspace row
    // takes in the panel; the backdrop is what shows behind the cards.
    var overviewZoom: CGFloat = 0.5
    // niri's own default (niri-config: Overview { backdrop_color rgba(0.15,
    // 0.15, 0.15, 1.0) }), opaque - it is what surrounds each workspace.
    var overviewBackdrop = NSColor(calibratedWhite: 0.15, alpha: 1)
    // Set only when the config declares backdrop-color: unset means niri's
    // look, which is the desktop showing through behind the workspaces.
    var overviewBackdropSet = false
    // niri's shadow section. macOS draws its own window shadow, so this maps
    // onto the one shadow nigiri actually renders: the focus ring's glow.
    // niri's layout { insert-hint }: default on, rgba(127,200,255,128)
    // (niri-config/src/appearance.rs, InsertHint::default).
    var insertHintOff = false
    var insertHintColor = NSColor(
        calibratedRed: 127 / 255.0, green: 200 / 255.0, blue: 255 / 255.0, alpha: 128 / 255.0)
    var shadowOn = false
    var shadowSoftness: CGFloat = 30
    var shadowOffset = CGSize(width: 0, height: 5)
    var shadowColor = NSColor(calibratedWhite: 0, alpha: 0.45)
    // niri's environment: variables handed to everything nigiri spawns.
    var environment: [String: String] = [:]
    // niri's screenshot-path, with strftime placeholders.
    var screenshotPath = "~/Desktop/Screenshot %Y-%m-%d %H.%M.%S.png"

    static var path: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/nigiri/config.kdl")
    }

    // The character each physical key produces IN THE ACTIVE LAYOUT, built
    // by asking macOS itself (TIS + UCKeyTranslate) rather than assuming
    // US-QWERTY positions.
    //
    // This exists because RegisterEventHotKey takes a VIRTUAL KEYCODE, and a
    // virtual keycode is a physical POSITION - the one that types "F" on a
    // US keyboard. On Workman (or Dvorak, Colemak, AZERTY...) that position
    // types something else entirely, so every letter bind silently landed on
    // the wrong key: verified live on a Workman keyboard, where `Mod+Shift+F`
    // fired `Mod+U { focus-workspace-down }`, because Workman's F sits where
    // QWERTY has U. The config says what the user TYPES, so that is what has
    // to be resolved.
    static var layoutKeyCodes: [String: CGKeyCode] = [:]
    // The layout the last resolution actually used, for the startup log.
    static var layoutKeyCodesSource: String = "?"

    // Ask the current input source what each keycode types, unmodified.
    // Rebuilt on demand (and whenever the layout changes) - a laptop with
    // two layouts installed can switch under us.
    // `preferred` is the config's input { keyboard { binds-layout } }: the
    // macOS answer to niri resolving binds against the FIRST configured xkb
    // layout rather than the active one ("niri will search for the first
    // configured XKB layout that has the latin key"), so binds don't move
    // when you switch input sources. Unset = follow whatever is active,
    // which is right for the common single-layout setup.
    static func refreshLayoutKeyCodes(preferring preferred: String? = nil) {
        var chosen: TISInputSource? = nil
        if let preferred, !preferred.isEmpty,
            let all = TISCreateInputSourceList(
                [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource] as CFDictionary, true)?
                .takeRetainedValue() as? [TISInputSource]
        {
            chosen = all.first { source in
                guard let nameRaw = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else {
                    return false
                }
                let name = Unmanaged<CFString>.fromOpaque(nameRaw).takeUnretainedValue() as String
                return name.localizedCaseInsensitiveContains(preferred)
            }
            if chosen == nil {
                print("[config] binds-layout \"\(preferred)\" no esta instalado - uso el layout activo")
            }
        }
        let source = chosen ?? TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        guard let source, let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            layoutKeyCodes = [:]
            layoutKeyCodesSource = "?"
            return
        }
        if let nameRaw = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) {
            layoutKeyCodesSource = Unmanaged<CFString>.fromOpaque(nameRaw).takeUnretainedValue() as String
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var map: [String: CGKeyCode] = [:]
        data.withUnsafeBytes { buffer in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return
            }
            for code in CGKeyCode(0)...CGKeyCode(127) {
                var deadKeyState: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                    UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState, chars.count, &length, &chars)
                guard status == noErr, length > 0 else { continue }
                let text = String(utf16CodeUnits: chars, count: length).lowercased()
                // First keycode wins: the main row before the numeric keypad.
                if map[text] == nil { map[text] = code }
            }
        }
        layoutKeyCodes = map
    }

    // Symbol NAMES (niri writes "Slash", not "/") resolved to the character
    // they stand for, so they go through the layout map like letters do.
    static let keyNameCharacters: [String: String] = [
        "slash": "/", "backslash": "\\", "comma": ",", "period": ".",
        "semicolon": ";", "quote": "\'", "minus": "-", "equal": "=",
        "grave": "`", "bracketleft": "[", "bracketright": "]",
    ]

    // Key names accepted on the right side of a combo. Letters are listed
    // (the ban on letter HOTKEYS is a default-config decision, not a parser
    // one - whoever edits their config owns their menu collisions), and
    // F13-F20 exist for hyper-key setups (Caps Lock -> F19 via Karabiner).
    static let keyCodes: [String: CGKeyCode] = [
        "left": 0x7B, "right": 0x7C, "up": 0x7E, "down": 0x7D,
        "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
        "page_up": 0x74, "page_down": 0x79,
        "return": 0x24, "space": 0x31, "tab": 0x30, "escape": 0x35,
        "slash": 0x2C, "backslash": 0x2A, "comma": 0x2B, "period": 0x2F,
        "bracketleft": 0x21, "bracketright": 0x1E,
        "semicolon": 0x29, "quote": 0x27, "minus": 0x1B, "equal": 0x18, "grave": 0x32,
        "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15,
        "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19,
        "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E, "f": 0x03,
        "g": 0x05, "h": 0x04, "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25,
        "m": 0x2E, "n": 0x2D, "o": 0x1F, "p": 0x23, "q": 0x0C, "r": 0x0F,
        "s": 0x01, "t": 0x11, "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07,
        "y": 0x10, "z": 0x06,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60,
        "f6": 0x61, "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D,
        "f11": 0x67, "f12": 0x6F, "f13": 0x69, "f14": 0x6B, "f15": 0x71,
        "f16": 0x6A, "f17": 0x40, "f18": 0x4F, "f19": 0x50, "f20": 0x5A,
    ]

    // "Mod+Left" -> (keycode, modifiers). Mod is nigiri's primary modifier
    // (Cmd+Opt - macOS has no free Super key); Hyper = all four (the
    // classic Karabiner Caps Lock remap).
    // "Mod+WheelScrollDown", "Mod+Ctrl+WheelScrollLeft" -> the internal
    // wheel key ("mod-down", "mod-ctrl-left") the mouse tap looks up. nil
    // when the combo is not a wheel binding at all.
    static func wheelBindingKey(for combo: String) -> String? {
        let parts = combo.split(separator: "+").map { $0.lowercased() }
        guard let key = parts.last, key.hasPrefix("wheelscroll") else { return nil }
        let direction = String(key.dropFirst("wheelscroll".count))
        guard ["up", "down", "left", "right"].contains(direction) else { return nil }
        // The wheel tap only ever reports mod/ctrl/shift, so cmd and opt are
        // dropped here for the same reason - but NOT silently folded into
        // "mod": `Cmd+WheelScrollDown` used to be rewritten to "mod-down" and
        // overwrite a separately declared `Mod+WheelScrollDown`.
        var mods = Set(parts.dropLast().compactMap { canonicalModifier(String($0)) })
        let ignored = mods.intersection(["cmd", "opt"])
        if !ignored.isEmpty {
            print(
                "[config] \(combo): la rueda no distingue \(ignored.sorted().joined(separator: "/")) - se ignora(n)"
            )
            mods.subtract(ignored)
        }
        // niri has no unmodified wheel binds (a bare wheel is scrolling), so a
        // combo without Mod is read as meaning it.
        mods.insert("mod")
        return bindingKey(mods: mods, suffix: direction)
    }

    static func parseCombo(_ combo: String) -> (CGKeyCode, HotkeyListener.Modifiers)? {
        let parts = combo.split(separator: "+").map { $0.lowercased() }
        // A bare key (no modifier) is a legal niri bind. It grabs that key
        // system-wide, so it is only ever what the config literally asked
        // for - never a fallback for a combo that failed to parse.
        guard let keyName = parts.last, !keyName.isEmpty else { return nil }
        // The ACTIVE layout first (what the user actually types), the
        // US-QWERTY table second (arrows, F-keys, Tab/Escape/... have no
        // character to look up, and a layout that lacks a key falls back
        // rather than losing the bind).
        let character = keyNameCharacters[keyName] ?? keyName
        guard let keyCode = (character.count == 1 ? layoutKeyCodes[character] : nil) ?? keyCodes[keyName]
        else { return nil }
        var mods: HotkeyListener.Modifiers = []
        for part in parts.dropLast() {
            switch part {
            case "mod": mods.formUnion(modKey)
            case "cmd", "command", "super": mods.insert(.command)
            case "opt", "option", "alt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            case "shift": mods.insert(.shift)
            case "hyper": mods.formUnion([.command, .option, .control, .shift])
            default: return nil
            }
        }
        return (keyCode, mods)
    }

    // input { mod-key }: read before any bind is parsed, since parseCombo
    // resolves Mod at parse time.
    nonisolated(unsafe) static var modKey: HotkeyListener.Modifiers = [.command, .option]

    static func parseModifiers(_ names: [String]) -> HotkeyListener.Modifiers? {
        var mods: HotkeyListener.Modifiers = []
        for part in names {
            switch part {
            case "mod": mods.formUnion(modKey)
            case "cmd", "command", "super", "win": mods.insert(.command)
            case "opt", "option", "alt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            case "shift": mods.insert(.shift)
            case "hyper": mods.formUnion([.command, .option, .control, .shift])
            default: return nil
            }
        }
        return mods
    }

    // The ONE spelling of a mouse/wheel table key. Both sides of the lookup
    // build this string - the parser from the config text, the event tap from
    // live modifier flags - and they used to build it differently: the parser
    // kept whatever order the user wrote, the tap always emitted its own. So
    // `Mod+Shift+Ctrl+…`, which is the order niri's own configs use, was
    // stored as "mod-shift-ctrl-…" and looked up as "mod-ctrl-shift-…". A
    // dead bind, with nothing logged. Fixed order, canonical names.
    static func bindingKey(mods: Set<String>, suffix: String) -> String {
        let order = ["mod", "cmd", "opt", "ctrl", "shift"]
        return (order.filter { mods.contains($0) } + [suffix]).joined(separator: "-")
    }

    // A config modifier word -> its canonical name. nil for anything else,
    // including the key itself.
    static func canonicalModifier(_ word: String) -> String? {
        switch word {
        case "mod": return "mod"
        case "ctrl", "control": return "ctrl"
        case "shift": return "shift"
        case "cmd", "command", "super": return "cmd"
        case "opt", "option", "alt": return "opt"
        default: return nil
        }
    }

    // niri writes mouse-button binds like any other: `Mod+MouseMiddle { ... }`.
    // Returns the table key ("mod-middle"), or nil if this is not one.
    static func mouseBindingKey(for combo: String) -> String? {
        let parts = combo.split(separator: "+").map { $0.lowercased() }
        guard let key = parts.last, key.hasPrefix("mouse") else { return nil }
        let button = String(key.dropFirst("mouse".count))
        guard ["left", "right", "middle", "back", "forward"].contains(button) else { return nil }
        let mods = Set(parts.dropLast().compactMap { canonicalModifier(String($0)) })
        return bindingKey(mods: mods, suffix: button)
    }

    // niri takes CSS-shaped hex: #rgb, #rgba, #rrggbb, #rrggbbaa. Only the
    // 6-digit form parsed here, and a wrong length returned nil in SILENCE -
    // so every colour with alpha (which is most of niri's own defaults, and
    // the only way to write a shadow or an insert hint) was dropped without
    // a word.
    static func parseColor(_ raw: String) -> NSColor? {
        var hex = raw.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        // Shorthand doubles each digit: #f0a -> #ff00aa.
        if hex.count == 3 || hex.count == 4 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6 || hex.count == 8, let value = UInt32(hex, radix: 16) else {
            print("[config] color invalido, se ignora: \(raw)")
            return nil
        }
        let hasAlpha = hex.count == 8
        let shift: UInt32 = hasAlpha ? 8 : 0
        return NSColor(
            calibratedRed: CGFloat((value >> (16 + shift)) & 0xFF) / 255.0,
            green: CGFloat((value >> (8 + shift)) & 0xFF) / 255.0,
            blue: CGFloat((value >> shift) & 0xFF) / 255.0,
            alpha: hasAlpha ? CGFloat(value & 0xFF) / 255.0 : 1)
    }

    // The whole file as one token stream: words (quotes stripped, spaces
    // preserved inside them), the structural characters { } ; as their own
    // tokens, newlines as statement terminators, // comments dropped.
}

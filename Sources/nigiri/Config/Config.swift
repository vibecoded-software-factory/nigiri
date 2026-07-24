import AppKit
import Carbon

// nigiri's config: niri's own ~/.config/niri/config.kdl when present
// (~/.config/nigiri/config.kdl only as fallback - see `path`), live-reloaded.
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
        // niri keeps is-active (pending Activated state) and is-focused
        // (keyboard focus) as DISTINCT matchers (window_rule.rs); both
        // answer false at open time, like niri's unmapped windows.
        var isFocused: Bool?
        var isActiveInColumn: Bool?
        var isUrgent: Bool?
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
            // Rules are resolved at adoption (open time), where niri also
            // answers false for focus/urgency/column state - a matcher
            // requiring true simply never fires at open, same as upstream.
            if let isFocused, isFocused != false { return false }
            if let isActiveInColumn, isActiveInColumn != false { return false }
            if let isUrgent, isUrgent != false { return false }
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
        // niri's default-floating-position relative-to anchor
        // (window_rule.rs, RelativeTo); nil = top-left.
        var defaultFloatingPositionRelativeTo: String? = nil
        var defaultWidth: DefaultWidth?
        // niri's open-on-workspace: a workspace NAME only
        // (window_rule.rs:25-26, Option<String>). The old integer form was
        // invented syntax - upstream rejects a bare number as a type error.
        var openOnWorkspaceName: String?
        var openMaximized: Bool? = nil
        // niri's open-fullscreen (macOS native fullscreen on adoption).
        var openFullscreen: Bool? = nil
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
        // firings; hotkey-overlay-title labels it in the overlay; repeat
        // defaults to true like niri's (binds.rs) - Carbon hotkeys don't
        // auto-repeat, so the listener re-fires held keys itself using the
        // system's key-repeat delay and rate. allow-when-locked/
        // allow-inhibiting stay inert (no lock hook on macOS).
        var cooldownMs: Int?
        var repeats: Bool = true
        var title: String?
        // niri's hotkey-overlay-title=null: the bind works, but the
        // "Important Hotkeys" overlay does not list it.
        var hiddenFromOverlay: Bool = false
    }

    // niri's default (layout.rs): gaps 16. The old 10 was the user's own
    // config baked in as the built-in default.
    var gap: CGFloat = 16
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
    // niri's default-column-width in its three shapes (layout.rs:146-147,
    // default-config.kdl:142-143): a proportion, fixed pixels, or the EMPTY
    // block - "the window gets to decide its initial width". The fixed and
    // empty forms used to be silently swallowed as 0.5.
    enum DefaultWidth: Equatable {
        case proportion(CGFloat)
        case fixed(CGFloat)
        case natural
    }
    var defaultColumnWidth: DefaultWidth = .proportion(0.5)
    var ringWidth: CGFloat = 4
    // See macOSWindowCornerRadius: the radius the ring/border round their
    // corners by, matching macOS's own window corner. Measured, not guessed.
    var cornerRadius: CGFloat = 19
    // niri's default focus-ring is SOLID rgb(127,200,255) (appearance.rs);
    // both stops equal renders the gradient machinery as a solid. The
    // purple gradient was the user's personal config baked in as default.
    var ringFrom: NSColor = NSColor(
        calibratedRed: 127 / 255.0, green: 200 / 255.0, blue: 255 / 255.0, alpha: 1)
    var ringTo: NSColor = NSColor(
        calibratedRed: 127 / 255.0, green: 200 / 255.0, blue: 255 / 255.0, alpha: 1)
    // niri draws the focus ring around EVERY window - active colour on the
    // focused one, inactive-color on the rest. nigiri used to have no
    // inactive ring at all, so with `border { off }` (niri's default, and
    // this user's config) non-focused windows wore no decoration whatsoever.
    // niri: rgb(80,80,80) (appearance.rs).
    var ringInactiveColor: NSColor = NSColor(
        calibratedRed: 80 / 255.0, green: 80 / 255.0, blue: 80 / 255.0, alpha: 1)
    // niri's urgent-color: rgb(155,0,0) (appearance.rs:250). Parsed and
    // stored; dormant until urgency machinery exists.
    var ringUrgentColor: NSColor = NSColor(
        calibratedRed: 155 / 255.0, green: 0, blue: 0, alpha: 1)
    // The gradient's CSS angle in degrees; niri's default is 180 ("to
    // bottom", appearance.rs:92) - only 45 used to be accepted.
    var ringAngle: CGFloat = 180
    var ringOff: Bool = false
    // layout { tab-indicator { ... } } - niri's full TabIndicator
    // (appearance.rs:459-499). Colors are OPTIONAL like upstream: unset,
    // they derive from the focus-ring/border at apply time
    // (tab_indicator.rs:363-406). The geometry knobs used to be hardcoded
    // constants and every real key was rejected as unknown.
    enum TabPosition: String { case left, right, top, bottom }
    var tabIndicatorOff = false
    var tabHideWhenSingleTab = false
    var tabPlaceWithinColumn = false
    var tabGap: CGFloat = 5
    var tabWidth: CGFloat = 4
    var tabLengthProportion: CGFloat = 0.5
    var tabPosition: TabPosition = .left
    var tabGapsBetweenTabs: CGFloat = 0
    var tabCornerRadius: CGFloat = 0
    var tabActiveColor: NSColor? = nil
    var tabInactiveColor: NSColor? = nil
    // Parsed and stored; dormant until urgency machinery exists.
    var tabUrgentColor: NSColor? = nil
    var rules: [Rule] = []
    var binds: [Bind] = []
    // niri's layout.border: a decoration in its own right, off by default,
    // with its own on/off flag - NOT "width 0 = off". Defaults are
    // Border::default() (appearance.rs:270-283): width 4, active
    // rgb(255,200,127), inactive rgb(80,80,80). The old inactive default
    // #585B70 was Catppuccin surface2 - a personal config baked in as a
    // default, exactly the kind of invention the fidelity audit hunts.
    var borderOn: Bool = false
    var borderWidth: CGFloat = 4
    var borderActiveColor: NSColor = NSColor(
        calibratedRed: 255 / 255.0, green: 200 / 255.0, blue: 127 / 255.0, alpha: 1)
    var borderInactiveColor: NSColor = NSColor(
        calibratedRed: 80 / 255.0, green: 80 / 255.0, blue: 80 / 255.0, alpha: 1)
    // niri's input section, the parts with an AX-world equivalent.
    // niri's input { workspace-auto-back-and-forth } (input.rs:23,51):
    // focusing the already-active workspace goes back to the previous one.
    var workspaceAutoBackAndForth: Bool = false
    var focusFollowsMouse: Bool = false
    var warpMouseToFocus: Bool = false
    // niri's spawn-at-startup - argv, no shell (misc.rs). Run once at
    // launch, never on reload.
    var spawnAtStartup: [[String]] = []
    // niri's spawn-sh-at-startup - the whole line through a shell.
    var spawnShAtStartup: [String] = []
    // niri's gestures { hot-corners {} }: 1x1 screen corners that toggle
    // the overview. Explicit corners win; top-left is the default when
    // none is set; `off` disables them all (niri.rs, is_inside_hot_corner).
    var hotCornersOff = false
    var hotCornerTopLeft = false
    var hotCornerTopRight = false
    var hotCornerBottomLeft = false
    var hotCornerBottomRight = false
    // niri's named workspaces, in declaration order: `workspace "chat"`.
    // Pre-created 1..N at those positions so focus/move/open-on-workspace
    // can target them by name.
    var namedWorkspaces: [String] = []
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
    // niri: rgba(0,0,0,0x77) (appearance.rs:363, #0007 in the default
    // config) - 0.45 was an invented rounding. spread defaults to 5.
    var shadowColor = NSColor(calibratedWhite: 0, alpha: 0x77 / 255.0)
    var shadowSpread: CGFloat = 5
    // niri's environment: variables handed to everything nigiri spawns.
    // nil = `K null` in the config, which UNSETS the variable
    // (misc.rs:158-164, value: Option<String>); an empty string SETS it
    // empty - "empty value = unset" was an invented rule.
    var environment: [String: String?] = [:]
    // niri's screenshot-path, with strftime placeholders.
    // niri's default (misc.rs:60-64); ~/Desktop with dots was invented.
    var screenshotPath = "~/Pictures/Screenshots/Screenshot from %Y-%m-%d %H-%M-%S.png"
    // niri's hotkey-overlay {} (misc.rs:67-85): skip-at-startup keeps the
    // "Important Hotkeys" panel from showing on launch (niri shows it every
    // startup by default); hide-not-bound drops unbound entries. The whole
    // section used to fall to "unknown top-level section".
    var hotkeyOverlaySkipAtStartup = false
    var hotkeyOverlayHideNotBound = false
    // Whether any layer-rule declares place-within-backdrop true - niri's
    // ONLY route for the wallpaper to appear behind the overview
    // (layer-rule, wiki + appearance.rs:12: the default backdrop is plain
    // gray 0.15). Defaulting to a captured desktop was invented.
    var backdropShowsWallpaper = false
    // niri's config-notification { disable-failed } (misc.rs:87-102).
    var configNotificationDisableFailed = false

    // nigiri reads niri's OWN config.kdl when it's present, so one dotfile
    // drives niri on Linux and nigiri on macOS - the Wayland-only sections it
    // can't honour are simply skipped. Its own `.config/nigiri/config.kdl` is
    // the fallback and the target for the first-run default (we never author a
    // niri config on the user's behalf). writeDefaultIfMissing() keys off this
    // same resolution: when niri's config exists, `path` points at it, it's
    // found, and no default gets written.
    static var path: String {
        let home = NSHomeDirectory() as NSString
        let niri = home.appendingPathComponent(".config/niri/config.kdl")
        if FileManager.default.fileExists(atPath: niri) { return niri }
        return home.appendingPathComponent(".config/nigiri/config.kdl")
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
                print("[config] binds-layout \"\(preferred)\" is not installed - using the active layout")
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
                "[config] \(combo): the wheel can't tell \(ignored.sorted().joined(separator: "/")) apart - ignored"
            )
            mods.subtract(ignored)
        }
        // niri allows genuinely unmodified wheel binds (binds.rs: any
        // modifier set, including none) - a bare WheelScrollDown eats
        // scrolling everywhere, which is the user's own call, exactly as
        // upstream. The silent promotion to Mod rewrote that intent.
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
            guard let mapped = modifierMask(part) else { return nil }
            mods.formUnion(mapped)
        }
        return (keyCode, mods)
    }

    // niri's modifier words, spelling for spelling (ModKey's FromStr,
    // input.rs:439-453) - cmd/command/opt/option/hyper were invented
    // vocabulary and are gone. The macOS mapping: Super/Win is Command,
    // Alt is Option; ISO_Level3_Shift (AltGr) is Option too, the closest
    // macOS has; ISO_Level5_Shift has no analog and maps to Option with a
    // note.
    nonisolated static func modifierMask(_ word: String) -> HotkeyListener.Modifiers? {
        switch word.lowercased() {
        case "mod": return modKey
        case "ctrl", "control": return .control
        case "shift": return .shift
        case "alt": return .option
        case "super", "win": return .command
        case "iso_level3_shift", "mod5": return .option
        case "iso_level5_shift", "mod3":
            print("[config] ISO_Level5_Shift has no macOS analog - using Option")
            return .option
        default: return nil
        }
    }

    // input { mod-key }: read before any bind is parsed, since parseCombo
    // resolves Mod at parse time.
    nonisolated(unsafe) static var modKey: HotkeyListener.Modifiers = [.command, .option]

    static func parseModifiers(_ names: [String]) -> HotkeyListener.Modifiers? {
        var mods: HotkeyListener.Modifiers = []
        for part in names {
            guard let mapped = modifierMask(part) else { return nil }
            mods.formUnion(mapped)
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
        // niri's spellings only (input.rs:439-453); the canonical names
        // stay the internal short forms the binding tables use.
        case "super", "win": return "cmd"
        case "alt", "iso_level3_shift", "mod5": return "opt"
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
    // niri parses colors with csscolorparser (appearance.rs:786-796): hex,
    // the CSS named colors, and the rgb()/rgba()/hsl()/hsla() functions.
    // Only hex used to be accepted, so valid niri configs lost colors with
    // nothing but a log line.
    static func parseColor(_ raw: String) -> NSColor? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let compact = trimmed.lowercased().replacingOccurrences(of: " ", with: "")
        if compact.hasPrefix("rgb") || compact.hasPrefix("hsl") {
            if let c = functionColor(compact) { return c }
            print("[config] invalid color, ignored: \(raw)")
            return nil
        }
        if let namedHex = cssNamedColors[compact] { return hexColor(namedHex) }
        if let c = hexColor(trimmed) { return c }
        print("[config] invalid color, ignored: \(raw)")
        return nil
    }

    private static func hexColor(_ raw: String) -> NSColor? {
        var hex = raw
        if hex.hasPrefix("#") { hex.removeFirst() }
        // Shorthand doubles each digit: #f0a -> #ff00aa.
        if hex.count == 3 || hex.count == 4 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6 || hex.count == 8, let value = UInt32(hex, radix: 16) else {
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

    // rgb(a)/hsl(a) in their CSS forms, whitespace already stripped;
    // channels take 0-255 or %, alpha 0-1 or %, "," or "/" separators.
    private static func functionColor(_ s: String) -> NSColor? {
        guard let open = s.firstIndex(of: "("), s.hasSuffix(")") else { return nil }
        let name = String(s[..<open])
        let inner = s[s.index(after: open)..<s.index(before: s.endIndex)]
        let comps = inner.split(whereSeparator: { $0 == "," || $0 == "/" }).map(String.init)
        func channel(_ c: String) -> CGFloat? {
            if c.hasSuffix("%") { return Double(c.dropLast()).map { CGFloat($0) / 100 * 255 } }
            return Double(c).map { CGFloat($0) }
        }
        func unit(_ c: String) -> CGFloat? {
            if c.hasSuffix("%") { return Double(c.dropLast()).map { CGFloat($0) / 100 } }
            return Double(c).map { CGFloat($0) }
        }
        switch name {
        case "rgb", "rgba":
            guard comps.count >= 3, let r = channel(comps[0]), let g = channel(comps[1]),
                let b = channel(comps[2])
            else { return nil }
            let a = comps.count >= 4 ? (unit(comps[3]) ?? 1) : 1
            return NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
        case "hsl", "hsla":
            guard comps.count >= 3,
                let h = Double(comps[0].replacingOccurrences(of: "deg", with: "")),
                let sat = unit(comps[1]), let light = unit(comps[2])
            else { return nil }
            let a = comps.count >= 4 ? (unit(comps[3]) ?? 1) : 1
            // The CSS HSL->RGB algorithm.
            let c = (1 - abs(2 * light - 1)) * sat
            let hp = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
            let x = c * (1 - abs(CGFloat(hp).truncatingRemainder(dividingBy: 2) - 1))
            let m = light - c / 2
            let rgb: (CGFloat, CGFloat, CGFloat)
            switch hp {
            case 0..<1: rgb = (c, x, 0)
            case 1..<2: rgb = (x, c, 0)
            case 2..<3: rgb = (0, c, x)
            case 3..<4: rgb = (0, x, c)
            case 4..<5: rgb = (x, 0, c)
            default: rgb = (c, 0, x)
            }
            return NSColor(calibratedRed: rgb.0 + m, green: rgb.1 + m, blue: rgb.2 + m, alpha: a)
        default: return nil
        }
    }

    // The CSS named colors (Level 4), the same set csscolorparser accepts.
    static let cssNamedColors: [String: String] = [
        "aliceblue": "#f0f8ff", "antiquewhite": "#faebd7", "aqua": "#00ffff",
        "aquamarine": "#7fffd4", "azure": "#f0ffff", "beige": "#f5f5dc", "bisque": "#ffe4c4",
        "black": "#000000", "blanchedalmond": "#ffebcd", "blue": "#0000ff",
        "blueviolet": "#8a2be2", "brown": "#a52a2a", "burlywood": "#deb887",
        "cadetblue": "#5f9ea0", "chartreuse": "#7fff00", "chocolate": "#d2691e",
        "coral": "#ff7f50", "cornflowerblue": "#6495ed", "cornsilk": "#fff8dc",
        "crimson": "#dc143c", "cyan": "#00ffff", "darkblue": "#00008b", "darkcyan": "#008b8b",
        "darkgoldenrod": "#b8860b", "darkgray": "#a9a9a9", "darkgreen": "#006400",
        "darkgrey": "#a9a9a9", "darkkhaki": "#bdb76b", "darkmagenta": "#8b008b",
        "darkolivegreen": "#556b2f", "darkorange": "#ff8c00", "darkorchid": "#9932cc",
        "darkred": "#8b0000", "darksalmon": "#e9967a", "darkseagreen": "#8fbc8f",
        "darkslateblue": "#483d8b", "darkslategray": "#2f4f4f", "darkslategrey": "#2f4f4f",
        "darkturquoise": "#00ced1", "darkviolet": "#9400d3", "deeppink": "#ff1493",
        "deepskyblue": "#00bfff", "dimgray": "#696969", "dimgrey": "#696969",
        "dodgerblue": "#1e90ff", "firebrick": "#b22222", "floralwhite": "#fffaf0",
        "forestgreen": "#228b22", "fuchsia": "#ff00ff", "gainsboro": "#dcdcdc",
        "ghostwhite": "#f8f8ff", "gold": "#ffd700", "goldenrod": "#daa520", "gray": "#808080",
        "green": "#008000", "greenyellow": "#adff2f", "grey": "#808080", "honeydew": "#f0fff0",
        "hotpink": "#ff69b4", "indianred": "#cd5c5c", "indigo": "#4b0082", "ivory": "#fffff0",
        "khaki": "#f0e68c", "lavender": "#e6e6fa", "lavenderblush": "#fff0f5",
        "lawngreen": "#7cfc00", "lemonchiffon": "#fffacd", "lightblue": "#add8e6",
        "lightcoral": "#f08080", "lightcyan": "#e0ffff", "lightgoldenrodyellow": "#fafad2",
        "lightgray": "#d3d3d3", "lightgreen": "#90ee90", "lightgrey": "#d3d3d3",
        "lightpink": "#ffb6c1", "lightsalmon": "#ffa07a", "lightseagreen": "#20b2aa",
        "lightskyblue": "#87cefa", "lightslategray": "#778899", "lightslategrey": "#778899",
        "lightsteelblue": "#b0c4de", "lightyellow": "#ffffe0", "lime": "#00ff00",
        "limegreen": "#32cd32", "linen": "#faf0e6", "magenta": "#ff00ff", "maroon": "#800000",
        "mediumaquamarine": "#66cdaa", "mediumblue": "#0000cd", "mediumorchid": "#ba55d3",
        "mediumpurple": "#9370db", "mediumseagreen": "#3cb371", "mediumslateblue": "#7b68ee",
        "mediumspringgreen": "#00fa9a", "mediumturquoise": "#48d1cc",
        "mediumvioletred": "#c71585", "midnightblue": "#191970", "mintcream": "#f5fffa",
        "mistyrose": "#ffe4e1", "moccasin": "#ffe4b5", "navajowhite": "#ffdead",
        "navy": "#000080", "oldlace": "#fdf5e6", "olive": "#808000", "olivedrab": "#6b8e23",
        "orange": "#ffa500", "orangered": "#ff4500", "orchid": "#da70d6",
        "palegoldenrod": "#eee8aa", "palegreen": "#98fb98", "paleturquoise": "#afeeee",
        "palevioletred": "#db7093", "papayawhip": "#ffefd5", "peachpuff": "#ffdab9",
        "peru": "#cd853f", "pink": "#ffc0cb", "plum": "#dda0dd", "powderblue": "#b0e0e6",
        "purple": "#800080", "rebeccapurple": "#663399", "red": "#ff0000",
        "rosybrown": "#bc8f8f", "royalblue": "#4169e1", "saddlebrown": "#8b4513",
        "salmon": "#fa8072", "sandybrown": "#f4a460", "seagreen": "#2e8b57",
        "seashell": "#fff5ee", "sienna": "#a0522d", "silver": "#c0c0c0", "skyblue": "#87ceeb",
        "slateblue": "#6a5acd", "slategray": "#708090", "slategrey": "#708090",
        "snow": "#fffafa", "springgreen": "#00ff7f", "steelblue": "#4682b4", "tan": "#d2b48c",
        "teal": "#008080", "thistle": "#d8bfd8", "tomato": "#ff6347", "transparent": "#00000000",
        "turquoise": "#40e0d0", "violet": "#ee82ee", "wheat": "#f5deb3", "white": "#ffffff",
        "whitesmoke": "#f5f5f5", "yellow": "#ffff00", "yellowgreen": "#9acd32",
    ]

    // The whole file as one token stream: words (quotes stripped, spaces
    // preserved inside them), the structural characters { } ; as their own
    // tokens, newlines as statement terminators, // comments dropped.
}

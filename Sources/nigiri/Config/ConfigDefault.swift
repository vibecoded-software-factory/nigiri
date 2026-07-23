import AppKit
import Carbon

// The commented default config written on first run - reproduces the
// previously hardcoded behavior exactly, and doubles as inline docs.
extension NigiriConfig {
    static func writeDefaultIfMissing() {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try? defaultConfigText.write(toFile: path, atomically: true, encoding: .utf8)
        print("config: wrote defaults to \(path)")
    }

    static let defaultConfigText = """
        // nigiri config - niri's config.kdl, translated to macOS. Live-reloads on save.
        // Mod = Cmd+Opt (macOS has no free Super). Also: Cmd/Opt/Ctrl/Shift, and
        // Hyper = all four (Karabiner Caps Lock remap). Keys: arrows, Home/End,
        // Page_Up/Page_Down, 0-9, a-z, F1-F20, Slash, Comma, Minus, ...

        layout {
            gaps 10

            center-focused-column "never"

            preset-column-widths {
                proportion 0.33333
                proportion 0.5
                proportion 0.66667
                // fixed 1200
            }

            // Marks where the window you're dragging with Mod+drag is going to
            // land (on by default, translucent blue like in niri):
            // insert-hint {
            //     // off
            //     color "#7fc8ff"
            // }

            // always-center-single-column
            // empty-workspace-above-first
            // default-column-display "tabbed"

            // Cut out of the usable area (a bar, for example):
            // struts {
            //     top 0
            //     bottom 0
            //     left 0
            //     right 0
            // }

            // Shadow: macOS draws every window's own and it can't be replaced,
            // so these values govern the ring's glow instead.
            // shadow {
            //     softness 30
            //     offset x=0 y=5
            //     color "#00000070"
            // }

            default-column-width { proportion 0.5; }

            focus-ring {
                width 4
                active-gradient from="#7355a6" to="#cba6f7" angle=45
            }

            // Border for the NON-focused windows (the focused one gets the ring):
            // border {
            //     width 2
            //     inactive-color "#585b70"
            // }
        }

        // overview {
        //     zoom 0.5
        //     backdrop-color "#0d0d0d"
        // }

        // Variables for everything nigiri spawns (empty value = unset it):
        // environment {
        //     TERM "xterm-256color"
        // }

        // screenshot-path "~/Desktop/Screenshot %Y-%m-%d %H.%M.%S.png"

        // input {
        //     // What Mod+ means (Cmd+Opt by default; niri uses Super, which
        //     // macOS reserves for itself):
        //     // mod-key "Ctrl"
        //     focus-follows-mouse
        //     warp-mouse-to-focus
        // }

        // Three-finger trackpad swipes (needs macOS's 3-finger gestures OFF in
        // System Settings > Trackpad, so they're free for us). Defaults below;
        // any action from the binds vocabulary works, empty string disables.
        // gestures {
        //     three-finger-left focus-column-right
        //     three-finger-right focus-column-left
        //     three-finger-up focus-workspace-up
        //     three-finger-down focus-workspace-down
        //     four-finger-up open-overview
        //     four-finger-down close-overview
        //     // Magic Mouse (the mouse's touch surface). Empty by default:
        //     // with ONE finger a vertical drag IS the scroll, so binding it
        //     // would fire on every scroll. With two fingers it's free.
        //     mouse-two-finger-left focus-column-right
        //     mouse-two-finger-right focus-column-left
        // }

        // Mod+wheel (MOUSE wheel only - trackpad scroll is consumed by macOS).
        // Hold Cmd+Opt and scroll; keys are mod[-ctrl][-shift]-<up|down|left|right>.
        // wheel {
        //     mod-down focus-workspace-down
        //     mod-up focus-workspace-up
        //     mod-ctrl-down move-column-to-workspace-down
        //     mod-ctrl-up move-column-to-workspace-up
        // }

        // Mouse buttons: written like any other bind, inside binds{}.
        //     Mod+MouseMiddle { close-window; }
        //     MouseBack       { focus-column-left; }
        //     MouseForward    { focus-column-right; }
        // Careful: a bind wins over the drag, not the other way around. The tap
        // checks the bind BEFORE claiming the drag, so declaring Mod+MouseLeft
        // here leaves you without Mod+drag-to-move.

        // spawn-at-startup "open" "-a" "Discord"

        // Window rules match by app-id (bundle id or app name) and/or title.
        // App-specific rules belong in YOUR config, not here - when DMS is in
        // use it manages its own via `include "dms/windowrules.kdl"`. Example:
        //
        // window-rule {
        //     match app-id="com.example.app"
        //     open-floating true
        //     // open-on-workspace 2
        //     // open-maximized true
        // }

        binds {
            Mod+Left  { focus-column-left; }
            Mod+Right { focus-column-right; }
            Mod+Up    { focus-window-up; }
            Mod+Down  { focus-window-down; }
            Mod+Home  { focus-column-first; }
            Mod+End   { focus-column-last; }

            Mod+Ctrl+Left        { focus-monitor-left; }
            Mod+Ctrl+Right       { focus-monitor-right; }
            Mod+Shift+Ctrl+Left  { move-column-to-monitor-left; }
            Mod+Shift+Ctrl+Right { move-column-to-monitor-right; }

            Mod+1 { focus-workspace 1; }
            Mod+2 { focus-workspace 2; }
            Mod+3 { focus-workspace 3; }
            Mod+4 { focus-workspace 4; }
            Mod+5 { focus-workspace 5; }
            Mod+6 { focus-workspace 6; }
            Mod+7 { focus-workspace 7; }
            Mod+8 { focus-workspace 8; }
            Mod+9 { focus-workspace 9; }
            Mod+0 { focus-workspace-previous; }
            Mod+Page_Up   { focus-workspace-up; }
            Mod+Page_Down { focus-workspace-down; }
            Mod+Slash { show-hotkey-overlay; }
            Mod+Tab { toggle-overview; }

            Cmd+Ctrl+Shift+Left  { move-column-left; }
            Cmd+Ctrl+Shift+Right { move-column-right; }
            Cmd+Ctrl+Shift+Up    { move-window-up; }
            Cmd+Ctrl+Shift+Down  { move-window-down; }
            Cmd+Ctrl+Shift+Home  { move-column-to-first; }
            Cmd+Ctrl+Shift+End   { move-column-to-last; }
            Cmd+Ctrl+Shift+1 { move-column-to-workspace 1; }
            Cmd+Ctrl+Shift+2 { move-column-to-workspace 2; }
            Cmd+Ctrl+Shift+3 { move-column-to-workspace 3; }
            Cmd+Ctrl+Shift+4 { move-column-to-workspace 4; }
            Cmd+Ctrl+Shift+5 { move-column-to-workspace 5; }
            Cmd+Ctrl+Shift+6 { move-column-to-workspace 6; }
            Cmd+Ctrl+Shift+7 { move-column-to-workspace 7; }
            Cmd+Ctrl+Shift+8 { move-column-to-workspace 8; }
            Cmd+Ctrl+Shift+9 { move-column-to-workspace 9; }

            Cmd+Opt+Ctrl+Left  { consume-or-expel-window-left; }
            Cmd+Opt+Ctrl+Right { consume-or-expel-window-right; }
            Cmd+Opt+Ctrl+Up    { expel-window-from-column; }
            Cmd+Opt+Ctrl+Down  { maximize-column; }
            Cmd+Opt+Ctrl+Home  { switch-preset-column-width; }
            Cmd+Opt+Ctrl+End   { switch-preset-window-height; }
            Cmd+Opt+Ctrl+Page_Up   { move-column-to-workspace-up; }
            Cmd+Opt+Ctrl+Page_Down { move-column-to-workspace-down; }

            Cmd+Ctrl+Left  { set-column-width "-10%"; }
            Cmd+Ctrl+Right { set-column-width "+10%"; }
            Cmd+Ctrl+Up    { set-window-height "+10%"; }
            Cmd+Ctrl+Down  { set-window-height "-10%"; }
            Cmd+Ctrl+Home  { reset-window-height; }
            Cmd+Ctrl+End   { expand-column-to-available-width; }

            Cmd+Opt+Shift+Left  { resize-edge left "-10%"; }
            Cmd+Opt+Shift+Right { resize-edge right "-10%"; }
            Cmd+Opt+Shift+Up    { resize-edge top "-10%"; }
            Cmd+Opt+Shift+Down  { resize-edge bottom "-10%"; }
            Cmd+Opt+Shift+Home      { resize-edge left "+10%"; }
            Cmd+Opt+Shift+End       { resize-edge right "+10%"; }
            Cmd+Opt+Shift+Page_Up   { resize-edge top "+10%"; }
            Cmd+Opt+Shift+Page_Down { resize-edge bottom "+10%"; }

            Cmd+Shift+Home { center-column; }
            Cmd+Shift+End  { center-visible-columns; }
            Cmd+Shift+Up   { toggle-window-floating; }
            Cmd+Shift+Down { switch-focus-between-floating-and-tiling; }
            Cmd+Shift+Page_Up   { maximize-window-to-edges; }
            Cmd+Shift+Page_Down { fullscreen-window; }

            Mod+Comma { consume-window-into-column; }
            Mod+Period { toggle-column-tabbed-display; }
            Mod+Backslash { close-window; }
            Mod+Grave { switch-preset-column-width-back; }
            Cmd+Ctrl+Shift+Page_Up   { move-workspace-up; }
            Cmd+Ctrl+Shift+Page_Down { move-workspace-down; }
            // Hyper = Cmd+Opt+Ctrl+Shift (doesn't clash with Force Quit's Cmd+Opt+Esc)
            Hyper+Escape { quit; }
        }

        """
}

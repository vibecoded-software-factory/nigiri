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
        // Mod = Cmd+Opt (macOS has no free Super). Modifier words are niri's:
        // Ctrl, Shift, Alt (Option), Super/Win (Command), Mod. Keys: arrows,
        // Home/End, Page_Up/Page_Down, 0-9, a-z, F1-F20, Slash, Comma, Minus, ...

        layout {
            gaps 16

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
            // so these values govern the ring's glow instead. Off unless you
            // add `on` - like niri, a bare shadow {} changes nothing.
            // shadow {
            //     on
            //     softness 30
            //     offset x=0 y=5
            //     color "#00000070"
            // }

            default-column-width { proportion 0.5; }

            focus-ring {
                width 4
                active-color "#7fc8ff"
            }

            // Border: a separate decoration from the focus ring, off by
            // default. Uncommenting the block ENABLES it (niri's documented
            // special case); add `off` inside to disable again.
            // border {
            //     width 4
            //     active-color "#ffc87f"
            //     inactive-color "#505050"
            // }
        }

        // overview {
        //     zoom 0.5
        //     backdrop-color "#0d0d0d"
        // }

        // Variables for everything nigiri spawns (`VAR null` unsets it):
        // environment {
        //     TERM "xterm-256color"
        // }

        // screenshot-path "~/Pictures/Screenshots/Screenshot from %Y-%m-%d %H-%M-%S.png"
        // screenshot-path null   // clipboard only, never saved

        // input {
        //     // What Mod+ means (Cmd+Opt by default; niri uses Super, which
        //     // macOS reserves for itself):
        //     // mod-key "Ctrl"
        //     focus-follows-mouse
        //     warp-mouse-to-focus
        // }

        // Touchpad gestures are niri's, hardcoded and continuous (needs
        // macOS's 3-finger gestures OFF in System Settings > Trackpad, so
        // they're free for us): 3-finger horizontal scrolls the column
        // strip, 3-finger vertical switches workspaces, 4-finger vertical
        // opens/closes the overview. The gestures {} section configures
        // only what niri's does (hot-corners; dnd-edge-* has no macOS
        // counterpart yet):
        // gestures {
        //     hot-corners { off }
        // }

        // Wheel binds are ordinary binds, exactly like in niri:
        // Mod+WheelScrollDown, Mod+Ctrl+WheelScrollUp, ... (see binds below).

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

        // niri's own default keymap (resources/default-config.kdl:349-633),
        // key for key, with Mod = Cmd+Opt. Omissions are macOS-forced and
        // say so; the previous keymap here was reinvented from scratch.
        binds {
            Mod+Shift+Slash { show-hotkey-overlay; }

            // Suggested binds for running programs (niri suggests alacritty/
            // fuzzel/swaylock; these are their macOS counterparts).
            Mod+T hotkey-overlay-title="Open a Terminal" { spawn "open" "-a" "Terminal"; }
            // Mod+D hotkey-overlay-title="Run an Application" { spawn-sh "open -a 'Launchpad'"; }
            // XF86Audio*/XF86MonBrightness* volume and brightness keys do
            // not exist on macOS keyboards; the system owns those keys.

            Mod+O repeat=false { toggle-overview; }

            Mod+Q repeat=false { close-window; }

            Mod+Left  { focus-column-left; }
            Mod+Down  { focus-window-down; }
            Mod+Up    { focus-window-up; }
            Mod+Right { focus-column-right; }
            Mod+H     { focus-column-left; }
            Mod+J     { focus-window-down; }
            Mod+K     { focus-window-up; }
            Mod+L     { focus-column-right; }

            Mod+Ctrl+Left  { move-column-left; }
            Mod+Ctrl+Down  { move-window-down; }
            Mod+Ctrl+Up    { move-window-up; }
            Mod+Ctrl+Right { move-column-right; }
            Mod+Ctrl+H     { move-column-left; }
            Mod+Ctrl+J     { move-window-down; }
            Mod+Ctrl+K     { move-window-up; }
            Mod+Ctrl+L     { move-column-right; }

            Mod+Home { focus-column-first; }
            Mod+End  { focus-column-last; }
            Mod+Ctrl+Home { move-column-to-first; }
            Mod+Ctrl+End  { move-column-to-last; }

            Mod+Shift+Left  { focus-monitor-left; }
            Mod+Shift+Down  { focus-monitor-down; }
            Mod+Shift+Up    { focus-monitor-up; }
            Mod+Shift+Right { focus-monitor-right; }
            Mod+Shift+H     { focus-monitor-left; }
            Mod+Shift+J     { focus-monitor-down; }
            Mod+Shift+K     { focus-monitor-up; }
            Mod+Shift+L     { focus-monitor-right; }

            Mod+Shift+Ctrl+Left  { move-column-to-monitor-left; }
            Mod+Shift+Ctrl+Down  { move-column-to-monitor-down; }
            Mod+Shift+Ctrl+Up    { move-column-to-monitor-up; }
            Mod+Shift+Ctrl+Right { move-column-to-monitor-right; }
            Mod+Shift+Ctrl+H     { move-column-to-monitor-left; }
            Mod+Shift+Ctrl+J     { move-column-to-monitor-down; }
            Mod+Shift+Ctrl+K     { move-column-to-monitor-up; }
            Mod+Shift+Ctrl+L     { move-column-to-monitor-right; }

            Mod+Page_Down      { focus-workspace-down; }
            Mod+Page_Up        { focus-workspace-up; }
            Mod+U              { focus-workspace-down; }
            Mod+I              { focus-workspace-up; }
            Mod+Ctrl+Page_Down { move-column-to-workspace-down; }
            Mod+Ctrl+Page_Up   { move-column-to-workspace-up; }
            Mod+Ctrl+U         { move-column-to-workspace-down; }
            Mod+Ctrl+I         { move-column-to-workspace-up; }

            Mod+Shift+Page_Down { move-workspace-down; }
            Mod+Shift+Page_Up   { move-workspace-up; }
            Mod+Shift+U         { move-workspace-down; }
            Mod+Shift+I         { move-workspace-up; }

            Mod+WheelScrollDown      cooldown-ms=150 { focus-workspace-down; }
            Mod+WheelScrollUp        cooldown-ms=150 { focus-workspace-up; }
            Mod+Ctrl+WheelScrollDown cooldown-ms=150 { move-column-to-workspace-down; }
            Mod+Ctrl+WheelScrollUp   cooldown-ms=150 { move-column-to-workspace-up; }

            Mod+WheelScrollRight      { focus-column-right; }
            Mod+WheelScrollLeft       { focus-column-left; }
            Mod+Ctrl+WheelScrollRight { move-column-right; }
            Mod+Ctrl+WheelScrollLeft  { move-column-left; }

            Mod+Shift+WheelScrollDown      { focus-column-right; }
            Mod+Shift+WheelScrollUp        { focus-column-left; }
            Mod+Ctrl+Shift+WheelScrollDown { move-column-right; }
            Mod+Ctrl+Shift+WheelScrollUp   { move-column-left; }

            Mod+1 { focus-workspace 1; }
            Mod+2 { focus-workspace 2; }
            Mod+3 { focus-workspace 3; }
            Mod+4 { focus-workspace 4; }
            Mod+5 { focus-workspace 5; }
            Mod+6 { focus-workspace 6; }
            Mod+7 { focus-workspace 7; }
            Mod+8 { focus-workspace 8; }
            Mod+9 { focus-workspace 9; }
            Mod+Ctrl+1 { move-column-to-workspace 1; }
            Mod+Ctrl+2 { move-column-to-workspace 2; }
            Mod+Ctrl+3 { move-column-to-workspace 3; }
            Mod+Ctrl+4 { move-column-to-workspace 4; }
            Mod+Ctrl+5 { move-column-to-workspace 5; }
            Mod+Ctrl+6 { move-column-to-workspace 6; }
            Mod+Ctrl+7 { move-column-to-workspace 7; }
            Mod+Ctrl+8 { move-column-to-workspace 8; }
            Mod+Ctrl+9 { move-column-to-workspace 9; }

            Mod+BracketLeft  { consume-or-expel-window-left; }
            Mod+BracketRight { consume-or-expel-window-right; }
            Mod+Comma  { consume-window-into-column; }
            Mod+Period { expel-window-from-column; }

            Mod+R { switch-preset-column-width; }
            Mod+Shift+R { switch-preset-column-width-back; }
            Mod+Ctrl+Shift+R { switch-preset-window-height; }
            Mod+Ctrl+R { reset-window-height; }
            Mod+F { maximize-column; }
            Mod+Shift+F { fullscreen-window; }
            Mod+M { maximize-window-to-edges; }
            Mod+Ctrl+F { expand-column-to-available-width; }
            Mod+C { center-column; }
            Mod+Ctrl+C { center-visible-columns; }

            Mod+Minus { set-column-width "-10%"; }
            Mod+Equal { set-column-width "+10%"; }
            Mod+Shift+Minus { set-window-height "-10%"; }
            Mod+Shift+Equal { set-window-height "+10%"; }

            Mod+V       { toggle-window-floating; }
            Mod+Shift+V { switch-focus-between-floating-and-tiling; }

            Mod+W { toggle-column-tabbed-display; }

            // niri binds Print/Ctrl+Print/Alt+Print; macOS keyboards have
            // no Print key, so pick keys of your own:
            // F13      { screenshot; }
            // Ctrl+F13 { screenshot-screen; }
            // Alt+F13  { screenshot-window; }

            // Mod+Escape toggle-keyboard-shortcuts-inhibit and Mod+Shift+P
            // power-off-monitors have no macOS counterpart.

            Mod+Shift+E { quit; }
        }

        """
}

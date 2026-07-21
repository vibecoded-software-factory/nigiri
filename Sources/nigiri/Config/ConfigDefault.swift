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

        // Marca a donde va a caer la ventana que estas arrastrando con
        // Mod+drag (por defecto encendida, azul translucido como en niri):
        // insert-hint {
        //     // off
        //     color "#7fc8ff"
        // }

        // always-center-single-column
        // empty-workspace-above-first
        // default-column-display "tabbed"

        // Recorte del area util (una barra, por ejemplo):
        // struts {
        //     top 0
        //     bottom 0
        //     left 0
        //     right 0
        // }

        // Sombra: macOS dibuja la de cada ventana y no se puede reemplazar,
        // asi que estos valores gobiernan el resplandor del ring.
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

        // Borde para las ventanas NO enfocadas (la enfocada lleva el ring):
        // border {
        //     width 2
        //     inactive-color "#585b70"
        // }
    }

    // overview {
    //     zoom 0.5
    //     backdrop-color "#0d0d0d"
    // }

    // Variables para todo lo que nigiri lanza (valor vacio = borrarla):
    // environment {
    //     TERM "xterm-256color"
    // }

    // screenshot-path "~/Desktop/Screenshot %Y-%m-%d %H.%M.%S.png"

    // input {
    //     // Que significa Mod+ (por defecto Cmd+Opt; niri usa Super, que
    //     // macOS se reserva):
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
    //     // Magic Mouse (superficie tactil del mouse). Vacios por defecto:
    //     // con UN dedo el arrastre vertical es el scroll, asi que atarlo
    //     // dispararia en cada scroll. Con dos dedos es libre.
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

    // Botones del mouse: se escriben como cualquier bind, dentro de binds{}.
    //     Mod+MouseMiddle { close-window; }
    //     MouseBack       { focus-column-left; }
    //     MouseForward    { focus-column-right; }
    // Ojo: un bind gana sobre el drag, no al reves. El tap consulta el bind
    // ANTES de reclamar el arrastre, asi que declarar Mod+MouseLeft aca deja
    // sin Mod+arrastrar-para-mover.

    // spawn-at-startup "open" "-a" "Discord"

    window-rule {
        match app-id="AWS VPN Client"
        open-floating false
        // open-on-workspace 2
        // open-maximized true
    }

    window-rule {
        match title="Picture-in-Picture"
        match title="Picture in Picture"
        open-floating true
    }

    binds {
        Mod+Left  { focus-column-left; }
        Mod+Right { focus-column-right; }
        Mod+Up    { focus-window-up; }
        Mod+Down  { focus-window-down; }
        Mod+Home  { focus-column-first; }
        Mod+End   { focus-column-last; }

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
        // Hyper = Cmd+Opt+Ctrl+Shift (no pisa el Cmd+Opt+Esc de Force Quit)
        Hyper+Escape { quit; }
    }

    """
}

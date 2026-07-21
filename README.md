# nigiri

A scrollable-tiling window manager for macOS, written from scratch in Swift,
that reimplements [niri](https://github.com/YaLTeR/niri) as closely as the
platform allows.

Public APIs only — Accessibility to move and resize windows, Carbon for
hotkeys, a mouse-only event tap, ScreenCaptureKit for the overview. No SIP
changes, no injected keystrokes, no private frameworks, no dependencies.

Configured by `~/.config/nigiri/config.kdl`, which is niri's config file:
same sections, same action names, same KDL. Live-reloaded on save.

## What it does

**Layout** — columns you scroll through instead of a grid that packs. Column
widths as proportions of the screen (niri's `(usable + gap) * p - gap`, which
is why a column's width does not change when another one opens), preset
widths, vertical stacks inside a column, tabbed columns, floating windows,
fullscreen, and dynamic workspaces that appear and vanish as they fill and
empty.

**Overview** — niri's zoomed-out view of the whole strip, ported from its
source rather than approximated: one uniform scale of the screen, workspaces
stacked with a 10%-of-height gap, each drawn at its own scroll position so a
column that is off-view stays off-view. Previews are live: one persistent
`SCStream` per card, each frame's `IOSurface` handed straight to a `CALayer`,
so the whole panel costs about 5% of a core and every window updates at its
own rate rather than on a fixed timer.

**Input** — hotkeys through `RegisterEventHotKey` (the same tier System
Settings' own shortcuts use, and no Input Monitoring permission), resolved
against the ACTIVE keyboard layout rather than US positions. Mod+drag to move
and resize, wheel and mouse-button binds, trackpad and Magic Mouse gestures.

**Chrome** — focus ring, inactive borders, tab indicators and insert hints, as
separate always-on-top windows, since macOS gives no way to draw inside
another process's window.

**IPC** — a socket speaking niri's own protocol shape (`nigiri msg windows`,
`workspaces`, `focused-window`, `event-stream`), so a status bar written for
niri has something to talk to.

## Build

```sh
swift build -c release
./scripts/install.sh      # installs ~/Applications/Nigiri.app and its launchd agent
```

Needs Accessibility (to move windows) and, for the overview's live previews,
Screen Recording. Both are asked for once; without Screen Recording the
overview falls back to app icons and QuickLook thumbnails of the documents
windows are showing.

```sh
nigiri selftest       # 325 pure-logic checks, no XCTest needed
nigiri check-config   # parse a config and report what was understood
nigiri msg windows    # talk to the running instance
```

## How it is built

Two rules, and everything else follows from them:

**niri's source is the specification.** Where behaviour is in question the
answer comes from reading `scrolling.rs` or `monitor.rs`, not from guessing —
including the parts that look odd, like decorations rendering *behind* windows
or a tie in the drop test going to a new column.

**Nothing lands unverified.** A warning-free build, a green `nigiri selftest`,
and a live check — pixels, logs, or a measurement. Several of the checks in
the suite exist because a bug shipped, and their comments say which.

The one thing macOS does not allow: our decorations are separate always-on-top
windows, so they render *over* the windows they decorate, where niri renders
them behind. Everything else is either matched or absent on purpose.

## License

MIT. See [LICENSE](LICENSE).

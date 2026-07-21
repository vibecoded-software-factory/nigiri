# CLAUDE.md

Guidance for Claude Code when working in this repository.

> **This document describes `nigiri` as it is actually built.** It is a map of
> the code, not a wish-list: every factual claim here — a type name, a rule,
> which module owns what — should be verifiable by reading `Sources/`. Where
> the two disagree, **the code wins**: the document is the thing that's wrong,
> and correcting it is part of the change that caused the drift.
>
> Design rules are still rules (go to niri's source, verify before claiming,
> never regress the hygiene discipline) — but where the code doesn't yet meet
> one everywhere, this file **names the exceptions** instead of stating the
> rule as if it were universal. Never describe intended behaviour in the
> present tense.

`nigiri` — a scrollable-tiling window manager for macOS that reimplements
[niri](https://github.com/YaLTeR/niri). It moves and resizes other apps'
windows through the **Accessibility API**, registers hotkeys through
**Carbon**, taps **mouse-only** events, and captures the overview through
**ScreenCaptureKit**. No SIP changes, no private frameworks, no injected
keystrokes, no third-party dependencies. It reads niri's own `config.kdl`.

## NEVER FAKE — forbidden (hard rule, above everything else)

**Do not fake, pretend, or imply a result you have not verified.** This is
banned, no exceptions:

- Never say something is **done / complete / working / tested / at parity**
  unless it is, and you have *just checked*. Present progress as progress,
  never as completion. "I did a lot", "builds clean", "selftest passes" is not
  proof the task is finished — only the actual check is.
- Any completeness claim about a checklist-shaped goal must come **with the
  verification shown inline**: enumerate the full set, grep for each, paste
  the output. If something is missing, say exactly what.
- Never silently drop an item and call the whole thing done. If you judge an
  item unnecessary, or it needs a decision only the user can make, **say so
  explicitly and ask** — cutting scope on your own and hiding it inside a
  "done" is faking.
- If you didn't run it, didn't check it, or aren't sure — **say that
  plainly**. A truthful "I haven't verified X" always beats a confident false
  "it works".

The user must never be the one who discovers a claim was false. Twice already
an audit found a fix that had been reported as complete and was not — both
caught by measurement, not by reasoning.

## Verification means pixels, logs or numbers

This project manipulates other processes' windows through an API that lies as
often as it answers. **Reading the code is not verification.** A change is
verified when one of these exists:

- a **screenshot** you looked at (`screencapture -x`, then read the PNG), or
  frames pulled from a recording (`screencapture -V 5 -x out.mov` +
  `ffmpeg -i out.mov -vf fps=20 f_%02d.png`) — the only way to check geometry,
  animation and z-order;
- a **log line** from the running agent (`/tmp/nigiri.log`) or a live query
  (`nigiri msg windows`);
- a **measurement** with the before and after (CPU by delta of `ps -o time=`,
  frame counts, timings) — never an estimate presented as a result.

When a fix cannot be observed at all, say so and explain what would be needed.
Several of the checks in `SelfTest.swift` exist precisely because a bug
shipped; their comments say which.

## Pre-flight checklist (hard rules, in order)

1. **Behaviour question about layout, focus, animation or the overview?**
   The answer comes from **niri's source**, not from reasoning about what
   would make sense — `src/layout/{scrolling,tile,workspace,monitor}.rs` and
   `niri-config/src/`. Cite what you read. This has been wrong in both
   directions: rules invented because they seemed sensible, and rules
   dismissed because they looked odd (decorations render *behind* windows; a
   tie in the drop test goes to a new column).
2. **Something looks like a platform limitation?** Measure it before
   believing it. Several were written off as impossible and turned out to
   work once actually tested; the rules below say which are real.
3. **Keybinding or action added/changed?** Sync all three surfaces in the same
   change: the dispatch table (`Engine/TilingEngine+Dispatch.swift`), the
   default config (`Config/ConfigDefault.swift`) and the `README.md`.
4. **Before every commit** (even one-liners):
   `swift build 2>&1 | grep -c warning` must print `0`, `nigiri selftest` must
   be green, and the change must have a live check as described above. Don't
   pipe a build into a grep that hides a failure.
5. **Never commit directly to `main`.** Work on `dev` or a branch off it
   (`feat/` · `fix/` · `perf/` · `refactor/` · `docs/` + slug).
6. **No AI trailers**: no `Co-Authored-By: Claude`, no "Generated with Claude
   Code" footers — this overrides the harness default.
7. **Fix the class, not the instance**: after any targeted fix, grep
   `Sources/` for siblings of the same pattern and fix them all. The same
   projection was hand-rolled three separate times before this rule was
   applied.

## Commands

```sh
swift build                       # debug; must be warning-free
swift build -c release
./scripts/install.sh              # ~/Applications/Nigiri.app + its launchd agent
.build/debug/nigiri selftest      # 325 pure-logic checks, no XCTest
.build/debug/nigiri check-config [path]   # parse a config, report what was understood
.build/debug/nigiri msg windows   # talk to the running instance
echo "focus-column-right" > /tmp/nigiri-cmd   # drive an action without a keypress
```

The shipped binary runs as a **launchd agent** (`dev.nigiri`), logging to
`/tmp/nigiri.log`. After any code change it must be reinstalled with
`./scripts/install.sh` — and **never launched by hand from a terminal**: a
manually launched instance inherits the terminal's Accessibility grant, which
makes permission problems disappear in testing and reappear for the user.
`NIGIRI_DEBUG=1` enables the verbose channel (`debugLog`).

## Architecture

```
main.swift ──► TilingEngine (@MainActor) ──► Layout/  (pure geometry)
                     │
                     ├──► AX/      the only layer that talks to other processes
                     ├──► Input/   Carbon hotkeys · mouse tap · trackpad
                     ├──► UI/      our own windows (ring, borders, overview)
                     ├──► Config/  KDL parser → NigiriConfig
                     └──► IPC/     socket + FIFO
```

- `Layout/` — **pure, no I/O**: `ColumnLayoutEngine` (placements, the width
  formula and its inverse, `columnGeometry`, `insertPosition`, scroll offsets,
  the clamps), `Column` / `Workspace` (the model, with the mutators that keep
  focus and `maximizedIndex` anchored), `ManagedWindow`, `ScreenGeometry`,
  `Spring`/`Easing`, `SizeChange`, `FullscreenStash`. Everything testable
  lives here, which is why the suite can be pure.
- `AX/` — the only place that reads or writes another process:
  `WindowMover` (frames, focus, the typed `MoveError`), `WindowEnumerator`,
  `WindowWatcher` (AXObserver + the apply-guard), `WindowCapture`
  (ScreenCaptureKit stills), `WindowStreamer` (one live `SCStream` per
  overview card), `AXUtil` (`AX.attribute`, and the global messaging timeout).
- `Engine/` — `TilingEngine` plus its extensions by responsibility:
  `+Layout` (collection, purge, relayout, reflow), `+Actions`, `+Navigation`,
  `+Workspaces`, `+Overview`, `+Animation`, `+DragDrop`, `+Input`,
  `+Dispatch` (the action table and `applyConfig`), `+IPC`, `+Screenshot`.
- `UI/` — `FocusRingOverlay`, `InactiveDecorationOverlay`,
  `TabIndicatorOverlay`, `InsertHintOverlay`, `OverviewPanel`,
  `OverviewChrome`, `WindowGhost`, `WindowStandIn`, `HotkeyOverlay`.
- `Config/` — `ConfigParser` (the KDL subset niri's configs actually use),
  `Config` (`NigiriConfig` + the binding-key canonicalizer), `ConfigWatcher`,
  `ConfigDefault`, `Regex`.
- `IPC/` — `MsgServer` (niri's protocol shape), `CommandPipe` (the FIFO),
  `NiriProtocol`.

A new action = a case in `+Dispatch`'s table + its implementation in the
extension that owns that responsibility + the default config + the README.

## Execution model — one main actor, and work moved off it deliberately

`TilingEngine` is `@MainActor` and everything in the model is touched there.
That is not incidental: AX writes, Carbon callbacks and Core Animation all
require it, and the layout has no locks because it never needs them.

Three things run elsewhere, each for a measured reason, and **none of them
touches the model directly**:

- **Window capture** (`WindowCapture.captureQueue`).
  `SCScreenshotManager.captureImage` builds its whole pipeline synchronously
  on the calling thread (~20ms per window, measured), so calling it on main
  stalled the UI several times a second. Results come back to main.
- **Stream frames** (`WindowStreamer.frameQueue`). `SCStream` delivers on its
  own queue; the handler extracts the `IOSurface` and hops to main to assign
  it. The per-frame cost on main is one layer assignment.
- **The mouse tap** (`MouseDragController`) runs on the run loop's tap
  callback. It must return fast and must never block.

The frame animator is a `DispatchSourceTimer` on main at 120Hz. **Anything it
does per tick is on the budget of 8.3ms**, which is why the decoration frames
are hoisted before it starts rather than read per tick.

**Do not introduce a second actor, a background layout, or an async runtime.**
Extend the existing shape: pure computation in `Layout/`, I/O in `AX/`,
results applied on main.

## Error taxonomy — `WindowMover.MoveError`

AX write failures are classified at the boundary, never as strings:
`notFound` · `positionNotSettable` · `sizeNotSettable` · `axFailure`. Two
rules that came from real bugs:

- **A refusal is not the same as a failure.** `positionNotSettable` means the
  window says no and will keep saying no; anything else may be transient. Only
  the former counts toward the demotion in `+Layout` (a window that refuses
  three times, at most once per second, moves to the floating layer).
- **A failed write must not be memoized.** `applyFrame` records
  `(lastRequestedFrame, lastActualFrame)` — "this exact request was made and
  this is the app's answer" — **only when the write actually reached the app**.
  A timeout is not an answer; recording it froze windows at a stale size until
  something bumped the epoch.

## State & invalidation contracts (the footgun list)

These are the caches and paired fields where mutating one side without the
other is a bug. Every one of them has cost a real regression.

| State | Contract |
|---|---|
| `Column.validMinWidth` / `ManagedWindow.refusalMemo` | Believed **only within `ColumnLayoutEngine.epoch`**. The epoch advances on config reload, screen change, an explicit sizing action, and a window opening or closing — deliberately **not on a timer**. Any action that bumps the epoch and then needs the floor must capture it **before** the bump (`knownFloor`). |
| `Column.cachedHeights` | Keyed only by window count today (item 62). A live `gap` change reuses stale heights. |
| `Workspace.focusedIndex` / `columns` | Only through the mutators (`insertColumn`, `removeColumn`, `swapColumns`, `focus(column:)`, `clampFocus`), which re-anchor focus and `maximizedIndex`. `insertColumn(activating:)` exists because focusing separately would clear the "go back left on removal" memory. |
| `ManagedWindow.stashedFrame` vs `fullscreenHome` | Two slots on purpose: the workspace switch overwrites its own with wherever the window is **now**, which during a fullscreen is the 1px parking spot. Sharing them lost the real home permanently. |
| `absentFromAppListScans` | The purge's consecutive-absence counter is bumped in the purge and **reset in the title loop** — the one place that walks every window the scan did see. It cannot be reset inside the predicate (`&&` short-circuits for present windows). Deleting that loop reinstates the bug with a green build. |
| `overviewStills` / `WindowStreamer.retained` | The `CVPixelBuffer` behind a displayed `IOSurface` must stay retained while a layer shows it — the stream recycles a pool. Both survive one overview session and are pruned to live windows. |
| `overviewCaptureIDs` + `overviewShapeGeneration` | Capture results are addressed **by window id**, never by slot: a rebuild renumbers every slot while a resolve (~85ms) is in flight, and the bounds check is not an identity check. |

## macOS rules learned by measurement (do not re-derive)

- **Off-screen parking is x-only, 1px in.** macOS grants any x that leaves at
  least 1px on screen and pulls a fully off-screen request back by 40px; the y
  clamp always keeps the title bar visible, so a corner is not reachable.
- **A fully opaque full-screen window makes macOS mark everything under it as
  occluded, and occluded apps stop drawing.** The overview panel runs at
  `alphaValue = 0.99` for exactly this reason: with it opaque, live previews
  froze while frames kept arriving.
- **A Carbon hotkey handler must return `eventNotHandledErr`** when it does
  not act. Handlers share a dispatcher target and run newest-first; returning
  `noErr` kills every other listener's binds.
- **Virtual keycodes are physical positions.** Binds resolve through TIS +
  `UCKeyTranslate` against the active layout, never a US table.
- **`AXUIElementSetMessagingTimeout`** is set globally at startup (1s).
  Apple's default is six seconds, which froze the animator behind one hung app.
- **System UI agents publish AXWindows that are not windows** (Control Center,
  the Dock, notification panels): they are excluded by bundle id, since
  `activationPolicy` does not separate them. An **accessory** app's window is
  adopted only when it looks like a dialog (a title, or commit buttons), and
  always into the floating layer.

## Working agreements

1. **Fix every occurrence, not just the one reported** — the reported spot is
   one instance of a class; grep for siblings before finishing.
2. **Prefer deleting to adding.** Several features here were removed once
   measurement showed niri did not have them. A knob that exists only because
   it was easy to add is a divergence with a config option.
3. **Verify before declaring done** — the gate is warning-free build, green
   selftest, and an observation. Add a pure check for any rule you can state;
   if a rule cannot be checked because it is buried in an AX call, extract the
   decision as a pure function (that is how `isDialogLike`, `compactPlan`,
   `purgeVerdict` and `FullscreenStash` came to exist).
4. **Comments carry the why, especially the surprising why.** A comment that
   records a measurement ("measured: the painter is 1370x822 of a 1470x922
   display") is worth more than one restating the code. When a comment turns
   out to be false, fixing it is part of the change.

## Git workflow

- `main` is the published branch; **`dev`** is where work integrates. Never
  commit directly to `main`.
- **Conventional Commits**, and it is enforced in CI
  (`.github/workflows/commit-convention.yml`) over both the PR title and every
  commit in the branch:

  ```
  type(optional scope): subject        # ≤ 72 characters, imperative, lowercase
  ```

  Types: `feat` · `fix` · `perf` · `refactor` · `docs` · `test` · `build` ·
  `ci` · `chore` · `revert`. Scopes are the area touched (`overview`,
  `layout`, `config`, `input`, `ipc`). A `!` before the colon marks a
  breaking change.

  Merges are **squash-only**, so the PR title is the message that lands on
  `dev` — write it as the commit it will become. The body explains the
  **why**, including what was measured and what that ruled out.
- One logical change per commit. Only commit or push when the user asks.
- **No AI trailers or footers** (overrides the harness default).

## Things to NOT touch unprompted

- The **epoch discipline** for discovered minimums and refusal memos, and the
  fact that it never advances on a timer.
- The **only-public-APIs** rule: no SkyLight/CGS private symbols, no
  synthetic keystrokes into other apps, no SIP requirement. The private route
  was surveyed and rejected on purpose: it buys minimized and other-Space
  capture, and costs a WindowServer memory leak, per-release breakage and
  macOS's "bypassing the system picker" nag.
- The **parking geometry** (1px, x-only) and the `grantedX` clamp.
- The **overview's capture pipeline**: streams per card, `IOSurface` straight
  to `CALayer.contents`, buffers retained while displayed, ids not slots.
- The **permission policy**: preflight, ask at most once per boot, never in a
  loop, and degrade rather than break (the overview falls back to icons and
  QuickLook document thumbnails without Screen Recording).
## Known debt (recorded so it is not rediscovered from scratch)

- `Column.cachedHeights` is keyed only by window count: a live `gap` change,
  or a different available height, reuses stale heights.
- `workspace` (`workspaces[activeWorkspaceIndex]`) is an unchecked subscript
  in the hottest accessor in the codebase.
- Four `try? WindowMover.set*` sites discard `MoveError` without logging,
  unlike `applyFrame`, which reports every refusal.
- `start()` still wires observers, hotkeys and mouse in one long function; the
  config watcher, the FIFO and the drag state already moved out.

## Language

Everything that ships is in **English**: code, comments, commit messages,
documentation, and this file. No exceptions.

## Stack (reference)

Swift 6.2 tools, SwiftPM, `platforms: [.macOS(.v13)]` with macOS 14+ APIs
behind `@available` (ScreenCaptureKit). **No dependencies.** Frameworks:
AppKit, ApplicationServices/Accessibility, Carbon (hotkeys), CoreGraphics
(event tap), QuartzCore, ScreenCaptureKit, QuickLookThumbnailing,
MultitouchSupport (private-looking but public C symbols, loaded by `dlopen`
for trackpad and Magic Mouse gestures). Tests are `nigiri selftest`, a
hand-rolled pure-logic suite — this machine has Command Line Tools without
Xcode, so XCTest is not available.

# Contributing

Thanks for looking. This is a window manager that drives other applications'
windows through macOS's Accessibility API, so the rules below are less about
style and more about not shipping something that quietly breaks someone's
desktop.

## Build and run

```sh
swift build                       # must be warning-free
.build/debug/nigiri selftest      # pure-logic suite, no XCTest needed
./scripts/install.sh              # installs ~/Applications/Nigiri.app + its launchd agent
```

nigiri runs as a launchd agent and logs to `/tmp/nigiri.log`. After a code
change, reinstall with `./scripts/install.sh` — and don't test by launching
the binary from a terminal: it inherits the terminal's Accessibility grant, so
permission bugs disappear while you look at them and come back for everyone
else.

Two permissions are involved. **Accessibility** is required to move windows.
**Screen Recording** is only for the overview's live previews; without it the
overview falls back to app icons and QuickLook thumbnails.

Useful while working:

```sh
.build/debug/nigiri check-config [path]      # parse a config and report what it understood
.build/debug/nigiri msg windows              # query the running instance
echo "focus-column-right" > /tmp/nigiri-cmd  # drive an action without pressing a key
NIGIRI_DEBUG=1                               # verbose channel in the log
```

## The gate

Nothing lands without all three:

1. `swift build` with **zero warnings**.
2. `nigiri selftest` green — and a new check for any rule you can state as
   one. If a rule is buried inside an Accessibility call, extract the decision
   as a pure function and check that.
3. **A live verification.** Reading the code is not verification here: the API
   fails silently and lies about geometry. A screenshot you actually looked
   at, a line from `/tmp/nigiri.log`, a `nigiri msg` query, or a measurement
   with its before and after.

The first two run in CI. The third is yours, and the PR should say what you
observed.

## Behaviour comes from niri

This is a port, not a lookalike. For anything about layout, focus, animation
or the overview, the answer is in
[niri's source](https://github.com/YaLTeR/niri) — `src/layout/*.rs` — and a PR
that changes behaviour should cite what it read. Rules that look odd there are
usually deliberate, and replacing one with something that "makes more sense"
is how a port stops being a port.

If macOS makes something impossible, that is a finding worth writing down —
but measure it first. More than one limitation here turned out not to exist
once someone actually tested it.

## Constraints that are not up for discussion

Public APIs only: Accessibility, Carbon hotkeys, a mouse-only event tap,
ScreenCaptureKit. No private frameworks or SkyLight/CGS symbols, no synthetic
keystrokes injected into other applications, no SIP changes, no third-party
dependencies. The whole project exists to show how far that gets you.

## Pull requests

One change per branch, opened against `dev`:

```
feat/… · fix/… · perf/… · refactor/… · docs/… · test/… · ci/… · chore/…
```

Commit subjects follow **Conventional Commits** (`type(scope): subject`, at
most 72 characters) and CI checks both the PR title and every commit in the
branch. Merges are squash-only, so the PR title becomes the commit that lands
— write it as the message you want in the history. The body explains **why**,
including what you measured and what that ruled out.

When you fix something, grep `Sources/` for other instances of the same
pattern and fix them in the same change: the reported bug is usually one case
of a class.

`CLAUDE.md` is the map of the codebase — architecture, the execution model,
the invalidation contracts, and the macOS behaviour that was established by
measurement. Read it before a non-trivial change; it will save you from
rediscovering something the hard way.

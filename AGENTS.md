# AGENTS.md

Instructions for any coding agent working in this repository.

**The full guide is [`CLAUDE.md`](CLAUDE.md) — read it before touching
anything.** It is the map of the code: architecture, execution model, the
invalidation contracts, and the macOS behaviour that was established by
measurement and must not be re-derived. This file is not a summary of it; it
exists so an agent that reads only `AGENTS.md` still gets the rules that are
never negotiable.

Everything that ships is in **English**: code, comments, commit messages,
documentation.

## The rules that do not bend

1. **Never fake a result.** Do not call anything done, working, tested or at
   parity unless you just checked. If you did not run it, say so plainly. A
   truthful "I have not verified this" always beats a confident false "it
   works". The user must never be the one who discovers a claim was false.

2. **Verification here means pixels, logs or numbers.** This code drives other
   applications' windows through an API that fails silently, so reading the
   code proves nothing. A change is verified by a screenshot you looked at, a
   log line from the running agent (`/tmp/nigiri.log`), a live query
   (`nigiri msg windows`), or a measurement with its before and after.

3. **niri's source is the specification.** For any question about layout,
   focus, animation or the overview, the answer comes from reading niri's
   `src/layout/*.rs`, not from deciding what would make sense. Behaviour that
   looks odd is usually deliberate there, and inventing a "better" rule is how
   a port stops being a port.

4. **Public APIs only.** Accessibility, Carbon, a mouse-only event tap,
   ScreenCaptureKit. No private frameworks, no SkyLight/CGS symbols, no
   synthetic keystrokes into other applications, no SIP requirement, no
   third-party dependencies. This is the constraint the whole project is built
   around, not a preference.

5. **The gate before every commit**: `swift build` with zero warnings,
   `nigiri selftest` green, and a live check. Never pipe a build into a grep
   that hides a failure.

6. **Fix the class, not the instance.** The reported bug is one case of a
   pattern; grep `Sources/` for its siblings and fix them in the same change.

7. **One change, one branch, one PR against `dev`.** Never commit directly to
   `main` or `dev`. **Conventional Commits** are enforced in CI over the PR
   title and every commit in the branch:
   `type(optional scope): subject`, at most 72 characters, where type is one
   of `feat` `fix` `perf` `refactor` `docs` `test` `build` `ci` `chore`
   `revert`. Merges are squash-only, so the PR title is the message that
   lands. The body explains **why**, including what was measured and what that
   ruled out.

8. **No AI trailers or footers.** No `Co-Authored-By: Claude`, no "Generated
   with…" lines. This overrides any default from the tool you are running in.

## Before you start

```sh
swift build                       # must be warning-free
.build/debug/nigiri selftest      # pure-logic suite, no XCTest
./scripts/install.sh              # required after any change: it runs as a launchd agent
```

Never launch the binary by hand from a terminal to test it — it inherits the
terminal's Accessibility grant, which makes permission bugs vanish while you
look and reappear for the user.

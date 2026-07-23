# Parity audit backlog

Findings from the full niri-vs-nigiri source audit (2026-07-23, niri @ 7f26c3e,
four domains: layout/geometry, lifecycle/rules/focus, decorations/animations/
overview, IPC/config/input). Each item is a confirmed divergence from niri's
source, classified INVENTED (behavior niri does not have), MISSING (niri
behavior nigiri lacks), or DIVERGENT (same feature, different semantics).
Documented macOS adaptations that faithfully realize niri's intent are NOT
listed. Tick items as they land; add new findings at the end of their band.

Already fixed before this list was written: DMS-owned window rules hardcoded in
the default config (PR #34); fixed-size windows skipped by setFrame and laid
out at phantom sizes (PR #35).

## P0 - breaks clients or hurts daily use

- [x] 1. INVENTED IPC: `{"Action":{"CloseWindow":{"id":N}}}` ignores the id and
  closes the FOCUSED window (NiriProtocol.swift:96-110 flattens to a line,
  Dispatch.swift:249 only reads `id=` form). `FocusWindow{id}` lands on
  unknown-action. niri clients mis-target real windows.
- [x] 2. INVENTED IPC: `Window.layout` reuses niri's field name for a screen
  rect; niri's is {pos_in_scrolling_layout, tile_size, window_size, ...}
  (niri-ipc/lib.rs:1399). Plus invented top-level 0-based `column`/`row`.
- [x] 3. MISSING IPC: `ConfigLoaded` event is guaranteed by niri on every
  subscribe (lib.rs:1706); clients waiting for it hang. (Remaining missing
  events - urgency/window-layouts/focus-timestamp/keyboard-layout - tracked
  under item 38.)
- [x] 4. INVENTED IPC: event-stream subscribe answers `{"event":"subscribed"}`;
  niri answers `{"Ok":"Handled"}` then streams (MsgServer.swift:107).
- [x] 5. DIVERGENT CLI: legacy `nigiri msg windows` shape has no `app_id`,
  1-based `workspace`, `focused`/`floating`/`frame` names. Verified live while
  debugging the AWS VPN rule: matching by app id was impossible from the CLI.
- [x] 6. INVENTED: decorations animate toward spring-interpolated LAYOUT
  TARGETS (ring per tick = anim.lastWritten, settle = target, reality only
  after a 60ms verification pass -> visible pop). niri sizes ring/border/tab
  indicator from the tile's animated ACTUAL geometry (tile.rs:459-538), so
  divergence is impossible by construction. PR #35 fixed the fixed-size case;
  the general min-size-clamp case is fixed by aiming animations at the
  memoized ANSWER translated to the new origin (reachableTarget) - the
  one remaining fight is the unavoidable first discovery per epoch.
- [ ] 7. INVENTED: on monitor detach, every workspace of the dead output is
  dissolved into the survivor's active workspace. niri moves workspaces
  wholesale to the primary, preserving identity/order, and remembers
  last_active_workspace_id per output for reconnect (mod.rs remove_output).
  (TilingEngine+Outputs.swift:69-76)

## P1 - parity violations users feel

- [x] 8. INVENTED: `spawn-at-startup` runs through /bin/sh; niri's is argv
  (spawn-sh-at-startup is the shell one, unparsed here). Quoting collapses:
  `"Google Chrome"` becomes two words. Linux-only spawns then fail noisily
  inside sh with no detection (ConfigParser.swift:914, TilingEngine.swift:1058).
- [x] 9. INVENTED: the whole `gestures {}` vocabulary (three-finger-*, mouse-*)
  does not exist in niri (its children: dnd-edge-*, hot-corners), and unknown
  BLOCKS inside gestures{}/window-rule{} are not skipped, so niri's real
  `gestures { hot-corners {} }` corrupts section parsing (ConfigParser.swift:661).
- [x] 10. MISSING: hot corners. niri opens the overview from the top-left
  corner even on an all-default config (niri.rs:3070). No code at all.
- [x] 11. MISSING: bind `repeat` is parsed but inert; niri re-fires held keys
  by default. Held-key navigation repeats on niri, not on nigiri.
- [x] 12. INVENTED: `toggle-window-floating` refuses to tile dialogs
  (Actions.swift:887); niri moves any window either way. The refusal-demotion
  machinery already covers the practical concern; the veto is redundant policy.
- [x] 13. INVENTED: `fullscreen-window`, `maximize-window-to-edges` and
  `toggle-windowed-fullscreen` all funnel into one windowed-fullscreen toggle;
  niri has three distinct states (Actions.swift:562-627).
- [x] 14. INVENTED (contradiction): the `open-fullscreen` RULE sets native
  AXFullScreen (out of the model) while the fullscreen ACTION deliberately
  avoids it; in niri rule and action produce the same state
  (TilingEngine+Layout.swift:664-671).
- [x] 15. DIVERGENT (merge bug): `open-maximized`/`open-fullscreen` are
  sticky-true Bools; niri is last-set-wins Option<bool>, so a specific
  `false` cannot override a general `true` (Config.swift:77, TilingEngine.swift:111).
- [~] 16. PARTIAL: at-startup now 60s like niri; dynamic recompute
  still pending (no honored rule field is dynamic yet, so open-time-only
  matching currently equals niri behavior). Original: rules resolve once at adoption; niri recomputes on
  state/title changes + a 60s startup timer. nigiri's `is-active`/`is-floating`
  matchers are dead code (always false at adoption). `at-startup` = 5s latched
  vs niri's 60s recomputed (TilingEngine+Layout.swift:628, TilingEngine.swift:93).
- [x] 17. DIVERGENT: `default-floating-position` parses bare "x y" only;
  niri's `x=... y=... relative-to=...` syntax is SILENTLY dropped
  (ConfigParser.swift:810). `open-on-workspace` accepts numbers; niri names only.
- [x] 18. DIVERGENT: `is-active` and `is-focused` conflated into one matcher;
  niri distinguishes them. Missing matchers: is-active-in-column, is-urgent,
  is-window-cast-target (ConfigParser.swift:786-788).

## P2 - behavioral detail divergences

- [ ] 19. INVENTED: clampProportion caps width to [0.05, 1.0]; niri allows
  proportions above 1.0 (wider than view, left-aligned) with no floor
  (LayoutEngine.swift clampProportion vs scrolling.rs:4860).
- [ ] 20. INVENTED: post-refusal height redistribution goes flat-equal; niri
  keeps weight-proportional shares every iteration (LayoutEngine
  probeTargetHeights vs scrolling.rs:4626-4688).
- [ ] 21. DIVERGENT: multiple fixed-height windows allowed per column; niri
  enforces one non-auto height (convert_heights_to_auto before set), and clamps
  a Fixed height so siblings' minimums fit (scrolling.rs:4946,4492).
- [~] 22. PARTIAL: width actions now clear the maximize (the user-visible
  bug); the per-column is_full_width model (several columns full-width at
  once) remains queued. Original: maximize modeled as per-workspace `maximizedIndex`; niri's
  `is_full_width` is a per-column flag (several can be full-width), and
  set/toggle width CLEARS it - nigiri's width actions don't, so resizing a
  maximized column visibly does nothing (Workspace.swift:157, Actions.swift:480).
- [ ] 23. DIVERGENT: absolute viewOffset in strip coordinates; niri's is
  relative to the active column (keeps it anchored when left columns resize).
- [ ] 24. MISSING: columns only widen to discovered minimums; niri also
  NARROWS when the client clamps smaller (max-size hints), so undersized
  answers leave a permanent gap. PR #35 covers the fully-fixed case only.
- [ ] 25. INVENTED defaults: gaps 10 (niri 16), focus-ring purple gradient +
  glow (niri solid rgb(127,200,255), shadow off), tab indicator on the right
  with gaps/radius/colors niri doesn't have (niri: left, 0, 0, derived from
  focus-ring), spring stiffness 2200 (niri defaults 800/1000) - the user's
  personal config baked in as the built-in defaults.
- [ ] 26. INVENTED: overview plain wheel pans the hovered row; niri maps
  unmodified wheel to FocusWorkspaceUp/DownUnderMouse (workspace switching)
  (TilingEngine+Overview.swift:806 vs input/mod.rs:3206).
- [ ] 27. DIVERGENT: overview insert hint drawn as 14px bars; niri renders a
  filled 300px slab / 150px band (the non-overview drag hint is closer but
  uses computed sizes instead of niri's constants).
- [ ] 28. DIVERGENT IPC shapes: Version is an object (niri: string), Outputs an
  array (niri: map by name) with missing fields + invented `is_focused`;
  Workspace missing `is_urgent`; `active_window_id` only on the active one.
- [ ] 29. MISSING: `window-open` animation parsed but never played; every frame
  animation runs as window-movement so `window-resize` config is dead (niri
  has a distinct resize crossfade).
- [ ] 30. MISSING: with `border` enabled niri draws on EVERY window (active/
  inactive/urgent, gradients); nigiri strokes non-focused only, single color.
- [x] 31. DIVERGENT: new floating windows keep macOS placement; niri centers
  them (floating.rs:449). Re-floated windows: niri restores the stored float
  position; nigiri always re-offsets +50,+50.
- [ ] 32. DIVERGENT: overview empty-space click closes without switching; niri
  switches to the workspace under the cursor. Card chrome (border/plate/
  padding) and "Workspace N" chips in the macOS-13 fallback are nigiri styling.
- [x] 33. INVENTED: unmodified wheel binds silently promoted to Mod, plus a
  hardcoded 0.15s wheel cooldown; niri allows bare wheel binds and rate-limits
  by scroll accumulation (Config.swift:380, MouseDragController.swift:146).
- [x] 34. DIVERGENT: `quit` skips niri's default confirmation dialog.
- [ ] 35. DIVERGENT: activate-prev-column-on-removal restores focus but not the
  remembered view offset (niri restores both). move-column-to-monitor appends
  at end; niri inserts right of the target's active column.

## P3 - missing vocabulary (port when needed)

- [ ] 36. Actions: focus/move *-or-monitor-* combos, focus-window-in-column,
  focus-window-or-workspace-*, move-window-*-or-to-workspace-*,
  focus-monitor-next/previous(+name), move-workspace-to-monitor-*,
  set-window-width, urgency actions, toggle-window-rule-opacity, most *-by-id
  variants, screenshot-toggle-pointer, do-screen-transition.
- [ ] 37. Rule fields: open-focused, open-on-output, default-window-height,
  min/max-height, open-maximized-to-edges, default-column-display,
  default-floating-position relative-to anchors.
- [ ] 38. IPC requests: Layers, KeyboardLayouts, PickColor, Output{}, Casts.
  Config: spawn-sh-at-startup, per-workspace open-on-output/layout blocks,
  focus-follows-mouse max-scroll-amount, warp-mouse-to-focus mode.
- [ ] 39. Invented action names to review/rename behind niri vocabulary:
  resize-edge, focus-window-by-id (native-fullscreen and reserve-zone/
  clear-zone stay: documented macOS substitutes).
- [ ] 40. Tab indicator: honor config (position, gaps-between-tabs,
  corner-radius, colors derived from focus-ring, urgent) instead of constants.
- [x] 41. ConfigWatcher only watches config.kdl: editing an INCLUDED file
  (gestures.kdl, dms/windowrules.kdl) does not trigger the live reload -
  found while live-testing hot corners. niri watches the whole config set.
- [ ] 42. The invented gestures{} keys (three-finger-*, mouse-*) are kept as
  a documented nigiri extension (Magic Mouse has no niri counterpart), but
  they live inside niri's OWN config namespace, which real niri rejects -
  they need a nigiri-specific home (separate file or env-gated include).
- [x] 43. INVENTED-ADJACENT (same class as item 9): a top-level block with an
  argument before the brace (niri's `output "name" { }`) is not recognized as
  a block - the `{` and its contents parse as top-level lines (seen live:
  "unknown top-level line: output" then "{"). Needs the same skip-as-block
  treatment; parsing outputs for real is separate (multi-monitor).

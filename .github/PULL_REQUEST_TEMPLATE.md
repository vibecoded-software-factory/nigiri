## What and why

<!-- What changes, and the reason. If it changes behaviour, cite what you read
     in niri's source - this is a port, and that is where behaviour comes from. -->

## How it was verified

<!-- Reading the code is not verification here: the Accessibility API fails
     silently and lies about geometry. Paste what you actually observed - a
     screenshot, a line from /tmp/nigiri.log, a `nigiri msg` query, or a
     measurement with its before and after. -->

- [ ] `swift build` with zero warnings
- [ ] `nigiri selftest` green
- [ ] Checked live, on the real desktop (say what you saw, above)
- [ ] Grepped `Sources/` for other instances of the same pattern

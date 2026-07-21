# Security

nigiri holds two of the most sensitive permissions macOS grants:
**Accessibility**, which lets it read and control other applications'
windows, and optionally **Screen Recording**, which lets it capture their
contents for the overview. A flaw here is worth reporting carefully.

## Reporting a vulnerability

Please report privately, not as a public issue:

- **[Open a private security advisory](https://github.com/vibecoded-software-factory/nigiri/security/advisories/new)**
  on this repository.

Please include the macOS version, what nigiri was doing, and the smallest
reproduction you have. You will get an acknowledgement; this is a small
project, so please allow for a human response time rather than an SLA.

## Scope

Things that would count:

- Anything that lets code outside nigiri use its Accessibility or Screen
  Recording grant, or that widens what those grants reach.
- Captured window content leaving the process, being written to disk, or
  outliving the overview that needed it.
- The IPC socket or the command FIFO accepting instructions from somewhere it
  shouldn't, or exposing window contents or titles beyond the local user.
- Anything in the config parser that turns a config file into code execution
  beyond the `spawn` action it is asked to run.

Things that are working as designed:

- `spawn` runs commands. That is its purpose, and the config file is the
  user's own.
- nigiri reads the titles and frames of every window it manages, and logs
  titles to `/tmp/nigiri.log`. That log is what makes layout bugs diagnosable.
- The overview captures window contents while it is open. Frames are held only
  as long as they are being shown and are dropped with the window.

## What nigiri deliberately does not do

- No private frameworks, no SkyLight/CGS symbols, no SIP changes.
- No synthetic keystrokes injected into other applications — every action is
  a direct Accessibility write or an event this process owns.
- No network access at all, and no telemetry.
- No third-party dependencies, so there is no supply chain beyond Apple's SDK.

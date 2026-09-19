# Vendored from PabloZaiden/mac-vnc-server

- Upstream: https://github.com/PabloZaiden/mac-vnc-server
- Vendored at upstream commit `679ec56` ("fix: avoid launchd throttling for streaming service")
- License: preserved verbatim in [LICENSE](LICENSE) (upstream project)

## Local changes on top of upstream

**Session-scoped input injection** — all six event-injection sites in
`Sources/mac-vnc-server/MacInputController.swift` post to `.cgSessionEventTap`
instead of `.cghidEventTap`.

Why: upstream posts to the system-wide HID stream, which routes injected
mouse/keyboard events to whichever session owns the console. When this server
runs as a LaunchAgent inside a fast-user-switching background session (which is
how this plugin uses it), VNC-client input escaped to the *console user's*
screen — moving their pointer and clicking in their session. `.cgSessionEventTap`
delivers events to the posting process's own login session, keeping input inside
the agent account.

Caveats (why this matters operationally):

- `.cgSessionEventTap` posts to *whatever session the process belongs to*. The
  LaunchAgent installed by this plugin bootstraps `gui/<agent-uid>`, which is
  correct. Running the binary via `su` from the console does NOT give it the
  agent's session, and the leak returns.
- If the agent account has no GUI session (logged out, parked at loginwindow),
  session-tap posts are silently dropped — the console stays safe, but input
  does nothing.

## Updating the vendored copy

Sync from upstream, then re-apply the input fix (six `.post(tap:)` sites in
`MacInputController.swift`), and re-verify in a real fast-user-switch deployment
before shipping.

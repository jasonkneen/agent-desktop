# Failure signatures

Every entry here is something that actually happened, with the symptom first,
because the symptom is what you will see before you know the cause.

## The screenshot shows the user's screen, not the agent's

**Cause.** A generic VNC client authenticating as the agent user gets a view of
whatever is on the *console* — the user's own session — not that account's
background session. Apple's Screen Sharing app reaches the account's own session
through a private negotiation that other clients do not get.

**Tell.** The framebuffer is the size of the user's full monitor layout, and the
desktop has their apps on it. Pointer moves you send have no effect.

**Fix.** Do not use Apple's Screen Sharing daemon for this. Run a VNC server
*inside* the agent account (mac-vnc-server), which captures the session it lives
in, and connect to that port instead.

## Apple's Screen Sharing app refuses to connect

**Symptom.** "You cannot control your own screen."

**Cause.** The app blocks connections to the same Mac.

**Fix.** Either use the browser view, or put a small TCP relay on another local
port and connect to that. The block is client-side, so a different port gets
past it.

## noVNC connects, authenticates, then dies immediately

**Symptom.** In the browser console: `Error decoding rect: Too big index in
palette: 25, palette size: 16`, then "Something went wrong, connection is
closed".

**Cause.** mac-vnc-server's default ZRLE encoding produces data noVNC's ZRLE
decoder rejects.

**Fix.** Start the server with `--encoding zlib`. Use `--encoding raw` if zlib
also fails; everything is local so the bandwidth does not matter.

## The viewer asks for a password nobody has

**Cause.** Started without `--password`, mac-vnc-server generates one into
`~/.mac-vnc-server/config.json` **inside the agent account**, which the user
cannot read from their own session.

**Fix.** Always pass `--password "$(cat /Users/Shared/agensis/vnc-pass)"`, with
that file created from the user's account beforehand.

## The viewer connects but the agent's tools time out (or the reverse)

**Cause.** mac-vnc-server serves **one client at a time** — it finishes a session
before accepting the next. A human watching blocks another VNC client, and vice
versa.

**Fix.** The agent should drive through the agensis-cu MCP host, not through VNC.
Then VNC only ever has one client: the human. If two VNC clients are genuinely
needed, the server needs patching to handle sessions concurrently.

## Keystrokes went somewhere unexpected

**Symptom.** You typed and nothing appeared where you aimed. Worse, it appeared
in a window a human was using.

**Cause.** Input goes to the session it belongs to, and lands on whatever has
focus there. If the human is connected to that desktop, that is their focus.

**Fix.** Take a screenshot and look before concluding anything. Do not diagnose
from an absence — "the app I wanted did not launch" does not tell you where the
keystrokes went. And do not send input while anyone is in that session.

## Permissions were granted but read as denied

**Causes, in order of likelihood.**
- The binary was rebuilt. Grants attach to the signature, so a new build is a
  different program to macOS. Re-grant, or re-run `install.sh`, which signs
  both binaries with stable identities (`com.agentdesktop.*`) so grants survive.
- The grant was made in the wrong account. These permissions are per-user.
- The check ran in a process that inherited a different app's grants. A process
  started with `su` from the user's terminal keeps the *user's* session and that
  terminal's permissions — it is not the agent's session and proves nothing.

## Cannot start anything inside the agent's session

**Symptom.** `launchctl bootstrap gui/<uid> ...` fails with
`Bootstrap failed: 5: Input/output error`.

**Cause.** Placing a process in another account's GUI session needs root.

**Fix.** Either run it from a terminal inside that session (via the viewer), or
have the user run it with `sudo`. `su` is not a substitute: it changes the user
id but stays in the caller's login session — this is also why a `--self-test`
run via `su` proves nothing about the agent account's permissions.

`mac-vnc-server run --service` installs a per-user LaunchAgent that runs in the
UI session, which sidesteps this for the VNC server specifically — the
reference setup uses exactly this, bootstrapped for the agent's uid.

## Nothing survives a reboot

**Expected.** The agent account's background session ends at reboot and there is
no scripted way to bring it back. The user logs in through Fast User Switching
again. Automatic login at boot is the only alternative and it makes that account
the console session, which defeats the purpose.

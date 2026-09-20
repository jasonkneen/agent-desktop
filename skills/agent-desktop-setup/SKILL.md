---
name: agent-desktop-setup
description: Set up a dedicated macOS user account that an AI agent can log into and control with computer use, while a human watches and takes over. Covers provisioning the account, installing the agensis-cu computer-use host, granting Screen Recording and Accessibility, wiring it into an Agensis relay or Claude Code, and putting a live view in a browser. Use this whenever someone wants an agent to have "its own desktop", "its own Mac account", a background/sandboxed machine session, computer use that does not fight them for the mouse, or wants to watch and take over an agent driving a Mac — even if they only say "give the agent somewhere to work" or "I don't want it messing with my screen".
---

# Setting up an agent's own macOS desktop

The goal: an agent gets a real macOS desktop of its own on the user's Mac. It can
see and click there. The user can watch it live in a browser and grab control.
Nothing the agent does lands on the user's own screen.

You are guiding a human through this. Several steps **only they can do** — they
need admin rights, or they must click a permission dialog inside the other
account. Your job is to do everything else, and to make their steps short and
unambiguous. `/agent-desktop` runs that walkthrough.

## How the pieces fit

```
agent account (a real macOS login, running in the background)
├── agensis-cu          the hands: MCP server, screen capture + input
└── mac-vnc-server      the eyes: streams that desktop
        │
        └── websockify + noVNC → the user watches in a browser and takes over

the agent itself runs anywhere (the user's Infinitty/Claude Code, or the relay)
and reaches the hands over MCP
```

Two separate channels on purpose: the agent drives through MCP, the human
watches through VNC. Watching never blocks the agent, and the human can always
see what it is doing.

## Where things live

Everything installs under `/Users/Shared/agensis` (override with
`AGENSIS_PREFIX`). `/Users/Shared` is the right home because both accounts can
execute from it while the agent account still cannot read the user's home
directory.

| path | what | source |
|---|---|---|
| `agensis-cu` | computer-use MCP host | `native/agensis-cu` in agensis-agent, `swift build -c release` |
| `mac-vnc-server` | screen stream | vendored at `native/mac-vnc-server` (PabloZaiden/mac-vnc-server + session-input patch), built binary is `.build/release/mac-vnc-server-dev` |
| `noVNC` | browser viewer | github.com/novnc/noVNC |
| `vnc-pass` | shared VNC password | you create it — see step 5 |
| `self-test.txt` | proof permissions were granted | written by the agent account in step 4 |

## What bounds the agent

Only the macOS permissions the user grants **to agensis-cu inside that account**.
If Screen Recording is denied, screenshots fail and the tool says so. Nothing in
this stack second-guesses a granted permission, and nothing works around a
denied one. Say this plainly when the user asks what the agent can do: they
decide, per account, in System Settings.

## The steps

Run `scripts/check-setup.sh` first and after every step. It prints exactly which
of the following is missing, so you never guess. Fix the **first** red row — the
rows are dependency-ordered, so later failures are usually just fallout.

### 1. Create the account — usually the app does this

The Agent Desktop app's "Add an agent" sheet creates the account itself: a
root helper behind the standard administrator prompt generates the account and
a random password (saved to `<prefix>/<account>-pass` for the user to type at
the login screen). **Prefer that path** — it generates a strong password that
never crosses the terminal.

If the user prefers to do it by hand, hand them the command rather than trying
it:

```
sudo sysadminctl -addUser agent -fullName "Agent" -password -
```

`-password -` prompts them, so no password lands in the transcript. A standard
(non-admin) account is the right choice: the agent should not be able to
administer the machine.

### 2. Log the account in — the user must do this

**There is no reliable way to log a macOS account in from a script.** Fast User
Switching is how: the menu bar user menu, pick the agent account, sign in. Then
switch straight back to their own account. The agent's session keeps running in
the background with its apps alive.

Two consequences worth telling them up front:
- After a reboot they must do this again.
- While that session is backgrounded, it still renders, which is what makes
  screen capture work.

### 3. Build and install the hosts

`scripts/install.sh` does all of this — builds both hosts from the vendored
sources, signs them with stable identifiers so permission grants survive
rebuilds, installs into `/Users/Shared/agensis`, generates the VNC password.
Prefer it. By hand it is:

```
# the hands
( cd <plugin-repo>/native/agensis-cu && swift build -c release )
cp .build/release/agensis-cu /Users/Shared/agensis/

# the eyes — vendored in the plugin repo (input fix included)
( cd <plugin-repo>/native/mac-vnc-server && swift build -c release )
cp .build/release/mac-vnc-server-dev /Users/Shared/agensis/mac-vnc-server

# stable identities: without these, a rebuild voids the permission grants
codesign --force --sign - --identifier com.agentdesktop.agensis-cu     /Users/Shared/agensis/agensis-cu
codesign --force --sign - --identifier com.agentdesktop.mac-vnc-server /Users/Shared/agensis/mac-vnc-server
```

Note the rename: the built product is `mac-vnc-server-dev`, but every command
here calls it `mac-vnc-server`.

### 4. Grant the permissions — the user must click, inside that account

macOS has no API to pre-approve Screen Recording, so the first run is
interactive and must happen **in the agent's session**, not the user's. The
easiest route is the view from step 5 if it is already up; otherwise they switch
to the account briefly.

In a terminal *in the agent account*:

```
/Users/Shared/agensis/agensis-cu --self-test | tee /Users/Shared/agensis/self-test.txt
```

It requests both permissions, so the dialogs appear. They allow Screen Recording
and Accessibility, then run it again. It exits 0 and prints both as true when it
is ready.

The `tee` matters: permissions are per-account and readable only from inside
that account, so this file is how `check-setup.sh` verifies the grant from the
user's side. It checks the file was written **by the agent account** and that
the host binary is not newer than it — because grants attach to the binary's
signature, so **a rebuild silently loses them**. If capture fails right after a
rebuild, that is why: re-grant, or sign with a stable identity.

### 5. Put a live view in the browser

First give both accounts a VNC password they can reach — without `--password`
the server generates one into the agent account's `~/.mac-vnc-server/config.json`,
which the user cannot read from their own session:

```
printf 'somepass' > /Users/Shared/agensis/vnc-pass && chmod 644 /Users/Shared/agensis/vnc-pass
```

Then, from a terminal **inside the agent account**:

```
/Users/Shared/agensis/mac-vnc-server run --bind 127.0.0.1 --port 5902 \
    --display 1 --encoding zlib --password "$(cat /Users/Shared/agensis/vnc-pass)"
```

And from the user's own account, `scripts/start-view.sh` bridges it to a browser
and prints the URL. Why each detail matters:

- **Started inside the agent account.** A normal user cannot start a process in
  another account's session; `sudo launchctl bootstrap gui/<uid>` is the only
  other route.
- **`--encoding zlib`.** The default ZRLE encoding crashes noVNC with
  "Too big index in palette". This wasted an hour once; do not skip it.
- **`--display 1`** when the Mac has several monitors, so the agent and the
  viewer see one screen. Otherwise a window can open on a screen nobody is
  watching. Check `--self-test` output: it prints the display count.
- **websockify + noVNC** on localhost, bridging the browser to the VNC port.

Apple's own Screen Sharing app **refuses to connect to the same Mac** ("You
cannot control your own screen"). A TCP relay on a different local port gets
past that if the user prefers the native app, but the browser view is simpler.

`mac-vnc-server run --service` installs a per-user LaunchAgent in the agent's
UI session, so the stream comes back by itself after each login instead of
needing a manual start. This is how the reference setup runs.

### 6. Point the agent at the hands

For plain Claude Code or Codex, an MCP entry is enough:

```json
{ "mcpServers": { "computer": { "command": "/Users/Shared/agensis/agensis-cu" } } }
```

For an **Agensis relay**, lean mode passes jobs only the hub's MCP server, so a
local one is invisible unless it is allowlisted:

```
agensis connect ... --mcp-allow computer=/Users/Shared/agensis/agensis-cu
```

Add `--mcp-allow-tools` only if the user wants the agent to act without being
asked per tool call. Loading the server and letting it act unattended are
deliberately two separate decisions — leave the second off unless they ask.

## Checking it actually works

Do not report success from "the command ran". Verify the chain end to end:

1. `scripts/check-setup.sh` shows every row green.
2. Ask the agent to call `permissions`; it should report both true and list the
   displays.
3. Ask for a `screenshot` and **look at it**. It should be the agent's desktop —
   a clean default wallpaper, not the user's own busy screen.

That last check matters more than it sounds. A VNC login as the agent user can
show you the *console* user's screen instead of the agent's own session, and
everything looks fine until you compare the picture with what the user has open.

## The rule that protects the user

**Never send input into a session a human is using.** Input reaches whichever
session it belongs to, and if the user is connected to the agent's desktop
through the viewer, that includes them — typing there lands in whatever window
they have focused. Before any click or keystroke, know that nobody is in that
session. If something you sent did not appear where you expected, stop and take
a screenshot rather than retrying.

## When something is wrong

`references/troubleshooting.md` has the failure signatures and their causes:
blank or wrong screen, input landing nowhere, viewer disconnects, permissions
that were granted but read as denied, and the multi-client limitation.

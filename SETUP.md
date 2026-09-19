# First-time setup

Start to finish. Steps marked **YOU** cannot be automated — they need admin
rights or a click inside the other account. Everything else is a paste.

**The short version: run step 1, then open `AgentUser.app` and follow it.** It
knows which account it is in, points at the first unfinished step, and ticks
each one green only when it is actually true. Everything below is the same
sequence written out, for when you would rather read than click.

`/agent-desktop:agent-desktop` is the terminal equivalent.

---

## 1. Build and install — paste

```
skills/agent-desktop-setup/scripts/install.sh
```

Needs a Swift toolchain (install Xcode first). Builds both hosts into
`/Users/Shared/agensis`, sets the directory to `1777`, and generates a VNC
password. Safe to re-run.

---

## 2. **YOU** — create the account

Needs admin rights.

```
sudo sysadminctl -addUser agent -fullName "Agent" -password -
```

The trailing `-` makes it **prompt** for the password rather than take it on the
command line, so it never lands in a transcript or your shell history. Type it
when asked.

Pick a standard account, not admin. Write the password down somewhere you'll
find it — you need it at step 3 and there is no way to recover it later.

Check it worked:

```
skills/agent-desktop-setup/scripts/check-setup.sh
```

The `account` row should be green.

---

## 3. **YOU** — log that account in

**This is the one step nothing can do for you.** Not a script, not SSH, not
Screen Sharing, not an agent. It needs the real login window.

1. Click the user icon in the menu bar, top right.
   (No icon? System Settings → Control Centre → "Fast User Switching" → show in
   menu bar.)
2. Choose **Agent**.
3. Enter the password from step 2.
4. Wait for the desktop to finish appearing.
5. Click the user menu again and switch **straight back to yourself**.

The agent's session keeps running in the background with its apps alive. It
still renders while backgrounded, which is exactly what makes screen capture
work.

**After every reboot you must do this again.** There is no way around it.
Automatic login at boot would make the agent the console session, which defeats
the whole point.

Check: the `session` row goes green.

> Why can't this be automated? Creating a GUI session requires the login window,
> which only accepts input from a real person at the machine. SSH and Screen
> Sharing give you a shell or the *console* session — never the agent's own.
> Connecting to port 5900 as the agent shows you **your own screen**, which
> looks like it worked and is not.

---

## 4. **YOU** — grant the two permissions

These are per-account, and macOS has no API to pre-approve them, so this must
happen **inside the agent's session**.

Switch to the agent account (menu bar → Agent), open Terminal there, and run:

```
/Users/Shared/agensis/agensis-cu --self-test | tee /Users/Shared/agensis/self-test.txt
```

Two dialogs appear. Allow **Screen Recording** and **Accessibility**. Then run
the same line again — it should print both as `true`.

Switch back to yourself. The `permissions` row goes green.

> The `tee` is not optional. Permissions are only readable from inside that
> account, so this file is the only way the check can verify the grant from your
> side.

> Rebuilding `agensis-cu` silently voids these grants — macOS ties them to the
> binary's signature, so a new build is a new program. If capture breaks right
> after a rebuild, redo this step.

---

## 5. Start the screen stream — inside the agent account

Still in a Terminal in the agent's session:

```
/Users/Shared/agensis/mac-vnc-server run --bind 127.0.0.1 --port 5902 \
    --display 1 --encoding zlib --password "$(cat /Users/Shared/agensis/vnc-pass)"
```

Leave it running. Switch back to yourself.

- `--encoding zlib` is **required**. The default crashes the browser viewer with
  "Too big index in palette".
- `--display 1` matters if you have more than one monitor, so the agent and the
  viewer are looking at the same screen.

---

## 6. Open the view — paste

```
skills/agent-desktop-setup/scripts/start-view.sh
```

Prints a `http://127.0.0.1:6080/...` URL. Open it, enter the password from
`/Users/Shared/agensis/vnc-pass`. You should see the agent's desktop.

Click into the view to take over. **Pause the agent first** — two cursors
fighting is worse than doing nothing.

---

## 7. Point an agent at it

```json
{ "mcpServers": { "computer": { "command": "/Users/Shared/agensis/agensis-cu" } } }
```

---

## 8. Verify it actually works

Green rows are necessary, not sufficient:

1. `check-setup.sh` — every row green.
2. Ask the agent to call `permissions` — both true, displays listed.
3. Ask for a `screenshot` and **look at it**.

That last one is the real test. It must show the **agent's** desktop — default
wallpaper, empty. If it shows your own screen with your apps on it, something is
pointed at the console session, and everything will look fine until you notice.

---

## If something is wrong

`skills/agent-desktop-setup/references/troubleshooting.md`, symptom first.

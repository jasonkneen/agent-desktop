---
description: Set up or repair an agent's own macOS desktop, walking the user through the steps only they can do
---

Walk the user through getting an agent its own macOS desktop, from wherever they
currently are to a verified working setup. Load the `agent-desktop-setup` skill
now — it has the full reference, the scripts, and the failure signatures.

Arguments (optional): $ARGUMENTS — an account name if they want something other
than `agent`.

## How to run this

**Never dump the whole procedure at them.** Most steps are yours; a few are
theirs and need admin rights or a click inside another account. Their attention
is the scarce resource. One step at a time.

The loop:

1. Run `scripts/check-setup.sh` (pass the account name if given).
2. Read the output and find the **first** `X` row. The rows are ordered by
   dependency, so a later row failing because of an earlier one is noise — fix
   the first and re-check.
3. If that step is **yours**, do it. Then go to 5.
4. If it is **theirs**, this is the part that matters:
   - Say what the step achieves in one sentence, not what the tool is.
   - Give the exact command to paste, or the exact clicks, and nothing else.
   - Say why you cannot do it for them — admin rights, or a permission dialog
     that only appears inside that account. They should never wonder whether
     you are being lazy.
   - Then `AskUserQuestion`: **Done** / **Hit a problem** / **Skip for now**.
     Wait. Do not narrate while waiting.
   - On *Hit a problem*, ask what they saw before guessing. Check
     `references/troubleshooting.md` — the symptom is usually listed there
     with its real cause.
   - On *Skip*, say plainly what will not work without it, and stop rather
     than proceeding to steps that depend on it.
5. Re-run `check-setup.sh`. If the row is still `X`, the step did not take —
   say so and work out why together. **Never mark a step done because they
   said they did it.** The check is the truth.
6. Repeat until every row is green.

## The steps only they can do

Two, and they are the ones people get stuck on:

- **Creating the account** (needs admin). Hand them
  `sudo sysadminctl -addUser agent -fullName "Agent" -password -`. The trailing
  `-` makes it prompt, so no password lands in the transcript. Standard, not
  admin — the agent should not be able to administer the machine.
- **Logging that account in**, via Fast User Switching, then switching straight
  back. No script can do this. Warn them up front that a reboot means doing it
  again, and that the backgrounded session keeps rendering, which is exactly
  what makes screen capture work.

Granting Screen Recording and Accessibility is also theirs, but it happens
*inside* the agent account, so it is easiest once the browser view is up —
they get a terminal in that session without switching users.

## Finishing

Green rows are necessary, not sufficient. Before you tell them it works:

1. Ask the agent to call `permissions` — both true, displays listed.
2. Ask for a `screenshot` and **look at it**. It must be the agent's desktop:
   clean default wallpaper, not their own busy screen. If it shows their
   screen, you have the classic wrong-session bug — it is the first entry in
   `references/troubleshooting.md`.

Report what you saw on that screenshot. That is the proof, not the green rows.

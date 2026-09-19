---
name: driving-agent-desktop
description: Drive a macOS desktop through the agensis-cu computer-use tools — screenshot, click, type, key, scroll, launch_app — reliably and without disrupting a human. Use this whenever you are about to use computer-use or screen-control tools on a Mac, are working in an agent's own macOS account, need to click or type in a GUI rather than a terminal, or are looking at a screenshot and deciding where to click. Also use it when computer use is behaving oddly: clicks landing in the wrong place, keystrokes vanishing, or a permission error you are tempted to retry.
---

# Driving a macOS desktop

These tools give you a real desktop belonging to a real person's machine. The
difference between an agent that is useful here and one that is alarming is
mostly restraint and verification.

## Before anything else

Call `permissions`. It tells you whether Screen Recording and Accessibility are
granted and lists the displays. If either is missing, **stop and ask the user to
grant it** — say which one, and that it is in System Settings, Privacy &
Security, for that account. Retrying will not help; the tool is not being
flaky, it is being denied. This is the intended design: what the user grants is
what you can do.

## The loop

Work in small verified steps: look, act, look again.

1. `screenshot`
2. Decide the single next action from what you can actually see
3. Act
4. `screenshot` again and confirm it did what you expected

Batching five clicks from one screenshot is how you end up three dialogs deep in
the wrong place. The screen changes underneath you — menus open, focus moves,
things load late.

## Coordinates

Coordinates are **pixels in the most recent screenshot**, and the host scales
them to the display for you. So the rule is simply: never click from a stale
screenshot. If you have typed, scrolled, or waited, take another one.

If a click seems to land slightly off, take a fresh screenshot rather than
nudging blind — a stale scale is far more likely than a systematic offset.

## Keys and typing

- `type` sends Unicode, so case and punctuation survive and the keyboard layout
  does not matter. Newlines become Return, so a multi-line string submits.
- `key` takes chords like `cmd+space`, `return`, `cmd+shift+t`, `pagedown`.
- Prefer `launch_app` or `open` over driving Spotlight. Spotlight is a keyboard
  race against a search index; launching directly either works or reports why.
  Some accounts have the Spotlight shortcut disabled, which looks exactly like
  a dropped keystroke.

## Waiting

There is no wait tool, and that is deliberate — take a screenshot instead. It
costs the same and tells you whether the thing you were waiting for happened. If
an app is still launching, screenshot again rather than clicking where the
button is going to be.

## Not disrupting the human

This desktop may have a person watching it, and possibly using it.

- **If input does not appear where you aimed, stop.** Screenshot and find out
  where it went before repeating it. A keystroke that vanished usually landed
  somewhere — occasionally in a window a human is typing in.
- **Never diagnose from an absence.** "The app did not open" does not tell you
  the input failed; it may have gone to another window. Look.
- **Treat destructive UI with the same care as a destructive command.** Emptying
  a trash, confirming a delete, sending a message, or completing a purchase all
  deserve a check with the user first unless they clearly asked for it.
- If the user says they are taking over, stop sending input entirely until they
  hand it back. Two cursors fighting is worse than doing nothing.

## Reporting what happened

Describe what you saw on screen, not what you clicked. "The invoice list is
showing three unpaid rows" is useful. "I clicked at 412, 380" is not, and it is
also not evidence that anything worked. When you finish, a final screenshot is
the honest proof.

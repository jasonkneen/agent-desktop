# Contributing

Thanks for helping make agent-desktop better. This document covers how to set
up, what to work on, and how to get a change merged.

## Project layout

```
.claude-plugin/                 plugin + marketplace manifests
commands/agent-desktop.md       the /agent-desktop walkthrough
skills/agent-desktop-setup/     setup skill: SKILL.md, scripts, troubleshooting
skills/driving-agent-desktop/   how an agent should drive a desktop
native/AgentUser/               SwiftUI app: wizard, viewer, registry
native/agensis-cu/              computer-use MCP host (the hands)
native/mac-vnc-server/          VNC server (the eyes) — vendored, see VENDORED.md
docs/                           screenshots
```

## Setting up

- macOS 14+, Xcode with a Swift 6 toolchain.
- `skills/agent-desktop-setup/scripts/install.sh` builds and installs
  everything into `/Users/Shared/agensis`.
- `swift test --package-path native/AgentUser` and
  `swift test --package-path native/agensis-cu` must pass.

## Before you open a PR

- **Build and test.** Both test suites green, and the app still launches in
  both faces if you touched it (wizard face and viewer face).
- **Keep the security posture.** This project's whole point is a hard boundary
  around the user's own session:
  - Never send input to a session a human may be using.
  - Keep every network bind on `127.0.0.1`. No LAN or external listeners.
  - Never embed, log, or echo credentials (VNC password, account passwords).
  - Never work around a denied macOS permission.
  A PR that weakens any of these will be declined regardless of its other
  merits.
- **Docs travel with code.** If a command, flag, path, or step changes, update
  `README.md`, `SETUP.md`, the relevant `SKILL.md`, and
  `references/troubleshooting.md` in the same PR.
- **Respect the vendored tree.** `native/mac-vnc-server` is vendored from
  [PabloZaiden/mac-vnc-server](https://github.com/PabloZaiden/mac-vnc-server).
  Don't reformat or casually refactor it. Changes go through the local patch
  documented in `VENDORED.md` — keep that file accurate if you add one.

## How to submit

1. Fork, then create a topic branch from `main`:
   `git checkout -b fix/short-description`
2. Make your change in small, focused commits. Write commit messages that say
   *why*, not just *what*.
3. Verify: `swift test` in every package you touched, plus `install.sh`
   end-to-end if the scripts changed.
4. Push and open a PR against `main`. Describe:
   - what problem it solves and how you hit it,
   - what you tested and what you could not test (a lot of this project needs a
     real second account and a real login window — say so honestly),
   - screenshots for anything user-visible.
5. Keep the PR green. Rebase onto `main` if requested.

## Reporting bugs

Open an issue with: macOS version, whether it's the console or the agent
account, the exact command or step, what you expected, what happened. Run
`skills/agent-desktop-setup/scripts/check-setup.sh` and paste its output — the
rows are dependency-ordered and usually point at the real cause. Redact
passwords.

## Style

- Swift: Swift 6 strict concurrency, no force-unwraps outside tests, match the
  surrounding code.
- Shell: `bash`, `set -euo pipefail`, absolute defaults, nothing interactive
  without saying so.
- Prose in this repo is written to be read by a human in a hurry. Short
  sentences, no filler, symptoms before causes.

## Cutting a release

Releases are one command — `scripts/release.sh <version> [--push]` — and it
does the whole sequence: preflight (clean tree, free tag), both test suites,
signed + notarized + stapled app, a DMG (app + Applications symlink), version
bump (`VERSION`, `.claude-plugin/plugin.json`), commit, and an annotated
`v<version>` tag.

Push is **never automatic**. Without `--push` the script stops after tagging:

```
scripts/release.sh 0.2.0        # stops here; verify the DMG first
# open releases/AgentDesktop-0.2.0-arm64.dmg, install, launch
git push origin main v0.2.0
gh release create v0.2.0 releases/AgentDesktop-0.2.0-arm64.dmg --generate-notes
```

Rules:
- One release per tag; the script refuses to reuse one.
- The version is whatever you passed — `VERSION` and the plugin manifest are
  written for you, never edited by hand.
- Signing needs the Developer ID cert and the notarytool keychain profile
  (see `native/AgentUser/release.sh` for the one-time setup). Builds are
  arm64-only (macOS 27 SDK dropped x86_64).

## Licence

By contributing you agree your contributions are licensed under the MIT
License covering this repository.

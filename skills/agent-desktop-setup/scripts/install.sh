#!/bin/bash
# Build and install all hosts and the account-creation helper into the shared prefix. Safe to re-run.
# Does NOT log the agent in, or grant permissions - see the skill. Account
# creation now happens from the app's Add-agent sheet (or the skill's manual command).
set -euo pipefail
PREFIX="${AGENSIS_PREFIX:-/Users/Shared/agensis}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

command -v swift >/dev/null || { echo "Swift toolchain required (install Xcode)." >&2; exit 1; }

# The prefix must be writable by the agent account too: it drops self-test.txt
# there to prove its permissions. 1777 + sticky = agent can add its own files
# but cannot touch or delete yours.
mkdir -p "$PREFIX"
chmod 1777 "$PREFIX"

echo "Building agensis-cu (the hands)..."
( cd "$HERE/native/agensis-cu" && swift build -c release )
install -m 755 "$HERE/native/agensis-cu/.build/release/agensis-cu" "$PREFIX/agensis-cu"

echo "Building mac-vnc-server (the eyes)..."
# Vendored source (see native/mac-vnc-server/VENDORED.md) so the
# session-scoped input fix ships with the plugin. Override MAC_VNC_SRC to
# build your own checkout instead.
SRC="${MAC_VNC_SRC:-$HERE/native/mac-vnc-server}"
if [ ! -f "$SRC/Package.swift" ]; then
  echo "  no Package.swift in $SRC" >&2; exit 1
fi
( cd "$SRC" && swift build -c release )
# the built product is named -dev; everything here calls it mac-vnc-server
install -m 755 "$SRC/.build/release/mac-vnc-server-dev" "$PREFIX/mac-vnc-server"

echo "Building AgentUser.app (the wizard and viewer)..."
# A real bundle, not a bare binary: macOS ties permission grants to a bundle
# identity, and plain executables are often not even offered in the lists.
bash "$HERE/native/AgentUser/bundle.sh" "$PREFIX" >/dev/null

echo "Building agentdesktop-setup (the account-creation helper)..."
# Run as root via the app's administrator prompt; does the OpenDirectory
# account creation the wizard asks for.
install -m 755 "$HERE/native/AgentUser/.build/release/agentdesktop-setup" "$PREFIX/agentdesktop-setup"

echo "Signing..."
# macOS keys TCC grants to the code's designated requirement. An ad-hoc
# signature's requirement is its cdhash — the exact build — so every rebuild
# voided the grants no matter how fixed the identifier (tccd logs it as
# "Failed to match existing code requirement"). A real certificate's
# requirement is identifier + team, which survives rebuilds. Use one if this
# Mac has it; ad-hoc is the fallback, and means re-granting after each build.
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -m1 -E '"(Developer ID Application|Apple Development):' | sed -E 's/.*"(.*)"/\1/')
[ -n "$SIGN_ID" ] || { SIGN_ID="-"; echo "note: no signing certificate — ad-hoc, grants will not survive a rebuild"; }
codesign --force --sign "$SIGN_ID" --identifier com.agentdesktop.agensis-cu     "$PREFIX/agensis-cu"
codesign --force --sign "$SIGN_ID" --identifier com.agentdesktop.mac-vnc-server "$PREFIX/mac-vnc-server"
codesign --force --sign "$SIGN_ID" --identifier com.agentdesktop.setup          "$PREFIX/agentdesktop-setup"

if [ ! -f "$PREFIX/vnc-pass" ]; then
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12 > "$PREFIX/vnc-pass"
  chmod 644 "$PREFIX/vnc-pass"
  echo "Generated a VNC password in $PREFIX/vnc-pass"
fi

echo
echo "Installed into $PREFIX:"
ls -1 "$PREFIX"
echo
echo "Next: open $PREFIX/AgentUser.app — it picks up from wherever you are."
echo "Prefer the terminal? run check-setup.sh or /agent-desktop:agent-desktop."

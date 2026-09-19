#!/bin/bash
# Report which parts of an agent desktop are in place. Read-only: it starts
# nothing, changes nothing, and sends no input. Run it before and after every
# setup step so you never have to guess what is missing.
#
#   check-setup.sh [account] [vnc_port] [web_port]

ACCOUNT="${1:-agent}"
VNC_PORT="${2:-5902}"
WEB_PORT="${3:-6080}"
PREFIX="${AGENSIS_PREFIX:-/Users/Shared/agensis}"
HOST_BIN="${AGENSIS_CU:-$PREFIX/agensis-cu}"
VNC_BIN="${MAC_VNC_SERVER:-$PREFIX/mac-vnc-server}"
SELFTEST="$PREFIX/self-test.txt"
missing=0

row() { # row <ok|no> <label> <detail>
  if [ "$1" = "ok" ]; then printf '  \033[32m/\033[0m %-22s %s\n' "$2" "$3"
  else printf '  \033[31mX\033[0m %-22s %s\n' "$2" "$3"; missing=$((missing+1)); fi
}

echo "Agent desktop status - account '$ACCOUNT'"
echo

if id "$ACCOUNT" >/dev/null 2>&1; then
  row ok "account" "exists (uid $(id -u "$ACCOUNT"))"
else
  row no "account" "no such user - the USER must create it: sudo sysadminctl -addUser $ACCOUNT -fullName Agent -password -"
fi

# A logged-in session shows a loginwindow process owned by that account. Dock
# and Finder mean the desktop is actually up, not just authenticating.
if pgrep -u "$ACCOUNT" -f loginwindow >/dev/null 2>&1; then
  if pgrep -u "$ACCOUNT" -x Dock >/dev/null 2>&1; then
    row ok "session" "logged in, desktop running"
  else
    row no "session" "logging in - Dock not up yet, wait a moment"
  fi
else
  row no "session" "not logged in - the USER must sign in via Fast User Switching (no script can do this)"
fi

if [ -x "$HOST_BIN" ]; then
  row ok "computer-use host" "$HOST_BIN"
else
  row no "computer-use host" "not at $HOST_BIN - build agensis-cu with 'swift build -c release' and copy it there"
fi

if [ -x "$VNC_BIN" ]; then
  row ok "vnc server binary" "$VNC_BIN"
else
  row no "vnc server binary" "not at $VNC_BIN - run install.sh (builds the vendored source in native/mac-vnc-server)"
fi

# Permissions are per-account and can ONLY be read from inside that account.
# Step 4 has the user drop the result in a shared file; we verify that file was
# written BY the agent account and actually says both are granted. Never assume.
if [ -f "$SELFTEST" ]; then
  owner=$(stat -f '%Su' "$SELFTEST" 2>/dev/null)
  if [ "$owner" != "$ACCOUNT" ]; then
    row no "permissions" "$SELFTEST was written by '$owner', not '$ACCOUNT' - it proves nothing; re-run --self-test inside the agent account"
  elif grep -q 'screenRecording=true' "$SELFTEST" && grep -q 'accessibility=true' "$SELFTEST"; then
    age_d=$(( ( $(date +%s) - $(stat -f '%m' "$SELFTEST") ) / 86400 ))
    if [ "$HOST_BIN" -nt "$SELFTEST" ]; then
      row no "permissions" "host binary is NEWER than the self-test - a rebuild drops the grants; re-run --self-test inside the agent account"
    else
      row ok "permissions" "screen recording + accessibility granted to $ACCOUNT (checked ${age_d}d ago)"
    fi
  else
    row no "permissions" "$SELFTEST reports a denied permission: $(tr -d '\n' < "$SELFTEST")"
  fi
else
  row no "permissions" "unproven - in a terminal INSIDE $ACCOUNT run: $HOST_BIN --self-test | tee $SELFTEST"
fi

if pgrep -u "$ACCOUNT" -f mac-vnc-server >/dev/null 2>&1; then
  if pgrep -u "$ACCOUNT" -f -- "--encoding zlib" >/dev/null 2>&1; then
    row ok "screen stream" "mac-vnc-server running with zlib"
  else
    row no "screen stream" "running WITHOUT --encoding zlib - noVNC will disconnect on the first frame"
  fi
else
  row no "screen stream" "mac-vnc-server not running in $ACCOUNT - start it from a terminal in that session"
fi

if nc -z 127.0.0.1 "$VNC_PORT" 2>/dev/null; then
  row ok "vnc port" "$VNC_PORT accepting connections"
else
  row no "vnc port" "$VNC_PORT closed"
fi

if nc -z 127.0.0.1 "$WEB_PORT" 2>/dev/null; then
  row ok "browser view" "http://127.0.0.1:$WEB_PORT/vnc.html"
else
  row no "browser view" "$WEB_PORT closed - run start-view.sh"
fi

echo
if [ "$missing" -eq 0 ]; then
  echo "All checks passed. Now verify for real: ask the agent for a screenshot"
  echo "and confirm it shows the AGENT's desktop, not the user's."
else
  echo "$missing item(s) need attention - see the X rows above."
fi
exit 0

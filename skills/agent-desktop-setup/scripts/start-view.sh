#!/bin/bash
# Serve the agent desktop in a browser: noVNC over websockify, bridged to the
# VNC server running inside the agent account. Binds to localhost only.
#
#   start-view.sh [vnc_port] [web_port]
#
# It does NOT start the VNC server - that must be launched from a terminal
# inside the agent's own session, because one account cannot start a process in
# another account's session.
set -u
VNC_PORT="${1:-5902}"
WEB_PORT="${2:-6080}"
PREFIX="${AGENSIS_PREFIX:-/Users/Shared/agensis}"
NOVNC_DIR="${NOVNC_DIR:-$PREFIX/noVNC}"
VNC_BIN="${MAC_VNC_SERVER:-$PREFIX/mac-vnc-server}"
PASS_FILE="$PREFIX/vnc-pass"

if ! nc -z 127.0.0.1 "$VNC_PORT" 2>/dev/null; then
  cat >&2 <<MSG
Nothing is listening on 127.0.0.1:$VNC_PORT.

Start the screen stream from a terminal INSIDE the agent account:

  $VNC_BIN run --bind 127.0.0.1 --port $VNC_PORT --display 1 \\
      --encoding zlib --password "\$(cat $PASS_FILE)"

--encoding zlib is required: the default encoding crashes the browser viewer.
MSG
  if [ ! -f "$PASS_FILE" ]; then
    cat >&2 <<MSG
--password is required too. Without it the server generates one into the agent
account's ~/.mac-vnc-server/config.json, which you cannot read from here. Put a
password both accounts can reach first:

  printf 'somepass' > $PASS_FILE && chmod 644 $PASS_FILE
MSG
  fi
  exit 1
fi

if [ ! -d "$NOVNC_DIR" ]; then
  echo "Fetching the noVNC web client into $NOVNC_DIR"
  mkdir -p "$(dirname "$NOVNC_DIR")"
  git clone --depth 1 https://github.com/novnc/noVNC "$NOVNC_DIR" >/dev/null 2>&1 || {
    echo "Could not fetch noVNC. Clone it manually to $NOVNC_DIR." >&2; exit 1; }
fi

if nc -z 127.0.0.1 "$WEB_PORT" 2>/dev/null; then
  echo "Something already serves port $WEB_PORT - reusing it."
else
  if command -v websockify >/dev/null 2>&1; then
    websockify --web "$NOVNC_DIR" "127.0.0.1:$WEB_PORT" "127.0.0.1:$VNC_PORT" >/dev/null 2>&1 &
  elif command -v uv >/dev/null 2>&1; then
    uv tool run --from websockify websockify --web "$NOVNC_DIR" \
      "127.0.0.1:$WEB_PORT" "127.0.0.1:$VNC_PORT" >/dev/null 2>&1 &
  else
    echo "Need websockify (pip install websockify, or install uv)." >&2; exit 1
  fi
  for _ in $(seq 1 20); do nc -z 127.0.0.1 "$WEB_PORT" 2>/dev/null && break; sleep 0.25; done
fi

[ -f "$PASS_FILE" ] && hint="The VNC password is in $PASS_FILE." || hint="Enter the VNC password when prompted."

cat <<MSG

Watch the agent's desktop here:

  http://127.0.0.1:$WEB_PORT/vnc.html?host=127.0.0.1&port=$WEB_PORT&autoconnect=1

$hint
Click into the view to take over; the agent keeps working unless you stop it,
so pause it before you start clicking.
MSG

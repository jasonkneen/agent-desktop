#!/bin/bash
# Capture demo media of the agent desktop. Run from the USER's account with the
# noVNC view open, because screencapture records whatever is on YOUR screen -
# it cannot reach into the agent's session. The agent's own `screenshot` tool is
# what gets you an agent's-eye view; this gets you the story of watching it.
#
#   capture-demo.sh still  [out.png]           full display
#   capture-demo.sh region [out.png]           pick a region with the mouse
#   capture-demo.sh video  [secs] [out.mov]    timed recording
#   capture-demo.sh gif    <in.mov> [out.gif]  convert a recording
set -u
MODE="${1:-still}"
DISPLAY_N="${CAPTURE_DISPLAY:-1}"
OUT_DIR="${OUT_DIR:-$PWD}"

case "$MODE" in
  still)
    out="${2:-$OUT_DIR/agent-desktop.png}"
    screencapture -x -D "$DISPLAY_N" "$out" && echo "wrote $out" ;;
  region)
    out="${2:-$OUT_DIR/agent-desktop.png}"
    echo "Drag to select the region (the browser view is the interesting part)..."
    screencapture -i "$out" && echo "wrote $out" ;;
  video)
    secs="${2:-20}"; out="${3:-$OUT_DIR/agent-desktop.mov}"
    echo "Recording display $DISPLAY_N for ${secs}s..."
    screencapture -V "$secs" -D "$DISPLAY_N" "$out" && echo "wrote $out" ;;
  gif)
    src="${2:-}"; out="${3:-${src%.*}.gif}"
    [ -f "$src" ] || { echo "usage: capture-demo.sh gif <in.mov> [out.gif]" >&2; exit 1; }
    pal=$(mktemp -t pal).png
    ffmpeg -y -v error -i "$src" -vf "fps=8,scale=800:-1:flags=lanczos,palettegen" "$pal"
    ffmpeg -y -v error -i "$src" -i "$pal" \
      -lavfi "fps=8,scale=800:-1:flags=lanczos[x];[x][1:v]paletteuse" "$out"
    rm -f "$pal"; echo "wrote $out" ;;
  *)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

cat <<'MSG'

Before this leaves your machine: the VNC password can appear in a terminal
title bar or in scrollback. Check the frame, and rotate it if in doubt:
  printf 'newpass' > /Users/Shared/agensis/vnc-pass
MSG

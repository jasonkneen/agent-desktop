#!/bin/bash
# Build an arm64 AgentUser.app, sign it with the Developer ID cert,
# notarize it with Apple, and staple the ticket. Same pipeline as
# infinitty-free/scripts/ship-signed.sh.
#
# arm64 only: the macOS 27 SDK drops the x86_64 slice as deprecated, so a
# universal build degrades to arm64 anyway. Revisit if Intel ever matters.
#
# Prereqs (one time):
#   - "Developer ID Application" cert in the Keychain
#   - notarytool profile: xcrun notarytool store-credentials infinitty ...
#
# Usage: scripts/release.sh [output-dir]   (default: dist/ next to this script)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$HERE/dist}"
APP="$OUT/AgentUser.app"
VERSION="${AGENTUSER_VERSION:-$(cat "$HERE/../../VERSION" 2>/dev/null || printf '0.1.0')}"

IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
[ -n "$IDENTITY" ] || { echo "ERROR: no 'Developer ID Application' cert in Keychain."; exit 1; }
echo "Signing identity: $IDENTITY"

xcrun notarytool history --keychain-profile infinitty >/dev/null 2>&1 || {
  echo "ERROR: notarytool profile 'infinitty' not set up."
  echo "One time: xcrun notarytool store-credentials infinitty --apple-id <email> --team-id SW75ZJJ5R6 --password <app-specific-password>"
  exit 1
}

echo "Building arm64 release..."
swift build -c release --package-path "$HERE"
BIN="$HERE/.build/release/AgentUser"
[ -x "$BIN" ] || { echo "ERROR: binary not found"; exit 1; }

echo "Staging app..."
AGENTUSER_BIN="$BIN" bash "$HERE/bundle.sh" "$OUT" >/dev/null

echo "Signing (hardened runtime)..."
codesign --force --options runtime --timestamp \
  --identifier com.agentdesktop.agentuser --sign "$IDENTITY" "$APP"
codesign -vvv --strict "$APP"

. "$HERE/../../scripts/notarize.sh"

echo "Notarizing (2-5 min)..."
ZIP="$OUT/AgentDesktop-$VERSION-notarized.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "DONE — $APP is signed, notarized, stapled."
echo "      $ZIP carries the stapled app for distribution."

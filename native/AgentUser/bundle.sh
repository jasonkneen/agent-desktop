#!/bin/bash
# Build AgentUser.app. It must be a real bundle, not a bare binary: macOS
# ties TCC grants to a bundle identity, and a plain executable is often not
# even offered in the Screen Recording list.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-${AGENSIS_PREFIX:-/Users/Shared/agensis}}"
APP="$OUT/AgentUser.app"

swift build -c release --package-path "$HERE"
BIN="${AGENTUSER_BIN:-$HERE/.build/release/AgentUser}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AgentUser"
# The account-creation helper rides inside the bundle so a DMG install works
# without install.sh; AccountCreator finds it next to the main executable.
cp "$HERE/.build/release/agentdesktop-setup" "$APP/Contents/MacOS/agentdesktop-setup"
cp "$HERE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Version comes from the repo-root VERSION file (single source of truth);
# AGENTUSER_VERSION overrides it for the release script.
VERSION="${AGENTUSER_VERSION:-$(cat "$HERE/../../VERSION" 2>/dev/null || printf '0.1.0')}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Agent Desktop</string>
  <key>CFBundleDisplayName</key><string>Agent Desktop</string>
  <key>CFBundleIdentifier</key><string>com.agentdesktop.agentuser</string>
  <key>CFBundleExecutable</key><string>AgentUser</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
</dict></plist>
PLIST

# A stable ad-hoc signature keeps the bundle identity fixed across rebuilds, so
# permissions granted once are not silently voided by the next build.
codesign --force --sign - --identifier com.agentdesktop.agentuser "$APP" 2>/dev/null || \
  echo "note: could not sign; permissions may need re-granting after a rebuild"

echo "Built $APP"

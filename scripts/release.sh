#!/bin/bash
# One-command release: test → build → notarize → DMG → version bump → commit + tag.
#
# Usage: scripts/release.sh <version> [--push]
#
# Push is NEVER automatic. Without --push the script stops after committing and
# tagging; you verify the DMG, then push when you are satisfied:
#   git push origin main v<version>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
PUSH=0
if [ "${2:-}" = "--push" ]; then PUSH=1; elif [ -n "${2:-}" ]; then
  echo "usage: $0 <version> [--push]" >&2; exit 1
fi
[ -n "$VERSION" ] || { echo "usage: $0 <version> [--push]   e.g. $0 0.2.0" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: version must be X.Y.Z, got '$VERSION'" >&2; exit 1; }

echo "==> preflight"
git rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: not a git repo" >&2; exit 1; }
if [ -n "$(git status --porcelain)" ]; then
  git status --short
  echo "ERROR: working tree is not clean — commit or stash first." >&2
  exit 1
fi
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
  echo "ERROR: tag v$VERSION already exists — pick a new version." >&2
  exit 1
fi
for t in swift codesign hdiutil xcrun git; do
  command -v "$t" >/dev/null || { echo "ERROR: required tool '$t' not found" >&2; exit 1; }
done

echo "==> tests"
swift test --package-path native/AgentUser 2>&1 | grep -E "Test run|error" | tail -2
swift test --package-path native/agensis-cu 2>&1 | grep -E "Test run|error" | tail -2

echo "==> build, sign, notarize, staple AgentUser.app"
/bin/bash native/AgentUser/release.sh dist

echo "==> DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R dist/AgentUser.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="dist/AgentDesktop-$VERSION-arm64.dmg"
rm -f "$DMG"
hdiutil create -volname "Agent Desktop $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "  created $DMG — notarizing (2-5 min)…"
source scripts/notarize.sh
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> version bump"
printf '%s\n' "$VERSION" > VERSION
sed -E -i '' 's/"version": "[^"]*"/"version": "'"$VERSION"'"/' .claude-plugin/plugin.json

echo "==> commit + tag"
mkdir -p releases
cp "$DMG" "releases/AgentDesktop-$VERSION-arm64.dmg"
git add VERSION .claude-plugin/plugin.json "releases/AgentDesktop-$VERSION-arm64.dmg"
if [ -n "$(git status --porcelain)" ]; then
  git commit -m "release v$VERSION"
else
  echo "  (nothing to commit — version already $VERSION and DMG unchanged)"
fi
git tag -a "v$VERSION" -m "Agent Desktop v$VERSION"

echo
echo "DONE: v$VERSION committed and tagged."
echo "  DMG: releases/AgentDesktop-$VERSION-arm64.dmg (stapled, verified)"
echo
if [ "$PUSH" = 1 ]; then
  git push origin "$(git branch --show-current)" "v$VERSION"
  echo "PUSHED. Attach the DMG to the GitHub release:"
  echo "  gh release create v$VERSION releases/AgentDesktop-$VERSION-arm64.dmg --title \"v$VERSION\" --generate-notes"
else
  echo "NOT pushed. Verify the DMG opens and the app launches, then:"
  echo "  git push origin \"\$(git branch --show-current)\" v$VERSION"
  echo "  gh release create v$VERSION releases/AgentDesktop-$VERSION-arm64.dmg --title \"v$VERSION\" --generate-notes"
  echo "(or rerun with --push to do the push step)"
fi

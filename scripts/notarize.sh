#!/bin/bash
# Shared notarytool submit/poll loop. Source this file, then call:
#
#   notarize <file>
#
# Requires a notarytool keychain profile. Profile name comes from
# NOTARY_PROFILE (default: infinitty, set up once with
# `xcrun notarytool store-credentials infinitty ...`).
#
# Transient status-check failures are retried (up to 10 in a row) rather than
# killing a submission that is still live at Apple's end.
NOTARY_PROFILE="${NOTARY_PROFILE:-infinitty}"

json_field() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }

notarize() {
  local file="$1" id state json fails=0
  json=$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --output-format json) \
    || { echo "ERROR: notarytool submit failed for $file"; return 1; }
  id=$(printf '%s' "$json" | json_field id)
  [ -n "$id" ] || { echo "ERROR: no submission id in: $json"; return 1; }
  echo "  submission $id — waiting for Apple…"
  local deadline=$((SECONDS + 1800))
  while (( SECONDS < deadline )); do
    sleep 20
    if json=$(xcrun notarytool info "$id" --keychain-profile "$NOTARY_PROFILE" --output-format json 2>/dev/null); then
      fails=0
      state=$(printf '%s' "$json" | json_field status)
      case "$state" in
        Accepted) echo "  accepted ($id)"; return 0 ;;
        "In Progress"|"") ;;
        *)
          echo "ERROR: notarization $state for $file ($id)"
          xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
          return 1 ;;
      esac
    else
      fails=$((fails + 1))
      (( fails >= 10 )) \
        && { echo "ERROR: 10 consecutive status checks failed for $id — check the network, then rerun (submission is still live)"; return 1; }
      echo "  status check failed (transient), retrying…"
    fi
  done
  echo "ERROR: notarization still not final after 30 min ($id)"
  return 1
}

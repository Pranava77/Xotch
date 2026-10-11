#!/usr/bin/env bash
# Sends a Developer ID–signed zip or disk image to Apple's notary service and
# waits for the verdict. Apple scans it for malware and checks the signing;
# a pass is what lets testers open Xotch without Gatekeeper blocking it.
# The packaging scripts call this; you only run it by hand to retry.
#
# Usage: scripts/notarize.sh <file.zip | file.dmg>
#
# Needs your Apple login saved once in the Keychain, under the profile name in
# NOTARY_PROFILE (default "xotch-notary"):
#   xcrun notarytool store-credentials xotch-notary \
#     --apple-id you@example.com --team-id TEAMID
# It asks for an app-specific password (appleid.apple.com › Sign-In and
# Security › App-Specific Passwords), so this script never sees one.
set -euo pipefail

FILE="${1:?usage: scripts/notarize.sh <file.zip | file.dmg>}"
PROFILE="${NOTARY_PROFILE:-xotch-notary}"
[[ -f "$FILE" ]] || { echo "No file at $FILE" >&2; exit 1; }

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  cat >&2 <<EOF
No Apple login saved for notarisation under the profile "$PROFILE".
Save it once (it asks for an app-specific password from appleid.apple.com):

  xcrun notarytool store-credentials $PROFILE --apple-id you@example.com --team-id TEAMID

Your Team ID is on developer.apple.com › Account › Membership details.
EOF
  exit 1
fi

echo "Sending $(basename "$FILE") to Apple's notary service. This usually takes a few minutes…"
RESULT="$(xcrun notarytool submit "$FILE" --keychain-profile "$PROFILE" --wait --output-format plist)"
STATUS="$(/usr/libexec/PlistBuddy -c 'Print :status' /dev/stdin <<<"$RESULT" 2>/dev/null || echo unknown)"
ID="$(/usr/libexec/PlistBuddy -c 'Print :id' /dev/stdin <<<"$RESULT" 2>/dev/null || echo "")"

if [[ "$STATUS" != "Accepted" ]]; then
  echo "Apple didn't accept it (status: $STATUS). What it found:" >&2
  [[ -n "$ID" ]] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2 || true
  exit 1
fi
echo "Notarised (submission $ID)."

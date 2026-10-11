#!/usr/bin/env bash
# Builds a release Xotch.app and zips it for beta testers. Signed with a
# Developer ID, it's also notarised by Apple and stapled, so testers can open
# it without Gatekeeper blocking it; signed ad hoc, testers have to allow it.
# Usage: scripts/package-beta.sh
#   NOTARY_PROFILE  the saved Apple login for notarisation (default xotch-notary)
#   SKIP_NOTARIZE=1 a Developer ID build without notarising, for a quick look
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Xotch.app"

"$ROOT/scripts/build-app.sh" release

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
ZIP="$ROOT/build/Xotch-$VERSION-$BUILD.zip"

codesign --verify --deep --strict "$APP"
echo "Signature verified."
SIGNATURE_INFO=$(codesign -dv "$APP" 2>&1)

rm -f "$ZIP"
if [[ "$SIGNATURE_INFO" == *"Authority=Developer ID Application"* && "${SKIP_NOTARIZE:-}" != "1" ]]; then
  # Apple scans a zip of the app; the ticket is then stapled to the app itself,
  # so it opens even offline, and the stapled app is what's zipped for testers.
  UPLOAD="$ROOT/build/Xotch-notarize.zip"
  rm -f "$UPLOAD"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$UPLOAD"
  "$ROOT/scripts/notarize.sh" "$UPLOAD"
  rm -f "$UPLOAD"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  # What Gatekeeper will say on a tester's Mac.
  spctl --assess --type execute --verbose=2 "$APP"
elif [[ "$SIGNATURE_INFO" == *"Signature=adhoc"* ]]; then
  echo "Note: signed ad hoc, so testers must allow it in System Settings › Privacy & Security (see docs/BETA.md)."
  echo "      With a Developer ID certificate in your keychain, this script also notarises it (see README › Releasing)."
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "Packaged $ZIP ($(du -h "$ZIP" | cut -f1))"
shasum -a 256 "$ZIP"

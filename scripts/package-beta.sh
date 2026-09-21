#!/usr/bin/env bash
# Builds a release Xotch.app and zips it for beta testers.
# Usage: scripts/package-beta.sh
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
if [[ "$SIGNATURE_INFO" == *"Signature=adhoc"* ]]; then
  echo "Note: signed ad hoc. Testers must allow it in System Settings › Privacy & Security (see docs/BETA.md)."
  echo "      Set SIGN_IDENTITY to a Developer ID and notarize before a wider beta."
fi

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "Packaged $ZIP ($(du -h "$ZIP" | cut -f1))"
shasum -a 256 "$ZIP"

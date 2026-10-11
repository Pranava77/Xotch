#!/usr/bin/env bash
# Builds a release Xotch.app and wraps it in a drag-to-Applications disk image.
# Usage: scripts/package-dmg.sh [--skip-build]
#
# Uses create-dmg when it's installed (nicer window, positioned icons) and
# falls back to hdiutil, which ships with macOS, so this works on any Mac.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Xotch.app"
PLIST="$ROOT/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
DMG="$ROOT/build/Xotch-$VERSION-$BUILD.dmg"
STAGING="$ROOT/build/dmg"

if [[ "${1:-}" != "--skip-build" ]]; then
  "$ROOT/scripts/build-app.sh" release
fi
[[ -d "$APP" ]] || { echo "No app at $APP. Run scripts/build-app.sh release first."; exit 1; }

# A clean staging folder: the app, and a shortcut to drag it into.
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

if command -v create-dmg >/dev/null 2>&1; then
  create-dmg \
    --volname "Xotch $VERSION" \
    --window-pos 200 160 --window-size 620 400 \
    --icon-size 120 \
    --icon "Xotch.app" 160 190 \
    --app-drop-link 460 190 \
    --hide-extension "Xotch.app" \
    --no-internet-enable \
    "$DMG" "$STAGING" >/dev/null
else
  echo "create-dmg isn't installed (brew install create-dmg) — using hdiutil."
  hdiutil create -volname "Xotch $VERSION" -srcfolder "$STAGING" \
    -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
fi
rm -rf "$STAGING"

# Sign the image the way the app was signed: with its Developer ID, or ad hoc.
AUTHORITY="$(codesign -dv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  IDENTITY="$SIGN_IDENTITY"
elif [[ "$AUTHORITY" == "Developer ID Application"* ]]; then
  IDENTITY="$AUTHORITY"
else
  IDENTITY="-"
fi
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$DMG"
else
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi

# A Developer ID image is notarised and stapled, so it opens without a warning.
if [[ "$IDENTITY" != "-" && "${SKIP_NOTARIZE:-}" != "1" ]]; then
  "$ROOT/scripts/notarize.sh" "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo "Built $DMG ($SIZE)"
echo "SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"

if [[ "$IDENTITY" == "-" ]]; then
  echo
  echo "Signed ad hoc, so macOS will warn whoever opens it. With a Developer ID"
  echo "certificate in your keychain, this script also notarises it (see README › Releasing)."
fi

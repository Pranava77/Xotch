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

# Ad-hoc signing is what an unsigned build gets; a Developer ID replaces it.
IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" "$DMG"

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo "Built $DMG ($SIZE)"
echo "SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"

if [[ "$IDENTITY" == "-" ]]; then
  cat <<'NOTE'

Signed ad hoc, so macOS will warn whoever opens it. Once you have a
Developer ID Application certificate:

  SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/package-dmg.sh
  xcrun notarytool submit build/Xotch-*.dmg --apple-id you@example.com \
        --team-id TEAMID --password APP-SPECIFIC-PASSWORD --wait
  xcrun stapler staple build/Xotch-*.dmg
NOTE
fi

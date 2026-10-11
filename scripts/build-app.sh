#!/usr/bin/env bash
# Builds Xotch.app from the Swift package, and optionally launches it.
# Usage: scripts/build-app.sh [debug|release] [--run]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
RUN="${2:-}"
APP="$ROOT/build/Xotch.app"
# Signed ad hoc ("-"), every build is a new app to macOS, so it asks for each
# permission and for Keychain access again. A certificate keeps them.
# SIGN_IDENTITY wins; otherwise a Developer ID certificate is used, and debug
# builds also take an Apple Development one (free with an Apple ID in Xcode).
pick_identity() {
  local kinds=("Developer ID Application")
  [[ "$CONFIG" == "debug" ]] && kinds+=("Apple Development")
  local list hash
  list="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  for kind in "${kinds[@]}"; do
    hash="$(grep "\"$kind" <<<"$list" | head -1 | awk '{print $2}')"
    if [[ -n "$hash" ]]; then
      echo "$hash"
      return
    fi
  done
  echo "-"
}
IDENTITY="${SIGN_IDENTITY:-$(pick_identity)}"

# The macOS 27 SDK in Command Line Tools declares SwiftUI's @State as a macro
# whose plugin only ships with Xcode. Without Xcode, build against macOS 26.
if [[ -z "${SDKROOT:-}" && "$(xcode-select -p)" == *CommandLineTools* ]]; then
  for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk; do
    if [[ -d "$candidate" ]]; then
      export SDKROOT="$candidate"
      break
    fi
  done
fi

cd "$ROOT"
# Release builds run on Apple silicon and Intel; debug builds only need this Mac.
ARCHS=()
if [[ "$CONFIG" == "release" ]]; then
  ARCHS=(--arch arm64 --arch x86_64)
fi
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} 2>&1 | { grep -v "ld: warning: search path" || true; }
BIN="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/Xotch"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Xotch"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Now Playing helper: a small library that Apple's perl loads (see MediaRemoteBridge.m).
clang -dynamiclib -fobjc-arc -Os -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
  -framework Foundation -Wall -Werror \
  -o "$APP/Contents/Frameworks/MediaRemoteBridge.dylib" \
  "$ROOT/MediaRemoteBridge/MediaRemoteBridge.m"
cp "$ROOT/MediaRemoteBridge/mediaremote-bridge.pl" "$APP/Contents/Resources/"
rm -rf "$APP/Contents/Resources/Mascots"
cp -R "$ROOT/Resources/Mascots" "$APP/Contents/Resources/Mascots"

codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Frameworks/MediaRemoteBridge.dylib"

# Dictation's engine, Whistle on Cactus's needle, runs in its own process (see
# NeedleHelper/needle-helper.c). The engine is built for macOS 26 on Apple
# silicon; Xotch only starts the helper there.
rm -rf "$APP/Contents/Helpers"
if [[ "$(uname -m)" == "arm64" ]]; then
  mkdir -p "$APP/Contents/Helpers"
  clang -O2 -arch arm64 -mmacosx-version-min=26.0 "$ROOT/NeedleHelper/needle-helper.c" \
    "$ROOT/Vendor/Needle/libneedle.a" -lc++ -o "$APP/Contents/Helpers/needle-helper"
  codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Helpers/needle-helper"
fi
ENTITLEMENTS="$ROOT/Resources/Xotch.entitlements"
if [[ "$CONFIG" == "debug" ]]; then
  # Lets leaks, sample and vmmap inspect debug builds. Never in release builds.
  ENTITLEMENTS="$ROOT/Resources/Xotch.debug.entitlements"
fi
codesign --force --options runtime --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$APP"

echo "Built $APP"
if [[ "$IDENTITY" == "-" ]]; then
  echo "Signed ad hoc: macOS will ask for permissions again. See docs/DEVELOPMENT.md › Permissions during development."
else
  echo "Signed with $(codesign -dv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
fi

if [[ "$RUN" == "--run" ]]; then
  pkill -x Xotch 2>/dev/null || true
  sleep 0.5
  open "$APP"
fi

#!/usr/bin/env bash
# Builds Brim.app from the Swift package, and optionally launches it.
# Usage: scripts/build-app.sh [debug|release] [--run]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
RUN="${2:-}"
APP="$ROOT/build/Brim.app"
# "-" signs ad hoc. Set SIGN_IDENTITY to your Developer ID once you have one.
IDENTITY="${SIGN_IDENTITY:--}"

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
swift build -c "$CONFIG" 2>&1 | { grep -v "ld: warning: search path" || true; }
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Brim"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Brim"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Now Playing helper: a small library that Apple's perl loads (see MediaRemoteBridge.m).
clang -dynamiclib -fobjc-arc -Os -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
  -framework Foundation -Wall -Werror \
  -o "$APP/Contents/Frameworks/MediaRemoteBridge.dylib" \
  "$ROOT/MediaRemoteBridge/MediaRemoteBridge.m"
cp "$ROOT/MediaRemoteBridge/mediaremote-bridge.pl" "$APP/Contents/Resources/"

codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Frameworks/MediaRemoteBridge.dylib"
codesign --force --options runtime --sign "$IDENTITY" \
  --entitlements "$ROOT/Resources/Brim.entitlements" "$APP"

echo "Built $APP"

if [[ "$RUN" == "--run" ]]; then
  pkill -x Brim 2>/dev/null || true
  sleep 0.5
  open "$APP"
fi

#!/usr/bin/env bash
# Builds Brim.app from the Swift package, and optionally launches it.
# Usage: scripts/build-app.sh [debug|release] [--run]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
RUN="${2:-}"
APP="$ROOT/build/Brim.app"

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
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Brim"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Brim"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc signature so macOS runs it locally. Replace "-" with your
# Developer ID identity once you've joined the Apple Developer Program.
codesign --force --options runtime --sign - "$APP"

echo "Built $APP"

if [[ "$RUN" == "--run" ]]; then
  pkill -x Brim 2>/dev/null || true
  open "$APP"
fi

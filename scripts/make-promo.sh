#!/usr/bin/env bash
# Makes the promotional film: build/promo/Xotch-promo.mp4 (46 s, 1080p60, silent).
# Needs a debug build running (scripts/build-app.sh debug --run): it renders
# the shots from sample data, then scripts/promo/Promo.swift draws the film.
# Usage: scripts/make-promo.sh [--stills <seconds…>]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/promo"
SHOTS="$OUT/shots"

if ! pgrep -x Xotch >/dev/null; then
  echo "Start a debug build first: scripts/build-app.sh debug --run" >&2
  exit 1
fi

rm -rf "$SHOTS"
mkdir -p "$OUT"
"$ROOT/scripts/debug.sh" promo "$SHOTS" >/dev/null
# The icon is the last thing written.
for _ in $(seq 1 100); do
  [[ -f "$SHOTS/icon.png" ]] && break
  sleep 1
done
[[ -f "$SHOTS/icon.png" ]] || { echo "The shots didn't arrive; is it a debug build?" >&2; exit 1; }

swiftc -O "$ROOT/scripts/promo/Promo.swift" -o "$OUT/Promo" 2>/dev/null
if [[ "${1:-}" == "--stills" ]]; then
  shift
  "$OUT/Promo" "$SHOTS" --stills "$OUT/stills" "$@"
else
  "$OUT/Promo" "$SHOTS" "$OUT/Xotch-promo.mp4"
fi

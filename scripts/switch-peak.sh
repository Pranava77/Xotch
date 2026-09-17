#!/usr/bin/env bash
# Relaunches a debug Brim, switches modules while the notch is open and prints the
# memory peak. Transitions can allocate large off-screen graphics buffers.
set -euo pipefail
cd "$(dirname "$0")/.."
pkill -x Brim 2>/dev/null || true
sleep 1
open build/Brim.app
sleep 7
PID="$(pgrep -x Brim)"
for module in home media home calendar media notes media home stats media home clipboard; do
  ./scripts/debug.sh open "$module" >/dev/null
  sleep 1
done
./scripts/debug.sh close >/dev/null
footprint -p "$PID" 2>/dev/null | awk '/phys_footprint:/ {now=$2" "$3} /phys_footprint_peak:/ {peak=$2" "$3} END {print "after switching: " now ", peak " peak}'

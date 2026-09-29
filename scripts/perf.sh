#!/usr/bin/env bash
# Measures Xotch's CPU, energy impact, idle wakeups and memory in common states,
# printing a Markdown table. Needs a running debug build; opens the notch while it runs.
# Usage: scripts/perf.sh [seconds per state]
set -euo pipefail
cd "$(dirname "$0")/.."
DURATION="${1:-10}"
PID="$(pgrep -x Xotch)" || { echo "Xotch isn't running. Start it with: scripts/build-app.sh debug --run"; exit 1; }

debug() { ./scripts/debug.sh "$@" >/dev/null; }

measure() {
  local samples=$(( DURATION / 2 + 1 ))
  local stats memory cpu power wakes
  # The first top sample covers the time before we started, so skip it.
  stats=$(top -l "$samples" -s 2 -pid "$PID" -stats pid,cpu,power,idlew 2>/dev/null | awk -v pid="$PID" '
    $1 == pid { n++; if (n == 1) next; cpu += $2; power += $3; gsub(/[^0-9]/, "", $4); wakes += $4 }
    END { if (n > 1) printf "%.2f|%.2f|%.1f", cpu / (n - 1), power / (n - 1), wakes / ((n - 1) * 2) }')
  memory=$(footprint -p "$PID" 2>/dev/null | awk '/phys_footprint:/ { print $2 " " $3; exit }')
  IFS='|' read -r cpu power wakes <<< "$stats"
  printf "| %s | %s%% | %s | %s/s | %s |\n" "$1" "$cpu" "$power" "$wakes" "$memory"
}

echo "| State | CPU | Energy impact | Idle wakeups | Memory |"
echo "|---|---|---|---|---|"
debug close
debug clear-activities
sleep 3
measure "Closed, nothing live"
for module in home media calendar clipboard shelf capture notes stats claude timers; do
  debug open "$module"
  sleep 3
  measure "Open on $module"
done
debug close
debug hud on
sleep 4
debug clear-activities
sleep 3
measure "Closed, system HUD on (nothing else live)"
debug hud off
debug close
sleep 2
debug activity-media
sleep 2
measure "Closed, music playing (equalizer)"
debug clear-activities
debug activity-timer
sleep 2
measure "Closed, timer counting down (ring)"
debug clear-activities
debug activity-claude
sleep 2
measure "Closed, Claude working (pulse)"
debug clear-activities
debug activity-download
sleep 2
measure "Closed, download progress"
debug clear-activities
debug activity-recording
sleep 2
measure "Closed, recording indicator (red timer)"
debug clear-activities
debug palette
sleep 3
measure "Open, command palette"
debug close

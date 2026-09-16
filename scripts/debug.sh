#!/usr/bin/env bash
# Sends a command to a running debug build of Brim.
# Usage: scripts/debug.sh open [module] | close | activity | activity-media | activity-timer |
#        activity-claude | activity-download | clear-activities [module] | celebrate | palette | ripple |
#        theme <id> | mood <mood> | rebuild <count> | status <file> | snapshot <folder> |
#        effects <folder> | selftest <report file>
set -euo pipefail

COMMAND="${1:?usage: scripts/debug.sh open [module]|close|activity|activity-media|activity-timer|activity-claude|activity-download|clear-activities|celebrate|palette|ripple|theme <id>|mood <mood>|rebuild <n>|status <file>|snapshot <folder>|effects <folder>|selftest <file>}"
if [[ "$COMMAND" == "open" && -n "${2:-}" ]]; then
  COMMAND="open:$2"
elif [[ "$COMMAND" == "rebuild" ]]; then
  COMMAND="rebuild:${2:-1}"
elif [[ "$COMMAND" == "status" ]]; then
  REPORT="${2:?status needs a file path}"
  mkdir -p "$(dirname "$REPORT")"
  COMMAND="status:$(cd "$(dirname "$REPORT")" && pwd)/$(basename "$REPORT")"
elif [[ "$COMMAND" == "snapshot" || "$COMMAND" == "effects" ]]; then
  FOLDER="$(cd "${2:?$COMMAND needs a folder}" 2>/dev/null && pwd || (mkdir -p "$2" && cd "$2" && pwd))"
  COMMAND="$COMMAND:$FOLDER"
elif [[ "$COMMAND" == "selftest" ]]; then
  REPORT="${2:?selftest needs a report file path}"
  mkdir -p "$(dirname "$REPORT")"
  COMMAND="selftest:$(cd "$(dirname "$REPORT")" && pwd)/$(basename "$REPORT")"
elif [[ -n "${2:-}" ]]; then
  COMMAND="$COMMAND:$2"
fi

swift - "$COMMAND" <<'EOF' 2>&1 | grep -v "ld: warning" || true
import Foundation
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.pranava.brim.debug"),
    object: CommandLine.arguments[1],
    userInfo: nil,
    deliverImmediately: true
)
EOF

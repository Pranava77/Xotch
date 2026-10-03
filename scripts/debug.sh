#!/usr/bin/env bash
# Sends a command to a running debug build of Xotch.
# Usage: scripts/debug.sh settings <file> | settings-pane <id> | settings-scroll <y> | settings-close | key volup|voldown|mute|brightup|brightdown | sound <cue> | open [module] | close | activity | activity-media | activity-timer |
#        activity-claude | activity-download | clear-activities [module] | celebrate | palette | ripple |
#        theme <id> | rebuild <count> | status <file> | snapshot <folder> |
#        effects <folder> | marketing <folder> | selftest <report file> |
#        click <x,y | control name> | type <text> | probe <file>
#
# click, type and probe drive the notch's own UI: the events are synthesised
# inside the app, so no Accessibility permission is involved. A control name
# comes from `.debugFrame(_:)` — "todos.add" and so on.
set -euo pipefail

COMMAND="${1:?usage: scripts/debug.sh open [module]|close|activity|activity-media|activity-timer|activity-claude|activity-download|clear-activities|celebrate|palette|ripple|theme <id>|rebuild <n>|status <file>|snapshot <folder>|effects <folder>|marketing <folder>|selftest <file>|click <x,y|name>|type <text>|probe <file>}"
if [[ "$COMMAND" == "open" && -n "${2:-}" ]]; then
  COMMAND="open:$2"
elif [[ "$COMMAND" == "rebuild" ]]; then
  COMMAND="rebuild:${2:-1}"
elif [[ "$COMMAND" == "settings" ]]; then
  REPORT="${2:?settings needs a file path for the window number}"
  mkdir -p "$(dirname "$REPORT")"
  COMMAND="settings:$(cd "$(dirname "$REPORT")" && pwd)/$(basename "$REPORT")"
elif [[ "$COMMAND" == "probe" ]]; then
  REPORT="${2:?probe needs a file path}"
  mkdir -p "$(dirname "$REPORT")"
  COMMAND="probe:$(cd "$(dirname "$REPORT")" && pwd)/$(basename "$REPORT")"
elif [[ "$COMMAND" == "status" ]]; then
  REPORT="${2:?status needs a file path}"
  mkdir -p "$(dirname "$REPORT")"
  COMMAND="status:$(cd "$(dirname "$REPORT")" && pwd)/$(basename "$REPORT")"
elif [[ "$COMMAND" == "snapshot" || "$COMMAND" == "effects" || "$COMMAND" == "marketing" ]]; then
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
    Notification.Name("com.pranava.xotch.debug"),
    object: CommandLine.arguments[1],
    userInfo: nil,
    deliverImmediately: true
)
EOF

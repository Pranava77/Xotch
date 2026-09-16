#!/usr/bin/env bash
# Sends a command to a running debug build of Brim.
# Usage: scripts/debug.sh open | close | activity | snapshot <folder>
set -euo pipefail

COMMAND="${1:?usage: scripts/debug.sh open|close|activity|snapshot <folder>}"
if [[ "$COMMAND" == "snapshot" ]]; then
  FOLDER="$(cd "${2:?snapshot needs a folder}" 2>/dev/null && pwd || (mkdir -p "$2" && cd "$2" && pwd))"
  COMMAND="snapshot:$FOLDER"
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

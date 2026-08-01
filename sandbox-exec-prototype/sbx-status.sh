#!/usr/bin/env bash
# sbx-status.sh — show launchd + process state of the sandbox-exec fleet.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/fleet-common.sh"

print_status
echo
echo "logs: ${LOG_DIR}"
for n in "${AGENTS[@]}"; do
  log="${LOG_DIR}/agent-${n}.log"
  [ -f "$log" ] && printf '  %-24s %s\n' "$(basename "$log")" "$(tail -1 "$log" 2>/dev/null | cut -c1-70)"
done

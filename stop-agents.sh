#!/usr/bin/env bash
# stop-agents.sh — tear down all 5 agents: bootout the launchd jobs (so
# KeepAlive stops restarting) and remove the containers. Idempotent.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

for n in "${AGENTS[@]}"; do
  if is_loaded "$n"; then
    echo "agent-${n}: booting out..."
    launchctl bootout "${GUI_DOMAIN}/$(label_for "$n")" || true
  else
    echo "agent-${n}: not loaded."
  fi
  container rm -f "agent-${n}" &>/dev/null || true
done

echo
print_status

#!/usr/bin/env bash
# remove-agents.sh — Stop and remove all agent-N containers created by run-claude.sh
#
# Usage:
#   ./remove-agents.sh

set -euo pipefail

for i in 1 2 3 4 5; do
  name="agent-${i}"
  if container list --all 2>/dev/null | grep -q "^${name}"; then
    echo "Removing '${name}'..."
    container stop "${name}" &>/dev/null || true
    container rm "${name}" &>/dev/null || true
  fi
done

echo "Done."

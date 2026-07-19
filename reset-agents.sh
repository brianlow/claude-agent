#!/usr/bin/env bash
# reset-agents.sh — force-recycle the whole fleet. Removes every agent
# container; launchd's KeepAlive then relaunches each one fresh (agent-run.sh
# does its own `container rm -f` on the way up). This is the recovery lever for
# a wedged/hung agent — the same action as the crash test.
#
# Trigger it directly (`./reset-agents.sh`, or `ssh mac ./reset-agents.sh`), or
# remotely by editing the vault sentinel note (see reset-watcher.sh).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "[$(date '+%F %T')] Recycling fleet..."
for n in "${AGENTS[@]}"; do
  echo "  agent-${n}: removing (launchd will relaunch)..."
  container rm -f "agent-${n}" &>/dev/null || true
done

echo "Done. launchd KeepAlive is relaunching the agents."

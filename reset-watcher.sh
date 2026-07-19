#!/usr/bin/env bash
# reset-watcher.sh — launchd StartInterval poller (every 15s). Watches the
# vault sentinel note's mtime; when it changes, recycles the fleet. Editing the
# sentinel from Obsidian mobile (→ iCloud → this Mac) is the remote reset.
#
# Trigger-on-mtime-change (not existence) means the note lives in the vault
# permanently and each *edit* is one reset request — no deletion needed, so
# iCloud delete-propagation quirks can't cause misses or loops.
#
# Env overrides (used by the test harness):
#   FLEET_SENTINEL, FLEET_RESET_STATE, FLEET_RESET_CMD
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

sentinel="${FLEET_SENTINEL:-${SENTINEL}}"
state="${FLEET_RESET_STATE:-${RESET_STATE}}"
reset_cmd="${FLEET_RESET_CMD:-${SCRIPT_DIR}/reset-agents.sh}"

mkdir -p "$(dirname "${state}")"

# Current sentinel mtime (epoch seconds), or empty if the note is absent — or
# an iCloud placeholder that hasn't downloaded yet, in which case stat fails.
cur="$(stat -f %m "${sentinel}" 2>/dev/null || true)"
last="$(cat "${state}" 2>/dev/null || true)"

# Only consider the sentinel when it currently EXISTS (cur non-empty). An
# absent / not-yet-synced note is never a trigger and never disturbs the
# baseline, so startup, deletion, and an undownloaded iCloud placeholder are
# all no-ops.
if [ -n "${cur}" ]; then
  # Trigger only on a change between two PRESENT states. The first time the
  # note appears (last empty) we just record its mtime as the baseline — so
  # neither first startup nor the note first materializing fires a reset. Only
  # an edit to an already-present note (cur != last) recycles the fleet.
  if [ -n "${last}" ] && [ "${cur}" != "${last}" ]; then
    echo "[$(date '+%F %T')] sentinel changed (${last} -> ${cur}) — triggering reset."
    "${reset_cmd}" || true
  fi
  printf '%s' "${cur}" > "${state}"
fi

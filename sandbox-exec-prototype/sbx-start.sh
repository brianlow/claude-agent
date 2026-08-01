#!/usr/bin/env bash
# sbx-start.sh — bring up the sandbox-exec fleet under launchd. Idempotent:
# already-loaded agents are left running; only missing ones are bootstrapped.
#
# Touches nothing belonging to the Apple Container fleet — different launchd
# labels, plists, logs and session names. See fleet-common.sh for the table.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/fleet-common.sh"

mkdir -p "${PLIST_DIR}" "${LOG_DIR}" "${GEN_DIR}"

for n in "${AGENTS[@]}"; do
  render_plist "$n" > "$(plist_for "$n")"
  if is_loaded "$n"; then
    echo "$(session_for "$n"): already loaded — leaving running."
  else
    echo "$(session_for "$n"): bootstrapping..."
    # Don't let one failed bootstrap abort the loop (set -e) — keep bringing up
    # the rest and still print the status table at the end.
    launchctl bootstrap "${GUI_DOMAIN}" "$(plist_for "$n")" \
      || echo "$(session_for "$n"): WARNING — bootstrap failed (see ${LOG_DIR})."
  fi
done

echo
echo "Waiting for agents to come up..."
deadline=$((SECONDS + 45))
while ((SECONDS < deadline)); do
  all_up=true
  for n in "${AGENTS[@]}"; do
    [ -n "$(agent_pid "$n")" ] || { all_up=false; break; }
  done
  $all_up && break
  sleep 2
done
$all_up || echo "NOTE: not all agents came up within 45s — see ${LOG_DIR}/agent-N.log"

echo
print_status
echo
echo "Sessions should appear in Claude Desktop's Fleet view."

#!/usr/bin/env bash
# sbx-stop.sh — tear down the sandbox-exec fleet. Idempotent.
#
# Only touches labels under ${LABEL_PREFIX} (com.brianlow.claude-sbx), so the
# Apple Container fleet is unaffected even if it happens to be loaded.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/fleet-common.sh"

for n in "${AGENTS[@]}"; do
  label="$(label_for "$n")"
  if is_loaded "$n"; then
    echo "$(session_for "$n"): booting out..."
    launchctl bootout "${GUI_DOMAIN}/${label}" \
      || echo "$(session_for "$n"): WARNING — bootout failed."
  else
    echo "$(session_for "$n"): not loaded."
  fi

  # bootout signals the job; make sure the process tree is actually gone
  # before reporting done, so a restart can't race a lingering session.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pid="$(agent_pid "$n")" || true
    [ -z "$pid" ] && break
    sleep 1
  done
  pid="$(agent_pid "$n")" || true
  if [ -n "$pid" ]; then
    echo "$(session_for "$n"): still running after bootout — sending TERM to $pid"
    kill "$pid" 2>/dev/null || true
  fi
done

echo
print_status

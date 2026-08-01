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

if is_loaded_label "$(browser_label)"; then
  echo "browser: booting out..."
  launchctl bootout "${GUI_DOMAIN}/$(browser_label)" \
    || echo "browser: WARNING — bootout failed."
  for _ in 1 2 3 4 5; do
    [ -z "$(browser_pid)" ] && break
    sleep 1
  done
  # Chromium is multi-process; bootout kills the job's own process, and the
  # profile's (allow signal (target children)) lets it take its renderers with
  # it. Confirm rather than assume — a leaked renderer holds the CDP port.
  bpid="$(browser_pid)" || true
  [ -n "$bpid" ] && { echo "browser: still running — sending TERM to $bpid"; kill "$bpid" 2>/dev/null || true; }
else
  echo "browser: not loaded."
fi

echo
print_status

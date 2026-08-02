#!/usr/bin/env bash
# sbx-stop.sh — tear down the sandbox-exec fleet. Idempotent.
#
# Only touches labels under ${LABEL_PREFIX} (com.brianlow.claude-sbx), so the
# Apple Container fleet is unaffected even if it happens to be loaded.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/sbx-common.sh"

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
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    browser_container_present || break
    sleep 1
  done
  # `container run --rm` removes the container when it stops, but bootout kills
  # the CLI process rather than the container — confirm rather than assume, or
  # the next start finds the name taken and the port held.
  if browser_container_present; then
    echo "browser: container still present after bootout — removing"
    container rm -f "${BROWSER_CONTAINER}" >/dev/null 2>&1 || true
  fi
else
  echo "browser: not loaded."
fi

echo
print_status

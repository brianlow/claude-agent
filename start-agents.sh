#!/usr/bin/env bash
# start-agents.sh [--build] — bring up all 5 agents under launchd. Idempotent:
# already-loaded agents are left running; only missing ones are bootstrapped.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

BUILD=false
[[ "${1:-}" == "--build" ]] && BUILD=true

# Ensure the container system is running.
container system status &>/dev/null || { echo "Starting container system..."; container system start; }

# Build the image if requested or missing.
if $BUILD || ! container image list 2>/dev/null | grep -q "^claude-code"; then
  echo "Building image ${IMAGE}..."
  container build --tag "${IMAGE}" --file "${SCRIPT_DIR}/Dockerfile" "${SCRIPT_DIR}"
fi

mkdir -p "${PLIST_DIR}" "${LOG_DIR}"

for n in "${AGENTS[@]}"; do
  render_plist "$n" > "$(plist_for "$n")"
  if is_loaded "$n"; then
    echo "agent-${n}: already loaded — leaving running."
  else
    echo "agent-${n}: bootstrapping..."
    # Don't let one failed bootstrap abort the loop (set -e) — keep bringing up
    # the rest and still print the status table at the end.
    launchctl bootstrap "${GUI_DOMAIN}" "$(plist_for "$n")" \
      || echo "agent-${n}: WARNING — bootstrap failed (see logs)."
  fi
done

# Bring up the remote-reset watcher (idempotent, same as the agents).
render_watcher_plist > "$(watcher_plist)"
if is_loaded_label "${WATCHER_LABEL}"; then
  echo "reset-watcher: already loaded."
else
  echo "reset-watcher: bootstrapping..."
  launchctl bootstrap "${GUI_DOMAIN}" "$(watcher_plist)" \
    || echo "reset-watcher: WARNING — bootstrap failed (see logs)."
fi

echo
print_status

#!/usr/bin/env bash
# run-claude.sh — Run Claude Code inside an Apple Container with Obsidian vault access
#
# Requirements:
#   - Apple Silicon Mac running macOS 26+
#   - Apple Container installed (github.com/apple/container/releases)
#
# Usage:
#   ./run-claude.sh             # launch claude
#   ./run-claude.sh --build     # rebuild image then launch
#   ./run-claude.sh --build-only  # rebuild image only, don't launch
#
# Auth: On first run, claude will open a browser to log in via claude.ai.
#       Credentials are stored in ~/.claude (mounted from host) so you only do this once.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="${HOME}/Library/Mobile Documents/iCloud~md~obsidian/Documents/Brian's Vault"
IMAGE="claude-code:latest"

# Pick the lowest-numbered slot (1-3) not currently in use.
# Called per-session so a restart grabs a fresh slot (a crashed --rm
# container has already freed its own slot).
pick_container_name() {
  for i in 1 2 3; do
    if ! container list --all 2>/dev/null | grep -q "^agent-${i}"; then
      echo "agent-${i}"
      return 0
    fi
  done
  return 1
}

# Parse flags
BUILD=false
BUILD_ONLY=false
for arg in "$@"; do
  if [[ "${arg}" == "--build" ]]; then
    BUILD=true
  elif [[ "${arg}" == "--build-only" ]]; then
    BUILD=true
    BUILD_ONLY=true
  fi
done

# Ensure the container system is running
if ! container system status &>/dev/null; then
  echo "Starting Apple Container system..."
  container system start
fi

# Build image if requested or if it doesn't exist yet
if ${BUILD} || ! container image list 2>/dev/null | grep -q "^claude-code"; then
  echo "Building image '${IMAGE}'..."
  container build --tag "${IMAGE}" --file "${SCRIPT_DIR}/Dockerfile" "${SCRIPT_DIR}"
  echo ""
fi

${BUILD_ONLY} && exit 0

# Sync gcalcli auth from macOS path (has spaces) to a space-free path for mounting
mkdir -p "${HOME}/.gcalcli"
cp "${HOME}/Library/Application Support/gcalcli/oauth" "${HOME}/.gcalcli/oauth" 2>/dev/null || true

# Stash .claude.json inside ~/.claude/ so it's reachable via the directory mount
if [ -f "${HOME}/.claude.json" ]; then
  cp "${HOME}/.claude.json" "${HOME}/.claude/.claude.json"
fi

BEAR_DIR="${HOME}/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data"

# Run sessions in a loop: if claude/the container crashes (non-zero exit),
# spin up a fresh session. A clean exit (code 0, e.g. you quit claude) stops.
# Give up after MAX_RESTARTS crashes to avoid an endless crash-loop.
MAX_RESTARTS=7
restarts=0
while true; do
  CONTAINER_NAME="$(pick_container_name)" || {
    echo "Error: all 3 container slots are in use (agent-1, -2, -3)"
    exit 1
  }

  echo "Starting container '${CONTAINER_NAME}'..."
  echo "  Vault:  ${VAULT} → /vault"
  echo "  Config: ~/.claude → /home/user/.claude"
  echo "  Bear:   ${BEAR_DIR} → /bear (ro)"
  echo ""

  status=0
  caffeinate -i container run \
    --name "${CONTAINER_NAME}" \
    --interactive \
    --tty \
    --rm \
    --env COLORTERM=truecolor \
    --env AGENT_SESSION_NAME="${CONTAINER_NAME}" \
    --mount "source=${VAULT},target=/vault" \
    --mount "source=${HOME}/.claude,target=/home/user/.claude" \
    --mount "source=${HOME}/.gcalcli,target=/home/user/.local/share/gcalcli" \
    --mount "source=${BEAR_DIR},target=/bear,readonly" \
    --workdir /vault \
    "${IMAGE}" || status=$?

  if [[ ${status} -eq 0 ]]; then
    break
  fi

  restarts=$((restarts + 1))
  if [[ ${restarts} -ge ${MAX_RESTARTS} ]]; then
    echo ""
    echo "⛔  Session '${CONTAINER_NAME}' exited (code ${status}). Hit restart cap (${MAX_RESTARTS}) — giving up."
    exit "${status}"
  fi

  echo ""
  echo "⚠️  Session '${CONTAINER_NAME}' exited (code ${status}). Restart ${restarts}/${MAX_RESTARTS} in 3s — press Ctrl-C to stop."
  sleep 3
done

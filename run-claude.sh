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

# Pick the lowest-numbered slot (1-3) not currently in use
CONTAINER_NAME=""
for i in 1 2 3; do
  if ! container list --all 2>/dev/null | grep -q "^claude-vault-${i}"; then
    CONTAINER_NAME="claude-vault-${i}"
    break
  fi
done
if [[ -z "${CONTAINER_NAME}" ]]; then
  echo "Error: all 3 container slots are in use (claude-vault-1, -2, -3)"
  exit 1
fi

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

echo "Starting container '${CONTAINER_NAME}'..."
echo "  Vault:  ${VAULT} → /vault"
echo "  Config: ~/.claude → /home/user/.claude"
echo "  Bear:   ${BEAR_DIR} → /bear (ro)"
echo ""

exec caffeinate -i container run \
  --name "${CONTAINER_NAME}" \
  --interactive \
  --tty \
  --rm \
  --env COLORTERM=truecolor \
  --mount "source=${VAULT},target=/vault" \
  --mount "source=${HOME}/.claude,target=/home/user/.claude" \
  --mount "source=${HOME}/.gcalcli,target=/home/user/.local/share/gcalcli" \
  --mount "source=${BEAR_DIR},target=/bear,readonly" \
  --workdir /vault \
  "${IMAGE}"

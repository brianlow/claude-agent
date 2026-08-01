#!/usr/bin/env bash
# hermes-run.sh — start the Hermes agent (hermes-1) detached.
#
# Deliberately NOT part of the Claude fleet: no launchd, no KeepAlive, and the
# name is absent from ${AGENTS}, so reset-agents.sh / stop-agents.sh never
# touch it. s6 inside the image restarts the gateway if it crashes; nothing
# restarts the container itself, so this doesn't survive a reboot — rerun it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"   # for ${VAULT}

NAME="hermes-1"
HERMES_IMAGE="nousresearch/hermes-agent:latest"
HERMES_DATA="${SCRIPT_DIR}/data"   # gitignored; self-contained, not ~/.hermes

[ -f "${HERMES_DATA}/.env" ] || { echo "missing ${HERMES_DATA}/.env" >&2; exit 1; }
if grep -q '^[A-Z_]*=REPLACE_ME$' "${HERMES_DATA}/.env"; then
  echo "${HERMES_DATA}/.env still has REPLACE_ME placeholders — fill them in first." >&2
  exit 1
fi

container system status &>/dev/null || container system start

# Clean slot: drop any stale/stopped/running container with this name.
container rm -f "${NAME}" &>/dev/null || true

# Detached, no --rm: keep the container inspectable after a crash.
# Discord is an outbound WebSocket, so no ports need publishing.
# --workdir /vault is what makes the vault's context files (CLAUDE.md,
# .hermes.md) load into every session.
container run -d \
  --name "${NAME}" \
  --mount "source=${HERMES_DATA},target=/opt/data" \
  --mount "source=${VAULT},target=/vault" \
  --workdir /vault \
  "${HERMES_IMAGE}" gateway run

echo "started ${NAME}; logs: container logs -f ${NAME}"

#!/usr/bin/env bash
# agent-run.sh <N> — run one agent (agent-N) in the foreground. Executed by
# launchd (KeepAlive), so any exit triggers a restart. Clears any stale
# container first so a reboot never wedges the slot.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

N="${1:?usage: agent-run.sh <N>}"
NAME="agent-${N}"

# Container system may still be coming up (e.g. just after login). Ensure it.
container system status &>/dev/null || container system start

# Clean slot: drop any stale/stopped/running container with this name.
container rm -f "${NAME}" &>/dev/null || true

# Host-side prep: sync gcalcli oauth, and build the fleet's own ~/.claude from
# the host's (credentials/settings/plugins in, agent-written state stays put).
mkdir -p "${HOME}/.gcalcli"
cp "${HOME}/Library/Application Support/gcalcli/oauth" "${HOME}/.gcalcli/oauth" 2>/dev/null || true
seed_fleet_claude_home
# Must run AFTER seed_fleet_claude_home (which creates the fleet home) — it
# writes the one file that function deliberately does not copy. It is a no-op
# when the fleet has its own token, below.
seed_fleet_credentials

# The fleet's own long-lived token, if one is installed. Passed by --env rather
# than written to disk: it is the credential of record, and Claude Code prefers
# it over ~/.claude/.credentials.json (which seed_fleet_credentials removes in
# that case, so there is only ever one).
#
# Built as an array so that with no token the flag is absent entirely, rather
# than passed empty — an empty CLAUDE_CODE_OAUTH_TOKEN reads as "configured"
# and suppresses the file fallback, which would take the fleet from
# "authenticated by copy" to "not authenticated at all".
TOKEN_ARGS=()
_fleet_token="$(fleet_oauth_token)"
[ -n "${_fleet_token}" ] && TOKEN_ARGS=(--env "CLAUDE_CODE_OAUTH_TOKEN=${_fleet_token}")

# Foreground (no -d) so launchd tracks the process lifetime. --tty gives the
# claude TUI a pty; no --interactive because no stdin is attached under launchd.
# caffeinate -dims prevents display/idle/system/disk sleep while running.
exec caffeinate -dims container run \
  --name "${NAME}" \
  --tty \
  --rm \
  --env COLORTERM=truecolor \
  --env "AGENT_SESSION_NAME=${NAME}" \
  ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
  --mount "source=${VAULT},target=/vault" \
  --mount "source=${FLEET_CLAUDE_HOME},target=/home/user/.claude" \
  --mount "source=${HOME}/.gcalcli,target=/home/user/.local/share/gcalcli" \
  --mount "source=${BEAR_DIR},target=/bear,readonly" \
  --workdir /vault \
  "${IMAGE}"

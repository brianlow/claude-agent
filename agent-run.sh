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
# writes the one file that function deliberately does not copy.
seed_fleet_credentials

# NO CLAUDE_CODE_OAUTH_TOKEN. A `claude setup-token` credential passed that way
# authenticates as "Claude API", and Remote Control requires a claude.ai
# SUBSCRIPTION identity — so the bridge never starts and the fleet is invisible
# in the desktop app's Fleet view. Measured 2026-09-21, same agent, in order:
#
#   API Usage Billing -> Not logged in                      (the husk)
#   Claude Pro -> /rc connecting -> remote-control is active (keychain seed)
#   Claude API -> no /rc line at all                         (setup-token)
#
# So the fleet has to hold a copy of the subscription grant, and the OAuth
# collision that copy causes is a cost of Remote Control, not a bug to fix with
# a different credential type. See seed_fleet_credentials() in common.sh.

# AGENT_SESSION_NAME pins the remote-control session name to the container name,
# so the Fleet view says which slot an agent is. entrypoint.sh falls back to
# --remote-control-session-name-prefix (agent-<random>) without it.
#
# Reusing the name across launches was suspected of hiding agents from the Fleet
# view and is NOT the cause — tested with random names, which changed nothing.
# The cause was the credential; see the note above.
#
# Foreground (no -d) so launchd tracks the process lifetime. --tty gives the
# claude TUI a pty; no --interactive because no stdin is attached under launchd.
# caffeinate -dims prevents display/idle/system/disk sleep while running.
exec caffeinate -dims container run \
  --name "${NAME}" \
  --tty \
  --rm \
  --env COLORTERM=truecolor \
  --env "AGENT_SESSION_NAME=${NAME}" \
  --mount "source=${VAULT},target=/vault" \
  --mount "source=${FLEET_CLAUDE_HOME},target=/home/user/.claude" \
  --mount "source=${HOME}/.gcalcli,target=/home/user/.local/share/gcalcli" \
  --mount "source=${BEAR_DIR},target=/bear,readonly" \
  --workdir /vault \
  "${IMAGE}"

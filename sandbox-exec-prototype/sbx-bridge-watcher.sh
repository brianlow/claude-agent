#!/usr/bin/env bash
# sbx-bridge-watcher.sh — launchd StartInterval poller (every 60s). Recycles an
# agent whose remote-control bridge has died, which launchd cannot do on its
# own.
#
# WHY THIS EXISTS. KeepAlive restarts a job that EXITS. An agent whose bridge
# dies does not exit — it sits there running, fully alive, unreachable from the
# desktop app. Measured: agent-1 stayed up 25 hours straight through a bridge
# death and launchd never touched it. Same blind spot README.md documents for a
# wedged agent, reached by a different cause.
#
# THE CAUSE IT WAS BUILT FOR. The fleet and the host hold copies of one OAuth
# grant, and refreshing rotates the refresh token, so whichever side refreshes
# second is revoked:
#
#   [code-session] /bridge failed 401: OAuth access token has been revoked.
#   [bridge:repl]  JWT refresh failed: no OAuth token
#   [remote-bridge] Teardown complete
#
# Restarting the agent fixes it, because sbx-agent-run.sh calls
# seed_fleet_credentials on every launch and re-reads the CURRENT token from
# the host keychain. This is the property the Apple Container fleet had by
# accident — its agents were restarted often enough that a revoked credential
# was always repaired within ~30s, so the collision was never visible.
#
# WHAT THIS DOES NOT FIX: the race direction. The fleet can still refresh FIRST
# and revoke the human's own login. Only a separate account for the fleet
# removes that, and no amount of restarting substitutes for it.
#
# Env overrides (used by test/test-sbx-bridge-watcher.sh):
#   SBX_BRIDGE_STATE, SBX_BRIDGE_COOLDOWN, SBX_BRIDGE_KICK_CMD,
#   SBX_BRIDGE_LOGDIR, SBX_BRIDGE_AGENTS, SBX_BRIDGE_SKIP_CRED_CHECK,
#   SBX_BRIDGE_PID_CMD
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/sbx-common.sh"

STATE="${SBX_BRIDGE_STATE:-${HOST_HOME}/.claude-sbx/bridge-watcher-state}"
COOLDOWN="${SBX_BRIDGE_COOLDOWN:-300}"
WATCH_LOGDIR="${SBX_BRIDGE_LOGDIR:-${LOG_DIR}}"
# shellcheck disable=SC2206
WATCH_AGENTS=(${SBX_BRIDGE_AGENTS:-${AGENTS[@]}})

mkdir -p "$(dirname "${STATE}")"
now="$(date +%s)"

# A restart only helps if the host keychain currently holds a USABLE credential
# — that is the thing seed_fleet_credentials will copy in. If the human is
# themselves logged out, recycling the fleet every 60s would be a restart storm
# that fixes nothing and buries the real cause in log noise. Check once, up
# front, and do nothing if there is nothing good to re-seed from.
#
# No token is printed here or anywhere else in this script.
if [ -z "${SBX_BRIDGE_SKIP_CRED_CHECK:-}" ]; then
  if ! security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null \
     | /usr/bin/python3 -c '
import json, sys
try:
    d = json.load(sys.stdin).get("claudeAiOauth", {})
except ValueError:
    sys.exit(1)
sys.exit(0 if d.get("accessToken") and d.get("refreshToken") else 1)
'; then
    echo "[$(date '+%F %T')] host keychain has no usable credential — not recycling (fix the host login first)."
    exit 0
  fi
fi

# Is this agent's bridge dead RIGHT NOW?
#
# "Dead" means: the debug log's most recent bridge-failure line is NEWER than
# the agent process's start time. Comparing against process start is what makes
# this safe to run every 60s — a failure the previous incarnation logged before
# it was restarted is history, not a reason to restart again. The debug log is
# appended across launches, so a plain grep would re-fire forever.
bridge_dead() {
  local pid="$1" logf="$2"
  [ -f "$logf" ] || return 1
  /usr/bin/python3 - "$pid" "$logf" <<'PY'
import re, subprocess, sys
from datetime import datetime, timezone

pid, logf = sys.argv[1], sys.argv[2]

# Process start time. `ps -o lstart=` is the only macOS format that carries the
# year, which matters at a year boundary.
try:
    out = subprocess.run(["ps", "-o", "lstart=", "-p", pid],
                         capture_output=True, text=True, check=True).stdout.strip()
    started = datetime.strptime(out, "%a %d %b %H:%M:%S %Y").astimezone()
except Exception:
    sys.exit(1)          # no such process / unparseable — let launchd handle it

# The three shapes a dead bridge takes in the debug log. All three appear
# together in practice; matching any one is enough.
PAT = re.compile(
    r"notifyBridgeFailed"
    r"|JWT refresh failed"
    r"|OAuth access token has been revoked")
TS = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z)")

last = None
with open(logf, "r", errors="replace") as fh:
    for line in fh:
        if not PAT.search(line):
            continue
        m = TS.match(line)
        if m:
            last = m.group(1)

if last is None:
    sys.exit(1)

failed = datetime.strptime(last, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc)
sys.exit(0 if failed > started else 1)
PY
}

# Per-agent cooldown, so a genuinely broken agent is retried on a slow cadence
# instead of being kicked every poll.
# `|| true` is load-bearing: with `set -o pipefail`, grep on a state file that
# does not exist yet exits 2 and takes the whole watcher down under `set -e` —
# on the very first run, before any kick has ever been recorded.
last_kick_for() {
  grep -E "^$1[[:space:]]" "${STATE}" 2>/dev/null | tail -1 | awk '{print $2}' || true
}

record_kick() {
  local n="$1" t="$2" tmp
  tmp="$(mktemp)"
  grep -vE "^${n}[[:space:]]" "${STATE}" 2>/dev/null > "${tmp}" || true
  printf '%s\t%s\n' "${n}" "${t}" >> "${tmp}"
  mv "${tmp}" "${STATE}"
}

# Overridable so the test can point the process-start comparison at a real,
# running pid of its own rather than needing a live agent.
pid_for() {
  if [ -n "${SBX_BRIDGE_PID_CMD:-}" ]; then "${SBX_BRIDGE_PID_CMD}" "$1"; else agent_pid "$1"; fi
}

for n in "${WATCH_AGENTS[@]}"; do
  pid="$(pid_for "$n" || true)"
  # No process: it exited, so KeepAlive is already relaunching it. Not our job.
  [ -n "${pid}" ] || continue

  bridge_dead "${pid}" "${WATCH_LOGDIR}/agent-${n}-debug.log" || continue

  last="$(last_kick_for "$n")"
  if [ -n "${last}" ] && [ $((now - last)) -lt "${COOLDOWN}" ]; then
    echo "[$(date '+%F %T')] agent-${n}: bridge dead, but kicked $((now - last))s ago (cooldown ${COOLDOWN}s) — waiting."
    continue
  fi

  echo "[$(date '+%F %T')] agent-${n}: bridge dead (pid ${pid}) — recycling to re-seed credentials."
  if [ -n "${SBX_BRIDGE_KICK_CMD:-}" ]; then
    "${SBX_BRIDGE_KICK_CMD}" "$n" || echo "[$(date '+%F %T')] agent-${n}: kick command failed."
  else
    # kickstart -k: kill the running job and start it again. Restarting via
    # launchd (rather than `kill`) is what guarantees sbx-agent-run.sh runs
    # again, and with it seed_fleet_home + seed_fleet_credentials.
    launchctl kickstart -k "${GUI_DOMAIN}/$(label_for "$n")" \
      || echo "[$(date '+%F %T')] agent-${n}: kickstart failed."
  fi
  record_kick "$n" "${now}"
done

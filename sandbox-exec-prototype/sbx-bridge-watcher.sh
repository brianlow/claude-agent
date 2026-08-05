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
#   SBX_BRIDGE_PID_CMD, SBX_BRIDGE_PS_BIN, SBX_BRIDGE_HOST_CRED_CMD,
#   SBX_BRIDGE_FLEET_CRED, SBX_BRIDGE_SEED_CMD, SBX_BRIDGE_SESSIONS_DIR
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

# --- one-way credential sync, host -> fleet ---------------------------------
#
# Has the fleet's credential drifted from the host keychain? Two ways it does:
# the host refreshed (rotating the token and revoking the fleet's copy), or the
# human re-logged in (minting a whole new grant). Either way the fleet is now
# holding a dead token and every agent is unreachable.
#
# ONE WAY ONLY, host -> fleet, and that direction is deliberate. The reverse --
# copying the fleet's file back into the host keychain -- would take a file that
# a sandboxed, prompt-injectable agent can write and install it into the human's
# credential store. An agent cannot forge a valid Anthropic token, but it can
# write arbitrary JSON, and the host would then use it. That is the same shape
# as the settings.json/ccline escape this fleet just closed: agent writes a
# file, host acts on it. So the fleet is a follower, never a source.
#
# Compares SHA-256 of the access token. No token is printed.
fleet_credential_stale() {
  local host_cred fleet_cred
  fleet_cred="${SBX_BRIDGE_FLEET_CRED:-${FLEET_HOME}/.claude/.credentials.json}"
  if [ -n "${SBX_BRIDGE_HOST_CRED_CMD:-}" ]; then
    host_cred="$("${SBX_BRIDGE_HOST_CRED_CMD}" 2>/dev/null || true)"
  else
    host_cred="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null || true)"
  fi
  [ -n "${host_cred}" ] || return 1
  printf '%s' "${host_cred}" | /usr/bin/python3 -c '
import hashlib, json, sys, os

def tok(d):
    o = (d or {}).get("claudeAiOauth", {})
    t = o.get("accessToken") or ""
    return hashlib.sha256(t.encode()).hexdigest() if t else ""

try:
    host = tok(json.load(sys.stdin))
except Exception:
    sys.exit(1)                       # unreadable host credential: not our call
if not host:
    sys.exit(1)                       # host itself has no token; guard handles it

try:
    with open(sys.argv[1]) as fh:
        fleet = tok(json.load(fh))
except Exception:
    fleet = ""                        # missing or corrupt counts as stale

sys.exit(0 if fleet != host else 1)
' "${fleet_cred}"
}

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
import os, re, subprocess, sys
from datetime import datetime, timezone

pid, logf = sys.argv[1], sys.argv[2]

# Process start time. `ps -o lstart=` is the only macOS format that carries the
# year, which matters at a year boundary.
#
# LC_ALL=C is not cosmetic — lstart's field ORDER is locale-dependent, and this
# runs under launchd where there is no LANG at all:
#
#   LANG=en_CA.UTF-8 -> 'Tue  4 Aug 21:21:46 2026'   (day before month)
#   no LANG (C)      -> 'Tue Aug  4 21:21:46 2026'   (month before day)
#
# Pinning the locale makes the format ours to choose rather than the caller's.
# The second format is kept as a fallback so an inherited LANG cannot break it
# either — this must behave identically by hand and under launchd, because the
# by-hand run is how anyone will debug it.
try:
    env = dict(os.environ, LC_ALL="C")
    # SBX_BRIDGE_PS_BIN exists so the test can feed this unparseable output and
    # assert it is reported rather than silently treated as healthy. PATH cannot
    # be used for that: sbx-common.sh exports a fixed PATH that wins.
    ps_bin = os.environ.get("SBX_BRIDGE_PS_BIN", "ps")
    out = subprocess.run([ps_bin, "-o", "lstart=", "-p", pid], env=env,
                         capture_output=True, text=True, check=True).stdout.strip()
except Exception:
    sys.exit(1)          # no such process — it exited, so KeepAlive has it

started = None
for fmt in ("%a %b %d %H:%M:%S %Y", "%a %d %b %H:%M:%S %Y"):
    try:
        started = datetime.strptime(out, fmt).astimezone()
        break
    except ValueError:
        continue

# A parse failure must be LOUD. Treating it as "healthy" is what let this run
# 714 times under launchd, detecting nothing, while a by-hand run worked fine.
# A monitor that cannot read its own input has to say so.
if started is None:
    sys.stderr.write("BUG: cannot parse `ps -o lstart=` output %r — "
                     "bridge detection is disabled until this is fixed\n" % out)
    sys.exit(2)

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

# Record each agent's display name if the human has renamed it.
#
# A rename in the desktop app is the human labelling what an agent is FOR
# ("umami-photos"), and a recycle would otherwise silently revert it to the
# derived default. Claude Code writes the current name into
# ~/.claude/sessions/<pid>.json with a `nameSource`; anything other than
# "derived" means a human chose it, so that is what we replay on restart.
#
# Done on EVERY poll, not just before a kick: a crash or a launchd restart also
# loses the name, and those do not come through this script.
capture_agent_names() {
  local n uuid sessdir
  # Overridable for the test only. Deliberately NOT done by exporting
  # FLEET_HOME: that variable decides which directory the Seatbelt profile
  # grants write access to, so it must stay non-overridable from the
  # environment.
  sessdir="${SBX_BRIDGE_SESSIONS_DIR:-${FLEET_HOME}/.claude/sessions}"
  [ -d "${sessdir}" ] || return 0
  mkdir -p "${SBX_STATE}"
  for n in "${WATCH_AGENTS[@]}"; do
    uuid="$(agent_session_uuid "$n")"
    /usr/bin/python3 - "${sessdir}" "${uuid}" "$(agent_name_file "$n")" <<'PY' || true
import glob, json, os, sys
sessdir, uuid, dest = sys.argv[1], sys.argv[2], sys.argv[3]
for p in glob.glob(os.path.join(sessdir, "*.json")):
    try:
        with open(p) as fh:
            d = json.load(fh)
    except Exception:
        continue
    if d.get("sessionId") != uuid:
        continue
    name, src = d.get("name"), d.get("nameSource")
    # "derived" is Claude Code's own default (from the cwd). Only a human-chosen
    # name is worth preserving; recording a derived one would pin a name that
    # should be allowed to change.
    if name and src and src != "derived":
        cur = ""
        try:
            with open(dest) as fh:
                cur = fh.read()
        except OSError:
            pass
        if cur != name:
            with open(dest, "w") as fh:
                fh.write(name)
            print("recorded display name for this agent: %s" % name)
    break
PY
  done
}
capture_agent_names

# Sync first, so a drifted credential is already repaired on disk by the time
# the agents are recycled below and re-read it.
#
# The recycle is NOT optional. Claude Code reads .credentials.json ONCE at
# startup and caches it -- measured: a session started with a dead credential
# logs `[Bootstrap] Skipped: no usable OAuth` / `bridge not enabled`, then never
# retries. A good credential written to disk 5+ minutes later changed nothing.
# So writing the file heals the NEXT launch, and only the restart makes it now.
STALE=0
if fleet_credential_stale; then
  STALE=1
  echo "[$(date '+%F %T')] fleet credential differs from host keychain — re-seeding (host -> fleet)."
  if [ -n "${SBX_BRIDGE_SEED_CMD:-}" ]; then
    "${SBX_BRIDGE_SEED_CMD}" || echo "[$(date '+%F %T')] WARNING — seed command failed."
  else
    seed_fleet_credentials
  fi
fi

for n in "${WATCH_AGENTS[@]}"; do
  pid="$(pid_for "$n" || true)"
  # No process: it exited, so KeepAlive is already relaunching it. Not our job.
  [ -n "${pid}" ] || continue

  # Two independent triggers. A stale credential is the CAUSE and shows up
  # first; a dead bridge is the SYMPTOM and can lag by minutes, or never appear
  # at all if the agent was relaunched into a bad credential and gave up at
  # startup without ever having a bridge to lose.
  if [ "${STALE}" -eq 1 ]; then
    REASON="credential re-seeded"
  else
    bridge_dead "${pid}" "${WATCH_LOGDIR}/agent-${n}-debug.log" || continue
    REASON="bridge dead"
  fi

  last="$(last_kick_for "$n")"
  if [ -n "${last}" ] && [ $((now - last)) -lt "${COOLDOWN}" ]; then
    echo "[$(date '+%F %T')] agent-${n}: ${REASON}, but kicked $((now - last))s ago (cooldown ${COOLDOWN}s) — waiting."
    continue
  fi

  echo "[$(date '+%F %T')] agent-${n}: ${REASON} (pid ${pid}) — recycling so it re-reads the credential."
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

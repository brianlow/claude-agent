#!/usr/bin/env bash
# Non-destructive test of sbx-bridge-watcher.sh's trigger logic. Uses the env
# overrides so no real agent is ever kicked: SBX_BRIDGE_KICK_CMD points at a
# stub that appends to a marker file.
#
# The agent whose "process" is inspected is this test's own shell — $$ is a
# real, running pid with a real start time, which is exactly what the watcher
# reads. Log timestamps are then written on either side of that start time to
# drive the two cases apart.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 — got '$2' want '$3'"; fail=1; fi; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
state="${tmp}/state"
marker="${tmp}/marker"
logdir="${tmp}/logs"
kickcmd="${tmp}/kick-stub.sh"
mkdir -p "${logdir}"
printf '#!/bin/bash\necho "kicked $1" >> "%s"\n' "${marker}" > "${kickcmd}"
chmod +x "${kickcmd}"

# The watcher resolves the agent pid via agent_pid(), which greps for a
# remote-control command line. Stub it to return this test's own pid — a real,
# running process with a real start time, which is what the comparison reads.
pidcmd="${tmp}/pid-stub.sh"
printf '#!/bin/bash\necho %s\n' "$$" > "${pidcmd}"
chmod +x "${pidcmd}"

run() {
  SBX_BRIDGE_STATE="${state}" \
  SBX_BRIDGE_KICK_CMD="${kickcmd}" \
  SBX_BRIDGE_PID_CMD="${pidcmd}" \
  SBX_BRIDGE_LOGDIR="${logdir}" \
  SBX_BRIDGE_AGENTS="7" \
  SBX_BRIDGE_COOLDOWN="${1:-300}" \
  SBX_BRIDGE_SKIP_CRED_CHECK=1 \
  ./sbx-bridge-watcher.sh >>"${tmp}/out" 2>&1
}

kicks() { grep -c kicked "${marker}" 2>/dev/null || echo 0; }

# Write a bridge-failure line stamped <offset> seconds relative to now, in the
# UTC format the real debug log uses.
log_failure_at() {
  local offset="$1"
  /usr/bin/python3 -c "
import sys, datetime
t = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=int(sys.argv[1]))
print(t.strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z',
      '[DEBUG] [bridge:repl] notifyBridgeFailed detail=\"JWT refresh failed: no OAuth token\"')
" "${offset}" >> "${logdir}/agent-7-debug.log"
}

# --- Case 1: no log at all -> nothing to do -------------------------------
rm -f "${marker}"
run
check "no debug log does not kick" "$(kicks)" "0"

# --- Case 2: failure OLDER than process start -> history, not a trigger ---
# This is the case a plain grep gets wrong: the line stays in the appended log
# forever and would re-fire on every poll.
rm -f "${marker}" "${logdir}/agent-7-debug.log"
log_failure_at -86400
run
check "failure older than process start is ignored" "$(kicks)" "0"

# --- Case 3: failure NEWER than process start -> recycle ------------------
rm -f "${marker}"
log_failure_at 5
run
check "failure newer than process start kicks" "$(kicks)" "1"
check "kicked the right agent" "$(tail -1 "${marker}")" "kicked 7"

# --- Case 4: cooldown suppresses a second kick ----------------------------
run
check "cooldown suppresses repeat kick" "$(kicks)" "1"

# --- Case 5: cooldown of 0 allows the next kick ---------------------------
run 0
check "expired cooldown allows another kick" "$(kicks)" "2"

# --- Case 6: the other two failure spellings also match -------------------
rm -f "${marker}" "${logdir}/agent-7-debug.log" "${state}"
/usr/bin/python3 -c "
import datetime
t = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=5)
print(t.strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z',
      '[DEBUG] [code-session] /bridge failed 401: OAuth access token has been revoked.')
" >> "${logdir}/agent-7-debug.log"
run
check "revoked-token spelling matches" "$(kicks)" "1"

# --- Case 7: a healthy log is never a trigger -----------------------------
rm -f "${marker}" "${logdir}/agent-7-debug.log" "${state}"
/usr/bin/python3 -c "
import datetime
t = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=5)
print(t.strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z', '[DEBUG] SSETransport: Connected')
" >> "${logdir}/agent-7-debug.log"
run
check "healthy log does not kick" "$(kicks)" "0"

# --- Case 8: it must work under launchd's environment, not just a shell -----
#
# THE REGRESSION THIS EXISTS FOR. `ps -o lstart=` puts the day and month in a
# LOCALE-DEPENDENT order, and a launchd job has no LANG:
#
#   LANG=en_CA.UTF-8 -> 'Tue  4 Aug 21:21:46 2026'
#   no LANG (C)      -> 'Tue Aug  4 21:21:46 2026'
#
# The original watcher parsed only the first, swallowed the ValueError as
# "healthy", and ran 714 times under launchd detecting nothing while working
# perfectly by hand. Every other case in this file passes with a shell
# environment inherited, so none of them could see it. `env -i` is the point.
rm -f "${marker}" "${logdir}/agent-7-debug.log" "${state}"
log_failure_at 5
env -i HOME="${HOME}" \
  SBX_BRIDGE_STATE="${state}" \
  SBX_BRIDGE_KICK_CMD="${kickcmd}" \
  SBX_BRIDGE_PID_CMD="${pidcmd}" \
  SBX_BRIDGE_LOGDIR="${logdir}" \
  SBX_BRIDGE_AGENTS="7" \
  SBX_BRIDGE_COOLDOWN="300" \
  SBX_BRIDGE_SKIP_CRED_CHECK=1 \
  /bin/bash ./sbx-bridge-watcher.sh >>"${tmp}/out" 2>&1
check "detects under launchd's bare environment" "$(kicks)" "1"

# --- Case 9: an unparseable process start must be LOUD, not silently healthy -
rm -f "${marker}" "${state}"
badps="${tmp}/badps"
mkdir -p "${badps}"
printf '#!/bin/bash\necho "not a date at all"\n' > "${badps}/ps"
chmod +x "${badps}/ps"
out9="$(SBX_BRIDGE_PS_BIN="${badps}/ps" \
  SBX_BRIDGE_STATE="${state}" SBX_BRIDGE_KICK_CMD="${kickcmd}" \
  SBX_BRIDGE_PID_CMD="${pidcmd}" SBX_BRIDGE_LOGDIR="${logdir}" \
  SBX_BRIDGE_AGENTS="7" SBX_BRIDGE_SKIP_CRED_CHECK=1 \
  ./sbx-bridge-watcher.sh 2>&1 || true)"
check "unparseable ps output does not kick" "$(kicks)" "0"
case "${out9}" in
  *"cannot parse"*) check "unparseable ps output is reported" "yes" "yes" ;;
  *)                check "unparseable ps output is reported" "no"  "yes" ;;
esac

# --- credential sync (host -> fleet) ----------------------------------------
#
# Claude Code reads .credentials.json ONCE at startup and caches it -- measured:
# a session started with a dead credential logs "[Bootstrap] Skipped: no usable
# OAuth" and never retries, and a good credential written 5 minutes later
# changed nothing. So a drifted credential must trigger a RECYCLE, not just a
# file write, and it must do so even when no bridge-failure line exists (an
# agent relaunched into a bad credential never had a bridge to lose).
hostcred="${tmp}/hostcred.sh"
fleetcred="${tmp}/fleet-credentials.json"
seedcmd="${tmp}/seed-stub.sh"
mk_cred() { printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"r","expiresAt":1}}' "$1"; }
printf '#!/bin/bash\ncat "%s"\n' "${tmp}/host-credentials.json" > "${hostcred}"
printf '#!/bin/bash\ncp "%s" "%s"\necho seeded >> "%s"\n' \
  "${tmp}/host-credentials.json" "${fleetcred}" "${tmp}/seeded" > "${seedcmd}"
chmod +x "${hostcred}" "${seedcmd}"

runsync() {
  SBX_BRIDGE_STATE="${state}" \
  SBX_BRIDGE_KICK_CMD="${kickcmd}" \
  SBX_BRIDGE_PID_CMD="${pidcmd}" \
  SBX_BRIDGE_LOGDIR="${logdir}" \
  SBX_BRIDGE_AGENTS="7" \
  SBX_BRIDGE_COOLDOWN="0" \
  SBX_BRIDGE_SKIP_CRED_CHECK=1 \
  SBX_BRIDGE_HOST_CRED_CMD="${hostcred}" \
  SBX_BRIDGE_FLEET_CRED="${fleetcred}" \
  SBX_BRIDGE_SEED_CMD="${seedcmd}" \
  ./sbx-bridge-watcher.sh >>"${tmp}/out" 2>&1
}

# --- Case 10: matching credentials, healthy log -> no sync, no kick ---------
rm -f "${marker}" "${state}" "${tmp}/seeded" "${logdir}/agent-7-debug.log"
mk_cred AAA > "${tmp}/host-credentials.json"
mk_cred AAA > "${fleetcred}"
runsync
check "matching credential does not re-seed" "$( [ -f "${tmp}/seeded" ] && echo yes || echo no )" "no"
check "matching credential does not kick"    "$(kicks)" "0"

# --- Case 11: host rotated -> re-seed AND recycle, with no failure line -----
# This is the case the bridge-failure trigger cannot see on its own.
rm -f "${marker}" "${state}" "${tmp}/seeded"
mk_cred BBB > "${tmp}/host-credentials.json"
runsync
check "drifted credential re-seeds"          "$( [ -f "${tmp}/seeded" ] && echo yes || echo no )" "yes"
check "drifted credential recycles agent"    "$(kicks)" "1"
check "re-seed made fleet match host"        "$(cat "${fleetcred}")" "$(cat "${tmp}/host-credentials.json")"

# --- Case 12: after the sync, the next poll is quiet ------------------------
rm -f "${marker}" "${tmp}/seeded"
runsync
check "converged credential does not re-seed" "$( [ -f "${tmp}/seeded" ] && echo yes || echo no )" "no"
check "converged credential does not kick"    "$(kicks)" "0"

# --- Case 13: a husk fleet credential counts as drift ----------------------
rm -f "${marker}" "${state}" "${tmp}/seeded"
mk_cred "" > "${fleetcred}"
runsync
check "husk fleet credential re-seeds"        "$( [ -f "${tmp}/seeded" ] && echo yes || echo no )" "yes"
check "husk fleet credential recycles"        "$(kicks)" "1"

# --- Case 14: a missing fleet credential counts as drift -------------------
rm -f "${marker}" "${state}" "${tmp}/seeded" "${fleetcred}"
runsync
check "missing fleet credential re-seeds"     "$( [ -f "${tmp}/seeded" ] && echo yes || echo no )" "yes"

echo
if [ "${fail}" -eq 0 ]; then echo "=== all bridge-watcher tests passed"; else echo "=== FAILURES"; fi
exit "${fail}"

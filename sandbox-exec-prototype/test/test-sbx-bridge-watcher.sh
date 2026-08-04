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

echo
if [ "${fail}" -eq 0 ]; then echo "=== all bridge-watcher tests passed"; else echo "=== FAILURES"; fi
exit "${fail}"

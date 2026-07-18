#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source ./common.sh

fail=0
check() { # check <desc> <actual> <expected>
  if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 — got '$2' want '$3'"; fail=1; fi
}

check "label_for"   "$(label_for 3)"   "com.brianlow.claude-agent.3"
check "plist_for"   "$(plist_for 3)"   "${REPO_DIR}/launchd/com.brianlow.claude-agent.3.plist"
check "agents len"  "${#AGENTS[@]}"    "5"

# render_plist must contain the label, the agent arg, and an absolute program path.
plist="$(render_plist 2)"
grep -q "<string>com.brianlow.claude-agent.2</string>" <<<"$plist" && echo "PASS: plist label" || { echo "FAIL: plist label"; fail=1; }
grep -q "<string>${REPO_DIR}/agent-run.sh</string>"    <<<"$plist" && echo "PASS: plist prog"  || { echo "FAIL: plist prog"; fail=1; }

# container_state returns one of the known tokens for agent-1 (live system).
st="$(container_state 1)"
[[ "$st" =~ ^(running|stopped|absent)$ ]] && echo "PASS: container_state token ($st)" || { echo "FAIL: container_state '$st'"; fail=1; }

exit $fail

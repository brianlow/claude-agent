#!/usr/bin/env bash
# Non-destructive test of reset-watcher.sh's trigger logic. Uses the env
# overrides so no real agents/containers are touched: FLEET_RESET_CMD points at
# a stub that just writes a marker file.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 — got '$2' want '$3'"; fail=1; fi; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
sentinel="${tmp}/sentinel.md"
state="${tmp}/state"
marker="${tmp}/marker"
resetcmd="${tmp}/reset-stub.sh"
printf '#!/bin/bash\necho fired >> "%s"\n' "${marker}" > "${resetcmd}"
chmod +x "${resetcmd}"

run() { FLEET_SENTINEL="${sentinel}" FLEET_RESET_STATE="${state}" FLEET_RESET_CMD="${resetcmd}" ./reset-watcher.sh; }

present() { [ -f "$1" ] && echo yes || echo no; }

# --- Path 1: note already exists at first run ---
touch -t 202601010900.00 "${sentinel}"
t1="$(stat -f %m "${sentinel}")"
rm -f "${marker}"
run
check "p1 case1: baselined to sentinel mtime" "$(cat "${state}")" "${t1}"
check "p1 case1: no trigger on first run (exists)" "$(present "${marker}")" "no"

rm -f "${marker}"
run
check "p1 case2: unchanged mtime does not trigger" "$(present "${marker}")" "no"

touch -t 202601011000.00 "${sentinel}"
t2="$(stat -f %m "${sentinel}")"
rm -f "${marker}"
run
check "p1 case3: edit triggers reset" "$(present "${marker}")" "yes"
check "p1 case3: state advanced to new mtime" "$(cat "${state}")" "${t2}"

# --- Path 2: note ABSENT at first run, then appears (the iCloud concern) ---
rm -f "${sentinel}" "${state}" "${marker}"
run
check "p2 case1: absent at startup does not trigger" "$(present "${marker}")" "no"
check "p2 case1: absent leaves no baseline written" "$(present "${state}")" "no"

# Note materializes (iCloud downloads / user creates it) — must NOT trigger.
touch -t 202601020900.00 "${sentinel}"
t3="$(stat -f %m "${sentinel}")"
rm -f "${marker}"
run
check "p2 case2: appearance-from-absent does NOT trigger" "$(present "${marker}")" "no"
check "p2 case2: appearance records baseline" "$(cat "${state}")" "${t3}"

# Now an actual edit triggers.
touch -t 202601021000.00 "${sentinel}"
rm -f "${marker}"
run
check "p2 case3: edit after appearance triggers" "$(present "${marker}")" "yes"

# Deletion while running does not trigger and preserves baseline.
t4="$(cat "${state}")"
rm -f "${sentinel}" "${marker}"
run
check "p2 case4: deletion does not trigger" "$(present "${marker}")" "no"
check "p2 case4: deletion preserves baseline" "$(cat "${state}")" "${t4}"

exit $fail

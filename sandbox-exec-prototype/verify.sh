#!/usr/bin/env bash
# PLAN.md Phase 1 step 5 — verify the actual security property, not just "it
# starts". Runs each probe as a direct child of sandbox-exec under the given
# profile, which is the same enforcement path Claude Code's subprocesses get.
#
#   ./verify.sh <profile.sb>
#
# DATA SAFETY: the two write-probes that are *expected to succeed* (vault,
# gcalcli) use uniquely-named files that are checked for non-existence first
# and removed afterwards. Nothing existing is ever opened for write, appended
# to, or truncated. Every other write-probe is expected to FAIL, and the script
# reports loudly if one unexpectedly succeeds.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROFILE="${1:?usage: verify.sh <profile.sb>}"
[ -f "$PROFILE" ] || PROFILE="$HERE/profiles/$PROFILE"
PROFILE="$(cd "$(dirname "$PROFILE")" && pwd)/$(basename "$PROFILE")"

VAULT="/Users/brianlow/Library/Mobile Documents/iCloud~md~obsidian/Documents/Brian's Vault"
BEAR="/Users/brianlow/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data"

PASS=0; FAIL=0
sb() { sandbox-exec -f "$PROFILE" "$@"; }

# check <description> <expect: allow|deny> <command...>
check() {
  local desc="$1" expect="$2"; shift 2
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  local got="allow"; [ $rc -ne 0 ] && got="deny"
  if [ "$got" = "$expect" ]; then
    printf '  ok    %-46s (%s)\n' "$desc" "$expect"; PASS=$((PASS+1))
  else
    printf '  FAIL  %-46s expected %s, got %s\n' "$desc" "$expect" "$got"
    printf '        %s\n' "$(echo "$out" | head -1)"; FAIL=$((FAIL+1))
  fi
}

echo "=== verifying $(basename "$PROFILE")"

echo "--- [1] filesystem outside the allow-list must be denied"
check "read  ~/.ssh/known_hosts"        deny  sb /bin/cat  "/Users/brianlow/.ssh/known_hosts"
check "list  ~/.ssh"                    deny  sb /bin/ls   "/Users/brianlow/.ssh"
check "write ~/.ssh/authorized_keys2"   deny  sb /usr/bin/touch "/Users/brianlow/.ssh/.sbx-probe-$$"
check "read  ~/Documents"               deny  sb /bin/ls   "/Users/brianlow/Documents"
check "read  ~/Desktop"                 deny  sb /bin/ls   "/Users/brianlow/Desktop"
check "read  another project (~/dev)"   deny  sb /bin/ls   "/Users/brianlow/dev"
check "write /etc"                      deny  sb /usr/bin/touch "/private/etc/.sbx-probe-$$"
check "read  ~/Library/Messages"        deny  sb /bin/ls   "/Users/brianlow/Library/Messages"

echo "--- [2] Bear must be readable but NOT writable"
# Bear lives in a Group Container, which is TCC-protected. TCC is a *separate*
# layer from Seatbelt and sandbox-exec can only ever subtract permissions, never
# add them — so if the launching process lacks the TCC grant, the read fails no
# matter what the profile says. Compare sandboxed vs unsandboxed to attribute
# the failure correctly instead of chasing it in the profile.
if /bin/ls "$BEAR" >/dev/null 2>&1; then
  check "read  Bear Application Data"   allow sb /bin/ls "$BEAR"
else
  echo "  n/a   read  Bear Application Data              (blocked by TCC, not Seatbelt:"
  echo "        the unsandboxed read fails too — the launching process needs Full Disk"
  echo "        Access. Not a profile defect; see NOTES.md.)"
fi
check "write Bear Application Data"     deny  sb /usr/bin/touch "$BEAR/.sbx-probe-$$"
check "write Bear group container"      deny  sb /usr/bin/touch \
      "/Users/brianlow/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/.sbx-probe-$$"

echo "--- [3] the allow-list must actually work"
check "read  vault"                     allow sb /bin/ls "$VAULT"
VPROBE="$VAULT/.sbx-probe-$$-DELETEME"
if [ -e "$VPROBE" ]; then echo "  SKIP  vault write — probe path already exists!";
else
  check "write vault (expected to succeed)" allow sb /usr/bin/touch "$VPROBE"
  if [ -e "$VPROBE" ]; then rm -f "$VPROBE"; echo "        (probe file removed)"; fi
fi
check "read  ~/.gcalcli"                allow sb /bin/ls "/Users/brianlow/.gcalcli"

echo "--- [4] IPC / confused-deputy paths must be denied"
check "osascript → Finder"              deny  sb /usr/bin/osascript -e 'tell application "Finder" to get name of home'
check "osascript → System Events"       deny  sb /usr/bin/osascript -e 'tell application "System Events" to get name of every process'
check "open(1) a GUI app"               deny  sb /usr/bin/open -a Calculator

echo
echo "=== pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]

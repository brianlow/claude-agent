#!/usr/bin/env bash
# sbx-verify.sh — assert the AGENT sandbox's security properties, not just "it
# starts". Runs each probe as a direct child of sandbox-exec under the agent's
# profile, which is the same enforcement path Claude Code's subprocesses get.
#
#   ./sbx-verify.sh              # the live rendered profile (rendered if absent)
#   ./sbx-verify.sh <profile.sb> # a specific profile, e.g. one being edited
#
# The browser has its own assertions — ./sbx-verify-browser.sh.
#
# DATA SAFETY: the two write-probes that are *expected to succeed* (vault,
# gcalcli) use uniquely-named files that are checked for non-existence first
# and removed afterwards. Nothing existing is ever opened for write, appended
# to, or truncated. Every other write-probe is expected to FAIL, and the script
# reports loudly if one unexpectedly succeeds.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/sbx-common.sh"

# Default to the profile the fleet actually runs under. render_profile is the
# same function sbx-agent-run.sh calls on every launch, so verifying a freshly
# rendered file is verifying what an agent would get on its next restart —
# not a stale artifact from whenever the fleet last started.
#
# All agents' profiles are byte-identical (render_profile takes N but the
# template has no per-agent substitution), so AGENTS[0] is representative.
if [ $# -ge 1 ]; then
  PROFILE="$1"
  [ -f "$PROFILE" ] || PROFILE="${HERE}/profiles/$PROFILE"
  [ -f "$PROFILE" ] || { echo "no such profile: $1" >&2; exit 1; }
  PROFILE="$(cd "$(dirname "$PROFILE")" && pwd)/$(basename "$PROFILE")"
else
  mkdir -p "${GEN_DIR}"
  PROFILE="$(profile_for "${AGENTS[0]}")"
  render_profile "${AGENTS[0]}" > "${PROFILE}"
fi

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
check "read  ~/.ssh/known_hosts"        deny  sb /bin/cat  "${HOME}/.ssh/known_hosts"
check "list  ~/.ssh"                    deny  sb /bin/ls   "${HOME}/.ssh"
check "write ~/.ssh/authorized_keys2"   deny  sb /usr/bin/touch "${HOME}/.ssh/.sbx-probe-$$"
check "read  ~/Documents"               deny  sb /bin/ls   "${HOME}/Documents"
check "read  ~/Desktop"                 deny  sb /bin/ls   "${HOME}/Desktop"
check "read  another project (~/dev)"   deny  sb /bin/ls   "${HOME}/dev"
check "write /etc"                      deny  sb /usr/bin/touch "/private/etc/.sbx-probe-$$"
check "read  ~/Library/Messages"        deny  sb /bin/ls   "${HOME}/Library/Messages"

echo "--- [2] Bear must be readable but NOT writable"
# Bear lives in a Group Container, which is TCC-protected. TCC is a *separate*
# layer from Seatbelt and sandbox-exec can only ever subtract permissions, never
# add them — so if the launching process lacks the TCC grant, the read fails no
# matter what the profile says. Compare sandboxed vs unsandboxed to attribute
# the failure correctly instead of chasing it in the profile.
if /bin/ls "$BEAR_DIR" >/dev/null 2>&1; then
  check "read  Bear Application Data"   allow sb /bin/ls "$BEAR_DIR"
else
  echo "  n/a   read  Bear Application Data              (blocked by TCC, not Seatbelt:"
  echo "        the unsandboxed read fails too — whatever launched the fleet needs Full"
  echo "        Disk Access. Not a profile defect; see README.md.)"
fi
check "write Bear Application Data"     deny  sb /usr/bin/touch "$BEAR_DIR/.sbx-probe-$$"
check "write Bear group container"      deny  sb /usr/bin/touch \
      "${HOME}/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/.sbx-probe-$$"

echo "--- [3] the allow-list must actually work"
check "read  vault"                     allow sb /bin/ls "$VAULT"
VPROBE="$VAULT/.sbx-probe-$$-DELETEME"
if [ -e "$VPROBE" ]; then echo "  SKIP  vault write — probe path already exists!";
else
  check "write vault (expected to succeed)" allow sb /usr/bin/touch "$VPROBE"
  if [ -e "$VPROBE" ]; then rm -f "$VPROBE"; echo "        (probe file removed)"; fi
fi
check "read  ~/.gcalcli"                allow sb /bin/ls "${HOME}/.gcalcli"

echo "--- [4] IPC / confused-deputy paths must be denied"
check "osascript → Finder"              deny  sb /usr/bin/osascript -e 'tell application "Finder" to get name of home'
check "osascript → System Events"       deny  sb /usr/bin/osascript -e 'tell application "System Events" to get name of every process'
check "open(1) a GUI app"               deny  sb /usr/bin/open -a Calculator

echo "--- [5] the host's ~/.claude must be unreachable"
# settings.json and ccline/ccline are executed by the HOST's claude, outside
# every sandbox. A writable path to them is an escape that never has to break
# out of anything — it just leaves a note the host picks up and runs.
check "read  host ~/.claude/settings.json"  deny  sb /bin/cat "${HOST_HOME}/.claude/settings.json"
check "write host ~/.claude probe"          deny  sb /usr/bin/touch "${HOST_HOME}/.claude/.sbx-probe-$$"
check "write host ccline statusline binary" deny  sb /bin/test -w "${HOST_HOME}/.claude/ccline/ccline"
check "read  host session transcripts"      deny  sb /bin/ls "${HOST_HOME}/.claude/projects"
check "read  host ~/.claude.json"           deny  sb /bin/cat "${HOST_HOME}/.claude.json"
check "write host ~/.npm"                   deny  sb /usr/bin/touch "${HOST_HOME}/.npm/.sbx-probe-$$"

echo "--- [6] the fleet's own home must work"
check "write fleet ~/.claude"               allow sb /usr/bin/touch "${FLEET_HOME}/.claude/.sbx-probe-$$"
check "read  host claude install (ro)"      allow sb /bin/ls "${HOST_HOME}/.local/share/claude"
check "write host claude install"           deny  sb /usr/bin/touch "${HOST_HOME}/.local/share/claude/.sbx-probe-$$"
rm -f "${FLEET_HOME}/.claude/.sbx-probe-$$"

echo "--- [7] the keychain must be unreachable"
# The fleet authenticates from a seeded ~/.claude/.credentials.json in its own
# home, not from the login keychain — which used to be the widest grant here.
check "read  host login.keychain-db"   deny  sb /bin/cat "${HOST_HOME}/Library/Keychains/login.keychain-db"
check "list  host ~/Library/Keychains" deny  sb /bin/ls  "${HOST_HOME}/Library/Keychains"
# NOT `security list-keychains` — that only prints the search list out of the
# com.apple.security preference domain, which is still granted (TLS trust
# evaluation reads it), so it succeeds while revealing a path and no secret.
# The meaningful probe is an actual item lookup. No -w, so nothing is printed
# even in the failure case where this unexpectedly succeeds.
check "security find Claude credential" deny sb /usr/bin/security find-generic-password -s 'Claude Code-credentials'
check "fleet credential file exists"   allow sb /bin/test -s "${FLEET_HOME}/.claude/.credentials.json"

echo "--- [8] seed_fleet_home repairs agent tampering"
# The fleet's home is writable, so what makes it SAFE is that launchd re-seeds
# it on every restart (KeepAlive, <=30s). That property is load-bearing, so it
# is tested rather than assumed.
_orig="$(cat "${FLEET_HOME}/.claude/settings.json" 2>/dev/null)"
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"TAMPERED"}]}]}}' \
  > "${FLEET_HOME}/.claude/settings.json"
seed_fleet_home >/dev/null 2>&1
if grep -q TAMPERED "${FLEET_HOME}/.claude/settings.json" 2>/dev/null; then
  printf '  FAIL  %-46s tampered settings.json survived the seed\n' "seed repairs settings.json"
  FAIL=$((FAIL+1))
  [ -n "$_orig" ] && printf '%s' "$_orig" > "${FLEET_HOME}/.claude/settings.json"
else
  printf '  ok    %-46s (repaired)\n' "seed repairs settings.json"; PASS=$((PASS+1))
fi

# Three conditions, not one. `! grep -q TAMPERED` alone is true for a file that
# does not exist, so a seed that silently skipped ccline would report "repaired"
# while proving nothing. Assert the file is back, and byte-identical to the host
# original — that is what "repaired" has to mean.
_ccline="${FLEET_HOME}/.claude/ccline/ccline"
printf '#!/bin/sh\necho TAMPERED\n' > "${_ccline}" 2>/dev/null
seed_fleet_home >/dev/null 2>&1
if [ ! -s "${_ccline}" ]; then
  printf '  FAIL  %-46s ccline missing after seed (did the copy run?)\n' "seed repairs ccline"; FAIL=$((FAIL+1))
elif grep -q TAMPERED "${_ccline}" 2>/dev/null; then
  printf '  FAIL  %-46s tampered ccline survived the seed\n' "seed repairs ccline"; FAIL=$((FAIL+1))
elif ! cmp -s "${HOST_HOME}/.claude/ccline/ccline" "${_ccline}"; then
  printf '  FAIL  %-46s ccline differs from the host original\n' "seed repairs ccline"; FAIL=$((FAIL+1))
else
  printf '  ok    %-46s (repaired)\n' "seed repairs ccline"; PASS=$((PASS+1))
fi

# The seed must never carry the human's session history into the fleet.
#
# Testing for the mere PRESENCE of sessions/, todos/ etc. does not work: agents
# create those themselves in their own home, and that is correct — it is the
# fleet's own state, not the human's. So assert the two things that would only
# be true if host content had travelled.
_pj="$(VAULT="${VAULT}" /usr/bin/python3 - "${FLEET_HOME}/.claude.json" <<'PY' 2>/dev/null
import json, os, sys
try:
    p = json.load(open(sys.argv[1])).get("projects", {})
except Exception:
    print("UNREADABLE"); raise SystemExit
keys = list(p)
print("ok" if keys == [os.environ["VAULT"]] else "LEAKED:%d:%s" % (len(keys), keys[:3]))
PY
)"
if [ "${_pj}" = "ok" ]; then
  printf '  ok    %-46s (vault only)\n' "fleet .claude.json projects stripped"; PASS=$((PASS+1))
else
  printf '  FAIL  %-46s %s\n' "fleet .claude.json projects stripped" "${_pj}"; FAIL=$((FAIL+1))
fi

if [ -f "${HOST_HOME}/.claude/history.jsonl" ] \
   && cmp -s "${HOST_HOME}/.claude/history.jsonl" "${FLEET_HOME}/.claude/history.jsonl" 2>/dev/null; then
  printf '  FAIL  %-46s fleet history.jsonl is a copy of the host'"'"'s\n' "host history.jsonl did not travel"; FAIL=$((FAIL+1))
else
  printf '  ok    %-46s (not copied)\n' "host history.jsonl did not travel"; PASS=$((PASS+1))
fi

echo
echo "=== pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]

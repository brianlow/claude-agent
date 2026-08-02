#!/usr/bin/env bash
# verify-browser.sh — assert the security properties of the browser CONTAINER.
#
# This file used to assert the security property of a SECOND SEATBELT PROFILE.
# That profile is gone: the browser now runs in an Apple container, so the
# things worth asserting changed shape entirely.
#
# What is being defended, and why each check exists:
#
#   1. CDP is unauthenticated. Chromium's debug port trusts every connection it
#      can see, so the ONLY boundary is who can reach the socket. Loopback
#      confinement is therefore not a nicety — it is the whole security model,
#      and it gets two checks, not one.
#   2. The container must hold nothing of value. The old profile's value was in
#      what it did NOT grant; the container's value is in what is NOT mounted.
#   3. The pinned image tag must actually pin the browser binary. That depends
#      on one env var suppressing cloakserve's self-update; delete it and every
#      other check here still passes while the running Chromium drifts.
#   4. A wedged browser must mean "no browser", never "an unconfined browser".
#      agent-browser falls back to launching /Applications/Google Chrome when
#      no CDP port answers; the AGENT's profile denies that exec, and that
#      denial is what makes the failure mode safe.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/fleet-common.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

echo "=== browser container: ${BROWSER_CONTAINER} (${BROWSER_IMAGE})"
echo
echo "--- the browser must actually be there"
if curl -s --max-time 5 "http://127.0.0.1:${BROWSER_CDP_PORT}/json/version" >/dev/null 2>&1; then
  ok "CDP answers on 127.0.0.1:${BROWSER_CDP_PORT}"
else
  bad "CDP does not answer on 127.0.0.1:${BROWSER_CDP_PORT} — is the job loaded?"
fi

echo
echo "--- CDP must be unreachable from anywhere but this Mac"
# CDP has no auth, so this is the entire boundary. Two independent facts have
# to hold: the published socket does not answer on this Mac's LAN-facing
# address (checked live, from this Mac, via curl — a binding test, not a true
# off-host reachability test: nothing here actually probes from another
# host), and the published-port structure itself is bound to 127.0.0.1
# (checked structurally, via `container inspect`).
#
# The plan's original second check here was `net.inet.ip.forwarding == 0`.
# On this host that sysctl reads 1 — there's a bridge100 interface and
# utun0/utun1 default routes from unrelated VM/VPN software, nothing to do
# with Apple `container`. The security property still holds (a Phase 0 spike
# confirmed both the LAN-IP curl and the container's own vmnet IP are
# refused), but the sysctl is not a valid proxy for it on this machine, so it
# is downgraded to an informational line and replaced with a direct
# structural check on the published-ports list.
LANIP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
if [ -z "${LANIP}" ]; then
  printf '  \033[33mn/a\033[0m   no LAN address on en0/en1 — cannot test off-host reachability\n'
elif curl -s --max-time 3 "http://${LANIP}:${BROWSER_CDP_PORT}/json/version" >/dev/null 2>&1; then
  bad "CDP is reachable on the LAN address ${LANIP} — UNAUTHENTICATED AND EXPOSED"
else
  ok "CDP not reachable on LAN address ${LANIP}"
fi

# Informational only — not a pass/fail signal on this host, see comment above.
printf '  \033[33mn/a\033[0m   net.inet.ip.forwarding=%s (informational only on this host; see comment above)\n' \
  "$(sysctl -n net.inet.ip.forwarding 2>/dev/null || echo 'unknown')"

PORTS_JSON="$(container inspect "${BROWSER_CONTAINER}" 2>/dev/null)"
# First line is always "COUNT=<n>" on a successful parse (never omitted, even
# when n=0), so an empty or renamed publishedPorts key is distinguishable
# from "checked and clean" — a missing/empty list must FAIL, not pass by
# default. Remaining lines (if any) are the non-loopback entries.
PORTS_OUT="$(printf '%s' "${PORTS_JSON}" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    c = d[0] if isinstance(d, list) else d
    ports = (c.get("configuration", {}) or {}).get("publishedPorts") or c.get("publishedPorts") or []
    print(f"COUNT={len(ports)}")
    bad = [p for p in ports if p.get("hostAddress") != "127.0.0.1"]
    for p in bad:
        print(p)
except Exception:
    print("PARSE-ERROR")
' 2>/dev/null || echo "PARSE-ERROR")"

PORTS_COUNT_LINE="$(printf '%s\n' "${PORTS_OUT}" | head -1)"
BAD_PORTS="$(printf '%s\n' "${PORTS_OUT}" | tail -n +2)"

if [ "${PORTS_OUT}" = "PARSE-ERROR" ] || [ "${PORTS_COUNT_LINE}" = "PARSE-ERROR" ]; then
  bad "could not read publishedPorts from container inspect"
elif [ "${PORTS_COUNT_LINE}" = "COUNT=0" ]; then
  bad "publishedPorts is empty or missing — cannot verify loopback binding"
elif [ -n "${BAD_PORTS}" ]; then
  bad "published port(s) not bound to 127.0.0.1: ${BAD_PORTS}"
else
  ok "all published ports (${PORTS_COUNT_LINE#COUNT=}) are bound to hostAddress 127.0.0.1"
fi

echo
echo "--- the container must hold nothing of value"
MOUNTS="$(container inspect "${BROWSER_CONTAINER}" 2>/dev/null \
  | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    c=d[0] if isinstance(d,list) else d
    src=[]
    for m in (c.get("configuration",{}).get("mounts") or c.get("mounts") or []):
        s=m.get("source") or (m.get("type") or {}).get("virtiofs",{}).get("source")
        if s: src.append(s)
    print("\n".join(src))
except Exception:
    print("PARSE-ERROR")' 2>/dev/null || echo "PARSE-ERROR")"

# MOUNTS_OK gates everything below: an unparseable or wrongly-keyed mounts
# list must never be silently indistinguishable from "checked and clean". A
# schema drift that renames the mounts key, or a genuinely empty mounts
# array, both yield MOUNTS="" from the parser above — that alone must not
# read as "nothing is mounted". So this asserts the expected mount is
# PRESENT as its own fact, separate from "nothing unexpected is present";
# either one failing is a real FAIL, not a fall-through pass.
MOUNT_PRESENT=0
if [ "${MOUNTS}" = "PARSE-ERROR" ]; then
  bad "could not read mounts from container inspect"
  MOUNTS_OK=0
else
  MOUNTS_OK=1
  if printf '%s\n' "${MOUNTS}" | grep -qxF "${BROWSER_DATA_DIR}"; then
    ok "browser profile dir (${BROWSER_DATA_DIR}) is mounted"
    MOUNT_PRESENT=1
  else
    bad "browser profile dir (${BROWSER_DATA_DIR}) is NOT among the mounts — expected mount missing"
  fi
  UNEXPECTED="$(printf '%s\n' "${MOUNTS}" | grep -v "^${BROWSER_DATA_DIR}$" | grep -v '^$' || true)"
  if [ -n "${UNEXPECTED}" ]; then
    bad "unexpected mounts: ${UNEXPECTED}"
  else
    ok "no mounts beyond the browser profile dir"
  fi
fi

# These must only score when the mounts list is BOTH parseable AND proven to
# be the right list — proven by MOUNT_PRESENT, i.e. having actually found the
# one mount we know must be there. A renamed/misread key parses cleanly to an
# empty MOUNTS, which would otherwise be indistinguishable from "read the
# real list and it's clean". Gating on MOUNT_PRESENT closes that: garbage or
# a wrong-key read can never produce a green "not mounted" for any secret.
for secret in "${VAULT}" "${BEAR_DIR}" "${HOME}/.ssh" "${HOME}/.claude" "${HOME}/Library/Keychains"; do
  if [ "${MOUNT_PRESENT}" != "1" ]; then
    printf '  \033[33mn/a\033[0m   not mounted: %s — could not verify, mounts list unreadable or unrecognized\n' "$(basename "${secret}")"
  elif printf '%s\n' "${MOUNTS}" | grep -qF "${secret}"; then
    bad "SECRET MOUNTED INTO THE BROWSER: ${secret}"
  else
    ok "not mounted: $(basename "${secret}")"
  fi
done

echo
echo "--- the pinned image tag must actually pin the browser binary"
# --env CLOAKBROWSER_AUTO_UPDATE=false is the ONLY thing stopping cloakserve
# from fetching a newer Chromium (~198MB) from GitHub on every start into the
# UNMOUNTED /root/.cloakbrowser. Drop it and nothing else in this file changes
# colour — CDP still answers, the mounts are still clean, the ports are still
# loopback — while the browser actually in use silently stops being the one
# ${BROWSER_IMAGE} ships. So it is asserted here, against the RUNNING
# container's own environment rather than against the source of this repo.
#
# Same fail-closed contract as the publishedPorts check above, for the same
# reason it was written that way: the parser emits "COUNT=<n>" as its first
# line on ANY successful read (never omitted, even at n=0), so "the
# environment list is missing, renamed, or empty" stays distinguishable from
# "read the real list and the value is right". Anything unreadable is a FAIL.
# Line 2, when present, is the variable's value.
ENV_OUT="$(container inspect "${BROWSER_CONTAINER}" 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    c = d[0] if isinstance(d, list) else d
    env = ((c.get("configuration", {}) or {}).get("initProcess", {}) or {}).get("environment")
    if env is None:
        raise KeyError("configuration.initProcess.environment")
    print(f"COUNT={len(env)}")
    for e in env:
        k, sep, v = str(e).partition("=")
        if k == "CLOAKBROWSER_AUTO_UPDATE" and sep:
            print(v)
            break
except Exception:
    print("PARSE-ERROR")
' 2>/dev/null || echo "PARSE-ERROR")"

ENV_COUNT_LINE="$(printf '%s\n' "${ENV_OUT}" | head -1)"
ENV_VALUE="$(printf '%s\n' "${ENV_OUT}" | tail -n +2 | head -1)"
# Anything that is not a well-formed COUNT= line is unreadable, full stop —
# including empty output, a python crash, or a future `container inspect` that
# prints something else entirely.
case "${ENV_COUNT_LINE}" in
  COUNT=*) ;;
  *) ENV_COUNT_LINE="PARSE-ERROR" ;;
esac

if [ "${ENV_COUNT_LINE}" = "PARSE-ERROR" ]; then
  bad "could not read initProcess.environment from container inspect — CLOAKBROWSER_AUTO_UPDATE unverifiable"
elif [ "${ENV_COUNT_LINE}" = "COUNT=0" ]; then
  bad "initProcess.environment is empty or missing — cannot verify CLOAKBROWSER_AUTO_UPDATE"
elif [ -z "${ENV_VALUE}" ]; then
  bad "CLOAKBROWSER_AUTO_UPDATE is not set on the running container — ${BROWSER_IMAGE} no longer pins the browser binary"
elif [ "${ENV_VALUE}" != "false" ]; then
  bad "CLOAKBROWSER_AUTO_UPDATE=${ENV_VALUE} (expected false) — the browser can self-update away from ${BROWSER_IMAGE}"
else
  ok "CLOAKBROWSER_AUTO_UPDATE=false on the running container — self-update suppressed, image tag pins the binary"
fi

echo
echo "--- the browser must not be able to read the host filesystem"
# Probe a HOST-ONLY path. /etc/passwd would be a false pass: the container has
# its own, so reading it proves nothing. /Users/ does not exist inside the
# image, so seeing this user's home directory listed there would mean a mount
# is exposing the host — the one thing a future "just one more --mount" would
# silently do.
# ok is reserved for the case that actually proves the property: the page
# genuinely loaded and its text genuinely did not contain the host home
# directory's name. A failed connect or a failed navigation (e.g. Chromium
# refusing file:///Users/ with net::ERR_FILE_NOT_FOUND because the path
# doesn't exist inside the container) is suggestive but not the same fact —
# it means the probe was inconclusive, not that it passed, so it prints n/a.
if ! agent-browser connect "http://127.0.0.1:${BROWSER_CDP_PORT}" >/dev/null 2>&1; then
  printf '  \033[33mn/a\033[0m   could not connect to CDP — file:// probe inconclusive\n'
elif ! agent-browser open "file:///Users/" >/dev/null 2>&1; then
  printf '  \033[33mn/a\033[0m   file:///Users/ navigation failed — did not genuinely load, probe inconclusive\n'
else
  PAGE_TEXT="$(agent-browser get text body 2>/dev/null || true)"
  if printf '%s' "${PAGE_TEXT}" | grep -qF "$(basename "${HOME}")"; then
    bad "browser can see the host filesystem through file:///Users/"
  else
    ok "page loaded and host filesystem not visible through file:///Users/"
  fi
fi

echo
echo "--- a wedged browser must mean 'no browser', not 'an unconfined browser'"
# agent-browser auto-launches /Applications/Google Chrome when no CDP port
# answers. The AGENT's profile denies that exec — assert it still does, without
# stopping the browser.
# Any agent's profile will do — render_profile has no per-agent substitutions,
# so all of them are byte-identical. Take the first rather than hardcoding
# agent 1, which stops being guaranteed to exist the moment AGENTS changes.
AGENT_PROFILE="$(profile_for "${AGENTS[0]}")"
CHROME_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ ! -f "${AGENT_PROFILE}" ]; then
  printf '  \033[33mn/a\033[0m   %s not rendered — run ./sbx-start.sh first\n' "${AGENT_PROFILE}"
elif [ ! -x "${CHROME_BIN}" ]; then
  # Google Chrome isn't installed at all here, so exec would fail with
  # "No such file or directory" regardless of the profile — that is not
  # evidence the sandbox denies anything, so this must not score as ok.
  printf '  \033[33mn/a\033[0m   Google Chrome not installed — cannot verify exec denial\n'
else
  # sandbox-exec exits 71 both when the profile denies the exec AND when the
  # binary is simply missing — exit status alone can't tell them apart.
  # Discriminate on stderr: Seatbelt's denial reads
  # "...failed: Operation not permitted"; a missing binary instead reads
  # "...failed: No such file or directory".
  CHROME_ERR="$(sandbox-exec -f "${AGENT_PROFILE}" "${CHROME_BIN}" --version 2>&1 >/dev/null)"
  CHROME_STATUS=$?
  if [ "${CHROME_STATUS}" -eq 0 ]; then
    bad "agent profile can exec Google Chrome — the fallback path is open"
  elif printf '%s' "${CHROME_ERR}" | grep -qi "Operation not permitted"; then
    ok "agent profile still denies exec of /Applications/Google Chrome"
  else
    bad "Google Chrome exec failed for a reason other than sandbox denial (exit ${CHROME_STATUS}): ${CHROME_ERR}"
  fi
fi

echo
echo "=== ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]

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
#   3. A wedged browser must mean "no browser", never "an unconfined browser".
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
# to hold: the published socket is loopback-only (checked live, off-host, via
# curl against the LAN address), and the published-port structure itself is
# bound to 127.0.0.1 (checked structurally, via `container inspect`).
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
BAD_PORTS="$(printf '%s' "${PORTS_JSON}" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    c = d[0] if isinstance(d, list) else d
    ports = (c.get("configuration", {}) or {}).get("publishedPorts") or c.get("publishedPorts") or []
    bad = [p for p in ports if p.get("hostAddress") != "127.0.0.1"]
    for p in bad:
        print(p)
except Exception:
    print("PARSE-ERROR")
' 2>/dev/null || echo "PARSE-ERROR")"

if [ "${BAD_PORTS}" = "PARSE-ERROR" ]; then
  bad "could not read publishedPorts from container inspect"
elif [ -n "${BAD_PORTS}" ]; then
  bad "published port(s) not bound to 127.0.0.1: ${BAD_PORTS}"
else
  ok "all published ports are bound to hostAddress 127.0.0.1"
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

if [ "${MOUNTS}" = "PARSE-ERROR" ]; then
  bad "could not read mounts from container inspect"
else
  UNEXPECTED="$(printf '%s\n' "${MOUNTS}" | grep -v "^${BROWSER_DATA_DIR}$" | grep -v '^$' || true)"
  if [ -n "${UNEXPECTED}" ]; then
    bad "unexpected mounts: ${UNEXPECTED}"
  else
    ok "only mount is the browser profile dir"
  fi
fi

for secret in "${VAULT}" "${BEAR_DIR}" "${HOME}/.ssh" "${HOME}/.claude" "${HOME}/Library/Keychains"; do
  if printf '%s\n' "${MOUNTS}" | grep -qF "${secret}"; then
    bad "SECRET MOUNTED INTO THE BROWSER: ${secret}"
  else
    ok "not mounted: $(basename "${secret}")"
  fi
done

echo
echo "--- the browser must not be able to read the host filesystem"
# Probe a HOST-ONLY path. /etc/passwd would be a false pass: the container has
# its own, so reading it proves nothing. /Users/ does not exist inside the
# image, so seeing this user's home directory listed there would mean a mount
# is exposing the host — the one thing a future "just one more --mount" would
# silently do.
if agent-browser connect "http://127.0.0.1:${BROWSER_CDP_PORT}" >/dev/null 2>&1 \
   && agent-browser open "file:///Users/" >/dev/null 2>&1 \
   && agent-browser get text 2>/dev/null | grep -qF "$(basename "${HOME}")"; then
  bad "browser can see the host filesystem through file:///Users/"
else
  ok "host filesystem not visible through file://"
fi

echo
echo "--- a wedged browser must mean 'no browser', not 'an unconfined browser'"
# agent-browser auto-launches /Applications/Google Chrome when no CDP port
# answers. The AGENT's profile denies that exec — assert it still does, without
# stopping the browser.
AGENT_PROFILE="${GEN_DIR}/sbx-agent-1.sb"
if [ ! -f "${AGENT_PROFILE}" ]; then
  printf '  \033[33mn/a\033[0m   %s not rendered — run ./sbx-start.sh first\n' "${AGENT_PROFILE}"
elif sandbox-exec -f "${AGENT_PROFILE}" "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --version >/dev/null 2>&1; then
  bad "agent profile can exec Google Chrome — the fallback path is open"
else
  ok "agent profile still denies exec of /Applications/Google Chrome"
fi

echo
echo "=== ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]

#!/usr/bin/env bash
# verify-detection.sh — does the containerized browser still beat bot detection?
#
# The whole point of CloakBrowser is fingerprint realism, and this change swaps
# the binary underneath it (macOS Chromium 145 / 26 patches -> Linux Chromium
# 146 / 58 patches) AND removes the GPU. Both are exactly the kind of change
# that passes every functional check while quietly failing the actual job.
#
# This does not replace real-world testing: synthetic suites measure the
# fingerprint, not whether a retailer serves you a product page.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/fleet-common.sh"

CDP="http://127.0.0.1:${BROWSER_CDP_PORT}"
curl -s --max-time 5 "${CDP}/json/version" >/dev/null 2>&1 || {
  echo "browser not answering on ${CDP} — start it with ./sbx-start.sh" >&2
  exit 1
}

agent-browser connect "${CDP}" >/dev/null

echo "=== environment"
agent-browser open "https://example.com" >/dev/null
echo "  userAgent   : $(agent-browser eval "navigator.userAgent" 2>/dev/null)"
echo "  platform    : $(agent-browser eval "navigator.platform" 2>/dev/null)"
echo "  webdriver   : $(agent-browser eval "navigator.webdriver" 2>/dev/null)"
echo "  cores/mem   : $(agent-browser eval "navigator.hardwareConcurrency + ' / ' + navigator.deviceMemory" 2>/dev/null)"
echo "  screen      : $(agent-browser eval "screen.width + 'x' + screen.height" 2>/dev/null)"

echo
echo "=== WebGL — a MISSING context is itself a fingerprint tell"
# NOTES.md records that CloakBrowser fabricates the renderer string (it claimed
# an M2 Max on an M1 Pro host under SwiftShader). The requirement is a WORKING
# context with a plausible string, NOT hardware acceleration — which is what
# makes a GPU-less VM viable at all. This is where that gets checked for real.
agent-browser eval "(()=>{const g=document.createElement('canvas').getContext('webgl');if(!g)return'NO WEBGL CONTEXT — FAIL';const d=g.getExtension('WEBGL_debug_renderer_info');return g.getParameter(d.UNMASKED_VENDOR_WEBGL)+' | '+g.getParameter(d.UNMASKED_RENDERER_WEBGL)})()"

echo
echo "=== incolumitas bot detection (scores near 1.0 are good)"
agent-browser open "https://bot.incolumitas.com/" >/dev/null
# The suite runs its tests asynchronously after load. The brief's 25s minimum
# was not enough on this machine on the first attempt (see deviation note in
# task-5-report.md) — poll instead of a single fixed sleep, so a slow run
# doesn't get recorded half-finished.
DEADLINE=$((SECONDS + 60))
LAST_LEN=0
STABLE_COUNT=0
while [ "${SECONDS}" -lt "${DEADLINE}" ]; do
  sleep 5
  CUR_LEN=$(agent-browser eval "(document.getElementById('detection-tests') ? document.getElementById('detection-tests').innerText : document.body.innerText).length" 2>/dev/null || echo 0)
  if [ "${CUR_LEN}" = "${LAST_LEN}" ] && [ "${CUR_LEN}" != "0" ]; then
    STABLE_COUNT=$((STABLE_COUNT + 1))
    [ "${STABLE_COUNT}" -ge 2 ] && break
  else
    STABLE_COUNT=0
  fi
  LAST_LEN="${CUR_LEN}"
done
agent-browser eval "document.getElementById('detection-tests') ? document.getElementById('detection-tests').innerText.slice(0,1200) : document.body.innerText.slice(0,1200)"

echo
echo "=== sannysoft"
agent-browser open "https://bot.sannysoft.com/" >/dev/null
sleep 8
agent-browser eval "Array.from(document.querySelectorAll('table tr')).slice(0,25).map(r=>r.innerText.replace(/\s+/g,' ')).join('\n')"

echo
echo "Record these in NOTES.md next to the macOS baseline. Red rows in sannysoft"
echo "and a low incolumitas score are the failures worth acting on; cosmetic"
echo "differences from the macOS run are expected — it is a different OS."

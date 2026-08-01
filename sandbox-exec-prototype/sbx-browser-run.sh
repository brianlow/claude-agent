#!/usr/bin/env bash
# sbx-browser-run.sh — CloakBrowser under its own Seatbelt profile, foreground,
# launchd-managed. One process, no pty (unlike the agent, this has no TUI).
#
# WHY THIS IS A SEPARATE JOB
#
# CloakBrowser cannot run inside the agent's sandbox. It aborts at startup:
#
#   abort() called / HIServices ___RegisterApplication_block_invoke
#                  / HIServices TransformProcessType
#
# TransformProcessType is a LaunchServices call, and LaunchServices is the
# mach-lookup revision 04 deliberately REMOVED to close the `open -a` confused-
# deputy escape. Granting it back gets further and then SIGSEGVs in
# -[NSWindow _close] unless WindowServer is granted too. Playwright's
# headless_shell tolerated both denials; the full Chromium.app does not, and
# CloakBrowser ships only the full bundle — the C++ fingerprint patches ARE the
# browser, so there is no headless-shell variant to fall back to.
#
# Rather than widen the agent's profile to fit the browser (which would undo
# most of what verify.sh proves), the two capability sets live in two sandboxes:
#
#   agent   — vault, Bear, Keychain, gcalcli.  NO GUI, NO LaunchServices.
#   browser — GUI, LaunchServices.             NO secrets at all.
#
# THE AGENT DOES NOT LAUNCH THIS. That is a security property, not an
# accident of packaging: launchd owns this command line, so a hostile session
# operator cannot add --allow-file-access (which would let pages read local
# files), repoint --user-data-dir, or load an extension. The agent's only reach
# is CDP on loopback, and CDP has no verb that spawns a process.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/fleet-common.sh"

mkdir -p "${LOG_DIR}" "${GEN_DIR}" "${BROWSER_DATA_DIR}"

CB="$(cloak_bin)"
[ -n "${CB}" ] && [ -x "${CB}" ] || {
  echo "CloakBrowser not installed. Run (unsandboxed, on the host):" >&2
  echo "  npm install -g cloakbrowser && cloakbrowser install" >&2
  exit 1
}

render_browser_profile > "${BROWSER_PROFILE}"

# Compile-check before exec. A syntax error otherwise becomes a silent 30s
# KeepAlive spin rather than a visible failure — the same trap the agent job
# hit during productionizing.
sandbox-exec -f "${BROWSER_PROFILE}" /usr/bin/true 2>/dev/null || {
  echo "browser profile failed to compile: ${BROWSER_PROFILE}" >&2
  sandbox-exec -f "${BROWSER_PROFILE}" /usr/bin/true || true
  exit 1
}

echo "$(date '+%Y-%m-%dT%H:%M:%S') starting browser"
echo "  profile : ${BROWSER_PROFILE}"
echo "  binary  : ${CB}"
echo "  datadir : ${BROWSER_DATA_DIR}/default"
echo "  cdp     : 127.0.0.1:${BROWSER_CDP_PORT}"

cd /private/tmp

# --no-sandbox: Chromium's OWN sandbox is Seatbelt-based, and Seatbelt does not
#   nest — inside sandbox-exec the zygote cannot issue its sandbox extension
#   (deny file-issue-extension ... com.apple.app-sandbox.read) and the browser
#   dies before writing DevToolsActivePort. What is lost is Chromium's internal
#   renderer/browser split, NOT our boundary: every process in this tree is
#   still confined by the profile above, which is the stronger of the two.
# --remote-debugging-address: loopback explicitly. Never 0.0.0.0 — CDP is
#   unauthenticated, so binding it to a routable address would hand the browser
#   to the network.
exec sandbox-exec -f "${BROWSER_PROFILE}" \
  "${CB}" \
    --headless \
    --no-sandbox \
    --user-data-dir="${BROWSER_DATA_DIR}/default" \
    --remote-debugging-port="${BROWSER_CDP_PORT}" \
    --remote-debugging-address=127.0.0.1

#!/usr/bin/env bash
# sbx-browser-run.sh — CloakBrowser in an Apple container, foreground,
# launchd-managed. One `container run`, no pty (unlike the agent, no TUI).
#
# WHY A CONTAINER AND NOT A SANDBOX
#
# This job used to be `sandbox-exec -f profiles/07-browser.sb ... Chromium.app`.
# CloakBrowser cannot run in the AGENT's profile — it abort()s in
# TransformProcessType without LaunchServices and SIGSEGVs in -[NSWindow _close]
# without WindowServer, which are exactly the grants revisions 04 and 05 removed
# to close the `open -a` confused-deputy escape.
#
# Giving those grants to a second Seatbelt profile MOVED that escape instead of
# deleting it. A Linux container has neither service to grant, so the capability
# is gone. That is the entire point of this job's existence in this form.
#
# THE AGENT DOES NOT LAUNCH THIS, and that is a security property rather than a
# packaging accident: launchd owns this command line, so a hostile session
# operator cannot add --allow-file-access, repoint --data-dir, add a --mount, or
# load an extension. The agent's only reach is CDP on loopback, and CDP has no
# verb that spawns a process.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/fleet-common.sh"

mkdir -p "${LOG_DIR}" "${BROWSER_DATA_DIR}"

# The container system may still be coming up (e.g. just after login), and
# launchd will have started this job before anyone ran a container command.
container system status &>/dev/null || container system start

# Clean slot: drop any stale/stopped/running container with this name, so a
# reboot or a crashed job never wedges the name. Same reason ../agent-run.sh
# does it.
container rm -f "${BROWSER_CONTAINER}" &>/dev/null || true

echo "$(date '+%Y-%m-%dT%H:%M:%S') starting browser container"
echo "  image     : ${BROWSER_IMAGE}"
echo "  container : ${BROWSER_CONTAINER}"
echo "  profile   : ${BROWSER_DATA_DIR}"
echo "  cdp       : 127.0.0.1:${BROWSER_CDP_PORT}"
echo "  seed      : ${BROWSER_FINGERPRINT}"

# --publish 127.0.0.1:...  loopback EXPLICITLY. Never a routable address: CDP is
#   unauthenticated, so binding it anywhere reachable hands the browser to the
#   network. verify-browser.sh asserts this from the outside.
# --mount  the only mount. Nothing else may be added here — the container's
#   security value is precisely that it holds nothing worth stealing.
#   verify-browser.sh asserts this is the ONLY mount, so a second one is a test
#   failure, not a convenience.
# --memory 4g  Apple container defaults are modest and Chromium is not.
# --env CLOAKBROWSER_AUTO_UPDATE=false  the image ships a Chromium build, but
#   cloakserve otherwise checks GitHub on every start and downloads a newer one
#   (~198MB) into /root/.cloakbrowser — which is NOT mounted, so the download
#   repeats on EVERY container start, and a KeepAlive crash loop would re-pull it
#   every 30s. It also means the pinned image tag would not actually pin the
#   browser binary in use. false makes the tag mean what it says.
# no -d  foreground, so launchd tracks the process lifetime and KeepAlive works.
# no caffeinate  the agent job already holds the Mac awake; a browser with no
#   agent driving it has no reason to prevent sleep.
#
# WHY `sh -c 'touch /run/.containerenv && exec cloakserve ...'` AND NOT
# `cloakserve ...` DIRECTLY — do not "simplify" this away:
#   cloakserve chooses its bind address with
#   `os.path.exists("/.dockerenv") or os.path.exists("/run/.containerenv")` —
#   0.0.0.0 in a container, 127.0.0.1 otherwise. Apple `container` creates
#   NEITHER marker, so cloakserve binds the container's OWN loopback, while
#   --publish NATs onto the container's routable interface. The result is a
#   container that looks perfectly healthy in `container ls` and is permanently
#   unreachable from the host — a silent hang, not a crash, so KeepAlive never
#   notices. The marker file makes the detection correct.
#   This does NOT widen exposure: 0.0.0.0 is inside the container's own network
#   namespace, and the host side of the publish is still pinned to 127.0.0.1.
exec container run \
  --name "${BROWSER_CONTAINER}" \
  --rm \
  --publish "127.0.0.1:${BROWSER_CDP_PORT}:9222" \
  --mount "source=${BROWSER_DATA_DIR},target=/profile" \
  --memory 4g \
  --cpus 2 \
  --env CLOAKBROWSER_AUTO_UPDATE=false \
  "${BROWSER_IMAGE}" \
  sh -c "touch /run/.containerenv && exec cloakserve --data-dir=/profile --fingerprint=${BROWSER_FINGERPRINT}"

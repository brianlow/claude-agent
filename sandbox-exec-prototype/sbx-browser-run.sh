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
# packaging accident. State precisely what launchd owning this job buys, because
# an earlier version of this comment overclaimed it:
#
#   STRUCTURALLY FIXED — literal argv elements written in this file, which no
#   environment variable and no shell metacharacter can add to or alter: the
#   image reference, the single --mount (both source and target), the --publish
#   HOST ADDRESS 127.0.0.1, the resource limits, and the flag list handed to
#   cloakserve. A hostile session operator therefore cannot add
#   --allow-file-access, repoint the profile dir at $HOME, add a second --mount,
#   append a --load-extension, or move CDP off loopback.
#
#   NOT FIXED — the browser plist carries no EnvironmentVariables dict, so this
#   job inherits the launchd gui-domain environment, and `launchctl setenv` is
#   reachable from inside the agent's Seatbelt profile. Two values in
#   fleet-common.sh read from that environment: BROWSER_FINGERPRINT and
#   BROWSER_CDP_PORT. Each is passed as ONE fully-quoted argv element — the seed
#   via --env, dereferenced by NAME inside the container, never interpolated
#   into the `sh -c` string — so the most either can do is change its own value:
#   a different fingerprint seed, or a different loopback port. Neither can grow
#   the argv, and neither reaches the host address, the mount, or the image.
#
# The agent's only other reach is CDP on loopback, and CDP has no verb that
# spawns a process.
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
#   verify-browser.sh asserts this variable is present on the RUNNING container,
#   because deleting it breaks nothing that any other check can see.
# --env BROWSER_FINGERPRINT=...  the seed travels as DATA, not as text spliced
#   into a command string. It is env-overridable (fleet-common.sh) and this job
#   inherits the gui-domain environment, so interpolating it into the `sh -c`
#   body below — which is what this script used to do — let anyone who can call
#   `launchctl setenv` inject shell metacharacters into the container's command
#   line. As an --env value it is one opaque argv element; the `sh -c` body
#   below is SINGLE-quoted and dereferences "${BROWSER_FINGERPRINT}" by name
#   inside the container, so a value containing `;`, `&&`, or a quote is passed
#   to cloakserve verbatim as one argument and executes nothing.
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
  --env "BROWSER_FINGERPRINT=${BROWSER_FINGERPRINT}" \
  "${BROWSER_IMAGE}" \
  sh -c 'touch /run/.containerenv && exec cloakserve --data-dir=/profile --fingerprint="${BROWSER_FINGERPRINT}"'

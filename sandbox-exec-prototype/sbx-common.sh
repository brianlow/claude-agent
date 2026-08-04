#!/usr/bin/env bash
# sbx-common.sh — shared config + helpers for the sandbox-exec fleet.
# Every sbx-*.sh script sources this; it is the one place fleet-wide config lives.
# SOURCE this file; do not execute it. Deliberately does NOT set
# `set -euo pipefail` so it can't alter a caller's shell options.
#
# This fleet is entirely self-contained under sandbox-exec-prototype/ and
# shares NOTHING with the Apple Container fleet in the parent directory:
#
#   | thing          | container fleet                  | this fleet                       |
#   |----------------|----------------------------------|----------------------------------|
#   | launchd label  | com.brianlow.claude-agent.N      | com.brianlow.claude-sbx.N        |
#   | plists         | ../launchd/                      | ./launchd/                       |
#   | logs           | ~/.claude-agent/logs/            | ~/.claude-sbx/logs/              |
#   | session names  | agent-N                          | sbx-agent-N                      |
#   | isolation      | Linux container                  | sandbox-exec (Seatbelt)          |
#
# Distinct on every axis, so both can be loaded at once without interfering.
# No script in the parent directory is read, written, or executed from here.

SBX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The human's home directory, captured at source time.
#
# Use this, never $HOME, anywhere below that means "the human's home".
# sbx-agent-run.sh reassigns $HOME to FLEET_HOME before it launches an agent,
# and a $HOME inside a FUNCTION BODY is expanded when the function is CALLED —
# so render_profile would otherwise render the log dir, and every read-only host
# toolchain path, under the fleet home. The failure mode is an agent that starts
# and hangs with no error, because pty-run.py becomes unreadable inside the
# sandbox. Assignments at the top level of this file are evaluated at source
# time and would be fine either way; they use HOST_HOME anyway so the rule has
# no exceptions to remember.
HOST_HOME="${HOME}"

# Five agents, one browser — matching the Apple Container fleet this replaced.
# Every agent gets an identical rendered profile (render_profile takes N but the
# template has no per-agent paths) and the same cwd, the vault. That sharing is
# inherited from the container fleet, not new here.
AGENTS=(1 2 3 4 5)
LABEL_PREFIX="com.brianlow.claude-sbx"
LOG_DIR="${HOST_HOME}/.claude-sbx/logs"
PLIST_DIR="${SBX_DIR}/launchd"
GEN_DIR="${SBX_DIR}/generated"
PROFILE_TEMPLATE="${SBX_DIR}/profiles/agent.sb.template"
GUI_DOMAIN="gui/$(id -u)"

# The fleet's own HOME. Every WRITABLE grant in the profile resolves here, so an
# agent that rewrites settings.json, a plugin hook, or the ccline binary rewrites
# the FLEET's copy. The host's ~/.claude holds two things the HOST's own claude
# executes unsandboxed — settings.json hooks and ccline/ccline — so a writable
# path to it is an escape that never has to break out of the sandbox at all.
# It is now explicitly denied in the profile, not merely un-granted.
FLEET_HOME="${HOST_HOME}/.claude-sbx/home"

VAULT="${HOST_HOME}/Library/Mobile Documents/iCloud~md~obsidian/Documents/Brian's Vault"
BEAR_DIR="${HOST_HOME}/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data"

# Plain Claude Code from the official installer — NOT the cmux-wrapped binary
# that comes first on PATH.
CLAUDE_BIN="${CLAUDE_BIN:-${HOST_HOME}/.local/bin/claude}"

# launchd jobs inherit a minimal PATH, and it has to cover the actual toolchain,
# not just system binaries. node/npm/npx live under asdf here, so a system-only
# PATH means every npx-launched MCP server dies at startup with
#   Executable not found in $PATH: "node"
# — which reads like a missing install and isn't one. The Seatbelt profile
# already grants read+exec on ~/.asdf and /opt/homebrew; this is purely about
# resolution.
#
# ~/.asdf/bin as well as the shims: a shim execs ~/.asdf/bin/asdf by absolute
# path, so it doesn't strictly need this, but anything invoking `asdf` directly
# does.
export PATH="${HOST_HOME}/.asdf/shims:${HOST_HOME}/.asdf/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# --- browser (a container, not a second sandbox) -----------------------------
# The browser USED to run natively under profiles/07-browser.sb.template. It
# could not run in the agent's profile: it needs LaunchServices
# (TransformProcessType abort()s without it) and WindowServer (SIGSEGV in
# -[NSWindow _close] without it) — precisely the grants revisions 04 and 05
# removed to close the `open -a` confused-deputy escape.
#
# Giving those grants to a second profile moved that escape rather than
# deleting it: a Chromium exploit from a hostile page landed in a sandbox that
# could launch unconfined GUI apps. A Linux container has no LaunchServices and
# no WindowServer to grant, so the capability is gone rather than relocated.
#
# What is deliberately unchanged: launchd owns the browser's command line, not
# the agent. Precisely — and this comment used to overclaim it — the image
# reference, the single --mount, the --publish HOST ADDRESS 127.0.0.1, and
# cloakserve's flag list are literal argv elements in sbx-browser-run.sh, so a
# hostile session operator cannot add --allow-file-access, repoint the profile
# dir, load an extension, add a mount, or move CDP off loopback.
#
# The two values below that read from the environment (BROWSER_CDP_PORT,
# BROWSER_FINGERPRINT) ARE operator-influenceable: the browser plist has no
# EnvironmentVariables dict, so the job inherits the gui-domain environment and
# `launchctl setenv` is reachable from inside the agent's profile. Each is
# passed as one fully-quoted argv element (the seed via --env, dereferenced by
# name inside the container), so the most either can do is change its own
# value — a different seed, or a different LOOPBACK port. Neither can grow the
# argv. See the long comment in sbx-browser-run.sh.
#
# The agent's only other reach is CDP, and CDP has no verb that spawns a process.
BROWSER_IMAGE="cloakhq/cloakbrowser:0.5.3"     # pinned; :latest would change the browser under us
BROWSER_CONTAINER="sbx-browser"
BROWSER_DATA_DIR="${SBX_DIR}/browser-profile"  # in-repo and gitignored, so browser state is local to the project

# Bound to loopback on the host side. Chromium's CDP has NO authentication, so
# this port is ambient authority for every local process — not just our agent.
# Loopback is what keeps it off the network; there is no auth to add.
BROWSER_CDP_PORT="${BROWSER_CDP_PORT:-9222}"

# A pinned fingerprint seed. Without one, CloakBrowser generates a random
# identity at every startup, so every launchd restart would present a brand-new
# device to the same sites. The seed is what keeps the DEVICE stable across
# restarts.
#
# It does NOT make anything persist, and an earlier version of this comment
# wrongly implied it did: the browser profile is EPHEMERAL. Cookies and
# localStorage do not survive a container restart under --data-dir=/profile,
# nor under the --user-data-dir=/profile/chrome fallback (cloakserve swallows
# that flag) — both tested live; see "Q2 re-tested" in NOTES.md. So the device
# stays stable while the session resets, and anything that depends on staying
# logged in across a browser-job restart will silently log out. That gap is
# accepted deliberately, not overlooked.
#
# Env-overridable, and this job inherits the gui-domain environment — so it is
# handed to the container via --env and must NEVER be interpolated into a shell
# command string. See sbx-browser-run.sh.
BROWSER_FINGERPRINT="${BROWSER_FINGERPRINT:-41337}"

browser_label() { printf '%s.browser' "${LABEL_PREFIX}"; }
browser_plist() { printf '%s/%s.plist' "${PLIST_DIR}" "$(browser_label)"; }

# `container ls -q` prints one container ID per line, and --name sets the ID.
# Matching whole lines keeps this independent of the table format.
browser_container_running() { container ls -q 2>/dev/null | grep -qx "${BROWSER_CONTAINER}"; }
browser_container_present() { container ls -a -q 2>/dev/null | grep -qx "${BROWSER_CONTAINER}"; }

browser_state() {
  if ! browser_container_present; then printf 'absent'; return; fi
  if ! browser_container_running; then printf 'stopped'; return; fi
  # A running container is NOT proof of a working browser, and launchd cannot
  # tell the difference — KeepAlive only sees that the job still exists. The
  # CDP probe is the source of truth, same as it was for the native browser.
  if curl -s --max-time 2 "http://127.0.0.1:${BROWSER_CDP_PORT}/json/version" >/dev/null 2>&1; then
    printf 'running (container, CDP %s ok)' "${BROWSER_CDP_PORT}"
  else
    printf 'running (container up, CDP NOT RESPONDING)'
  fi
}

label_for()   { printf '%s.%s' "${LABEL_PREFIX}" "$1"; }
plist_for()   { printf '%s/%s.plist' "${PLIST_DIR}" "$(label_for "$1")"; }
profile_for() { printf '%s/sbx-agent-%s.sb' "${GEN_DIR}" "$1"; }
session_for() { printf 'sbx-agent-%s' "$1"; }

is_loaded_label() { launchctl print "${GUI_DOMAIN}/$1" &>/dev/null; }
is_loaded()       { is_loaded_label "$(label_for "$1")"; }

# Is the agent's claude process actually alive? There's no container to query,
# so match the remote-control session name on the command line.
#
# The trailing ( |$) is not decoration: pgrep -f takes an extended regex and
# matches a substring, so a bare "sbx-agent-1" also matches sbx-agent-10's
# command line. Harmless at AGENTS=(1..5), silently wrong the day the fleet
# grows past 9 — and the symptom would be "agent 1 looks up when it isn't".
agent_pid() { pgrep -f -- "--remote-control $(session_for "$1")( |\$)" 2>/dev/null | head -1; }

agent_state() {
  local pid; pid="$(agent_pid "$1")"
  if [ -n "$pid" ]; then printf 'running (pid %s)' "$pid"; else printf 'absent'; fi
}

# Populate ${FLEET_HOME} from the host. One-way: host → fleet, never back.
#
# Re-run on every launch, so anything an agent rewrote is REPAIRED on restart
# (launchd KeepAlive, <=30s). That repair is what makes it safe for the fleet's
# copy to be writable at all: tampering has a shelf life of one restart. The
# property is load-bearing and therefore tested — see section [7] of
# sbx-verify.sh, which tampers and asserts the repair.
#
# Copies only what an agent needs to START. Deliberately absent, and this is a
# hard requirement rather than an oversight: projects/, history.jsonl,
# file-history/, shell-snapshots/, sessions/, todos/, debug/, telemetry/. Those
# are the human's own session transcripts (196MB of them) and the fleet has no
# business reading them.
#
# Idempotent, returns 0. Safe to call on every launch.
seed_fleet_home() {
  mkdir -p "${FLEET_HOME}/.claude" "${FLEET_HOME}/.npm"
  chmod 700 "${FLEET_HOME}"

  # Directories the host owns: mirror exactly. --delete removes agent additions,
  # which IS the repair property — a planted file in plugins/ does not survive.
  local d
  for d in plugins ccline; do
    [ -d "${HOST_HOME}/.claude/${d}" ] || continue
    rsync -a --delete "${HOST_HOME}/.claude/${d}/" "${FLEET_HOME}/.claude/${d}/"
  done

  # Flat files the host owns.
  #
  # .credentials.json is deliberately NOT in this list. The host's copy is a
  # HUSK (empty tokens, epoch expiry) and copying it would clobber the real
  # credential that seed_fleet_credentials writes from the keychain item. That
  # function owns this one file; nothing else may touch it.
  local f
  for f in settings.json statusline-ps1.sh; do
    [ -f "${HOST_HOME}/.claude/${f}" ] || continue
    cp -p "${HOST_HOME}/.claude/${f}" "${FLEET_HOME}/.claude/${f}"
  done

  # ~/.claude.json carries 16 project entries with exampleFiles — host paths the
  # fleet must not see. Strip `projects` wholesale and re-add ONLY the vault,
  # pre-trusted, so the agent doesn't hit the trust dialog on a fresh home.
  if [ -f "${HOST_HOME}/.claude.json" ]; then
    VAULT="${VAULT}" /usr/bin/python3 - \
      "${HOST_HOME}/.claude.json" "${FLEET_HOME}/.claude.json" <<'PY'
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src))
d["projects"] = {os.environ["VAULT"]: {"hasTrustDialogAccepted": True,
                                       "hasCompletedProjectOnboarding": True}}
json.dump(d, open(dst, "w"))
PY
    chmod 600 "${FLEET_HOME}/.claude.json"
  fi
  return 0
}

# Give the fleet a file-based credential, so the keychain can leave the profile.
#
# WHY THIS IS NOT OPTIONAL. It is not merely that the keychain grant is wide —
# it is that the login keychain is located RELATIVE TO $HOME. Once
# seed_fleet_home + `export HOME` move the fleet's home, securityd looks for
# login.keychain-db under ~/.claude-sbx/home/Library/Keychains, which does not
# exist, and every agent comes up "Not logged in". Measured directly:
#
#   HOME=/Users/brianlow                    -> keychain item FOUND
#   HOME=/Users/brianlow/.claude-sbx/home   -> NOT FOUND (rc=44)
#
# So the fleet home and the file credential are ONE change, not two. Spelling
# the profile's keychain grant __HOSTHOME__ does not save it; the grant was
# never the binding constraint.
#
# That is survivable because Claude Code needs a credential STORE, not the
# keychain specifically: on macOS it prefers the keychain and falls back to
# ~/.claude/.credentials.json when the keychain is unreachable.
#
# The host's own ~/.claude/.credentials.json is a HUSK on this machine (empty
# tokens, epoch expiry), so copying that file is useless — that is exactly what
# made the keychain look mandatory on the first pass. The live token is in the
# keychain item, so read it from there and write it out as the file.
#
# 0600, inside a FLEET_HOME that is 0700. This is a real refresh token in
# plaintext on disk; the keychain was at least encrypted at rest. Accepted
# because the alternative is granting the fleet the host login keychain, which
# is every secret Brian owns rather than this one.
#
# KNOWN RISK, accepted deliberately: the fleet now holds a COPY of an OAuth
# grant the host also holds. If refreshing rotates the refresh token, whichever
# side refreshes second is logged out. Fingerprint to detect it (hash only,
# never print the token):
#
#   security find-generic-password -s 'Claude Code-credentials' -w \
#     | /usr/bin/python3 -c "import json,sys,hashlib;print(hashlib.sha256(\
#       json.load(sys.stdin)['claudeAiOauth']['refreshToken'].encode()\
#       ).hexdigest()[:16])"
#
# A changed value after an agent has run past the access-token expiry means
# rotation is live, and the fleet needs its own login rather than a copy.
seed_fleet_credentials() {
  local dest="${FLEET_HOME}/.claude/.credentials.json"
  local token
  token="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null)" || {
    echo "WARNING: no 'Claude Code-credentials' in the host keychain — agents will not authenticate" >&2
    return 0
  }
  # Reject the husk rather than overwrite a working fleet credential with it.
  printf '%s' "${token}" | /usr/bin/python3 -c '
import json, sys
try:
    d = json.load(sys.stdin).get("claudeAiOauth", {})
except ValueError:
    sys.exit(1)
sys.exit(0 if d.get("accessToken") and d.get("refreshToken") else 1)
' || { echo "WARNING: host keychain credential is empty — leaving the fleet copy alone" >&2; return 0; }

  ( umask 077; printf '%s' "${token}" > "${dest}" )
  chmod 600 "${dest}"
  return 0
}

# Render the Seatbelt profile from its template. Paths are substituted rather
# than hardcoded so this isn't tied to one username, and so the log directory
# stays in sync with the fleet config above.
#
# TWO homes, and the split is the whole point: __HOME__ is the fleet's, where
# every writable grant lands; __HOSTHOME__ is the human's, granted read/exec
# only for the toolchain (asdf, git config, the claude install) and explicitly
# DENIED for ~/.claude, ~/.claude.json and ~/.npm by the backstops.
#
# HOST_HOME, not $HOME, in the last two: this function is called from
# sbx-agent-run.sh AFTER it exports HOME=${FLEET_HOME}, and a $HOME in a
# function body expands at call time. See the HOST_HOME comment at the top.
render_profile() {
  local n="$1"
  sed -e "s|__HOME__|${FLEET_HOME}|g" \
      -e "s|__HOSTHOME__|${HOST_HOME}|g" \
      -e "s|__VAULT__|${VAULT}|g" \
      -e "s|__LOGDIR__|${HOST_HOME}/.claude-sbx|g" \
      "${PROFILE_TEMPLATE}"
}

render_plist() {
  local n="$1" label log
  label="$(label_for "$n")"
  log="${LOG_DIR}/agent-${n}.log"
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${SBX_DIR}/sbx-agent-run.sh</string>
        <string>${n}</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>30</integer>
    <key>WorkingDirectory</key><string>${SBX_DIR}</string>
    <!-- Pin TERM here too, so the job doesn't depend on the environment of
         whoever ran sbx-start.sh. sbx-agent-run.sh also forces it. -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>TERM</key><string>xterm-256color</string>
        <key>COLORTERM</key><string>truecolor</string>
    </dict>
    <key>StandardOutPath</key><string>${log}</string>
    <key>StandardErrorPath</key><string>${log}</string>
</dict>
</plist>
PLIST
}

render_browser_plist() {
  local label log
  label="$(browser_label)"
  log="${LOG_DIR}/browser.log"
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${SBX_DIR}/sbx-browser-run.sh</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>30</integer>
    <key>WorkingDirectory</key><string>${SBX_DIR}</string>
    <key>StandardOutPath</key><string>${log}</string>
    <key>StandardErrorPath</key><string>${log}</string>
</dict>
</plist>
PLIST
}

print_status() {
  printf '%-13s %-12s %s\n' "AGENT" "LAUNCHD" "PROCESS"
  local n l
  for n in "${AGENTS[@]}"; do
    if is_loaded "$n"; then l="loaded"; else l="not loaded"; fi
    printf '%-13s %-12s %s\n' "$(session_for "$n")" "$l" "$(agent_state "$n")"
  done
  if is_loaded_label "$(browser_label)"; then l="loaded"; else l="not loaded"; fi
  printf '%-13s %-12s %s\n' "browser" "$l" "$(browser_state)"
}

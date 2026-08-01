#!/usr/bin/env bash
# fleet-common.sh — shared config + helpers for the sandbox-exec fleet.
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

AGENTS=(1)                                   # fleet of 1 for now
LABEL_PREFIX="com.brianlow.claude-sbx"
LOG_DIR="${HOME}/.claude-sbx/logs"
PLIST_DIR="${SBX_DIR}/launchd"
GEN_DIR="${SBX_DIR}/generated"
PROFILE_TEMPLATE="${SBX_DIR}/profiles/06-production.sb.template"
GUI_DOMAIN="gui/$(id -u)"

VAULT="${HOME}/Library/Mobile Documents/iCloud~md~obsidian/Documents/Brian's Vault"
BEAR_DIR="${HOME}/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data"

# Plain Claude Code from the official installer — NOT the cmux-wrapped binary
# that comes first on PATH.
CLAUDE_BIN="${CLAUDE_BIN:-${HOME}/.local/bin/claude}"

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
export PATH="${HOME}/.asdf/shims:${HOME}/.asdf/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# --- browser (the second sandbox) -------------------------------------------
# CloakBrowser cannot run inside the agent's profile: it needs LaunchServices
# (TransformProcessType abort()s without it) and WindowServer (SIGSEGV in
# -[NSWindow _close] without it), which are precisely the grants the agent
# profile exists to withhold. So it gets its own launchd job and its own
# Seatbelt profile, and the agent reaches it only over localhost CDP.
# See profiles/07-browser.sb.template and NOTES.md.
BROWSER_PROFILE_TEMPLATE="${SBX_DIR}/profiles/07-browser.sb.template"
BROWSER_PROFILE="${GEN_DIR}/sbx-browser.sb"
BROWSER_DATA_DIR="${HOME}/.claude-sbx/browser"

# Bound to loopback. Chromium's CDP has NO authentication, so this port is
# ambient authority for every local process — not just our agent. Loopback is
# what keeps it off the network; there is no auth to add.
BROWSER_CDP_PORT="${BROWSER_CDP_PORT:-9222}"

# Resolved by glob, not pinned: cloakbrowser self-updates into a new
# chromium-<version>/ directory, and the profile grants the whole
# ~/.cloakbrowser subpath, so an update must not require a config edit here.
cloak_bin() {
  ls -d "${HOME}"/.cloakbrowser/chromium-*/Chromium.app/Contents/MacOS/Chromium 2>/dev/null | sort -V | tail -1
}

browser_label()   { printf '%s.browser' "${LABEL_PREFIX}"; }
browser_plist()   { printf '%s/%s.plist' "${PLIST_DIR}" "$(browser_label)"; }
browser_pid()     { pgrep -f -- "--remote-debugging-port=${BROWSER_CDP_PORT}" 2>/dev/null | head -1; }

browser_state() {
  local pid; pid="$(browser_pid)"
  if [ -z "$pid" ]; then printf 'absent'; return; fi
  if curl -s --max-time 2 "http://127.0.0.1:${BROWSER_CDP_PORT}/json/version" >/dev/null 2>&1; then
    printf 'running (pid %s, CDP %s ok)' "$pid" "${BROWSER_CDP_PORT}"
  else
    # Alive but not answering CDP — the wedged case KeepAlive cannot detect,
    # since launchd only sees that the process still exists.
    printf 'running (pid %s, CDP NOT RESPONDING)' "$pid"
  fi
}

render_browser_profile() {
  sed -e "s|__HOME__|${HOME}|g" \
      -e "s|__VAULT__|${VAULT}|g" \
      -e "s|__LOGDIR__|${HOME}/.claude-sbx|g" \
      "${BROWSER_PROFILE_TEMPLATE}"
}

label_for()   { printf '%s.%s' "${LABEL_PREFIX}" "$1"; }
plist_for()   { printf '%s/%s.plist' "${PLIST_DIR}" "$(label_for "$1")"; }
profile_for() { printf '%s/sbx-agent-%s.sb' "${GEN_DIR}" "$1"; }
session_for() { printf 'sbx-agent-%s' "$1"; }

is_loaded_label() { launchctl print "${GUI_DOMAIN}/$1" &>/dev/null; }
is_loaded()       { is_loaded_label "$(label_for "$1")"; }

# Is the agent's claude process actually alive? There's no container to query,
# so match the remote-control session name on the command line.
agent_pid() { pgrep -f -- "--remote-control $(session_for "$1")" 2>/dev/null | head -1; }

agent_state() {
  local pid; pid="$(agent_pid "$1")"
  if [ -n "$pid" ]; then printf 'running (pid %s)' "$pid"; else printf 'absent'; fi
}

# Render the Seatbelt profile from its template. Paths are substituted rather
# than hardcoded so this isn't tied to one username, and so the log directory
# stays in sync with the fleet config above.
render_profile() {
  local n="$1"
  sed -e "s|__HOME__|${HOME}|g" \
      -e "s|__VAULT__|${VAULT}|g" \
      -e "s|__LOGDIR__|${HOME}/.claude-sbx|g" \
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

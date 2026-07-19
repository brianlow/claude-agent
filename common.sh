#!/usr/bin/env bash
# common.sh — shared config + helpers for the agent fleet.
# SOURCE this file; do not execute it. It deliberately does NOT set
# `set -euo pipefail` so it can't alter a caller's shell options.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS=(1 2 3 4 5)
LABEL_PREFIX="com.brianlow.claude-agent"
IMAGE="claude-code:latest"
LOG_DIR="${HOME}/.claude-agent/logs"
PLIST_DIR="${REPO_DIR}/launchd"
GUI_DOMAIN="gui/$(id -u)"
VAULT="${HOME}/Library/Mobile Documents/iCloud~md~obsidian/Documents/Brian's Vault"
BEAR_DIR="${HOME}/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data"

# Remote-reset feature: a launchd poller watches SENTINEL's mtime and, when it
# changes, recycles the whole fleet. SENTINEL is a note inside the iCloud vault,
# so editing it from Obsidian mobile (→ iCloud → this Mac) is the remote trigger.
WATCHER_LABEL="${LABEL_PREFIX}.reset-watcher"
SENTINEL="${VAULT}/Fleet Reset.md"
RESET_STATE="${HOME}/.claude-agent/reset-last-seen"

# launchd jobs inherit a minimal PATH; make binaries resolvable everywhere.
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

label_for() { printf '%s.%s' "${LABEL_PREFIX}" "$1"; }
plist_for() { printf '%s/%s.plist' "${PLIST_DIR}" "$(label_for "$1")"; }
watcher_plist() { printf '%s/%s.plist' "${PLIST_DIR}" "${WATCHER_LABEL}"; }

is_loaded_label() { launchctl print "${GUI_DOMAIN}/$1" &>/dev/null; }
is_loaded() { is_loaded_label "$(label_for "$1")"; }

container_state() {
  local state
  state="$(container list --all --format json 2>/dev/null \
    | jq -r --arg id "agent-$1" '.[] | select(.configuration.id==$id) | .status' 2>/dev/null)"
  printf '%s' "${state:-absent}"
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
        <string>${REPO_DIR}/agent-run.sh</string>
        <string>${n}</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>30</integer>
    <key>WorkingDirectory</key><string>${REPO_DIR}</string>
    <key>StandardOutPath</key><string>${log}</string>
    <key>StandardErrorPath</key><string>${log}</string>
</dict>
</plist>
PLIST
}

render_watcher_plist() {
  local log="${LOG_DIR}/reset-watcher.log"
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${WATCHER_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${REPO_DIR}/reset-watcher.sh</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>15</integer>
    <key>WorkingDirectory</key><string>${REPO_DIR}</string>
    <key>StandardOutPath</key><string>${log}</string>
    <key>StandardErrorPath</key><string>${log}</string>
</dict>
</plist>
PLIST
}

print_status() {
  printf '%-9s %-12s %s\n' "AGENT" "LAUNCHD" "CONTAINER"
  local n l
  for n in "${AGENTS[@]}"; do
    if is_loaded "$n"; then l="loaded"; else l="not loaded"; fi
    printf '%-9s %-12s %s\n' "agent-${n}" "$l" "$(container_state "$n")"
  done
  if is_loaded_label "${WATCHER_LABEL}"; then l="loaded"; else l="not loaded"; fi
  printf '%-9s %-12s %s\n' "watcher" "$l" "-"
}

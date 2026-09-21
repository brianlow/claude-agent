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

# The fleet's own ~/.claude. Deliberately NOT the host's: that directory holds
# settings.json (hooks, statusLine) and the ccline binary, all of which the host
# `claude` executes. Mounting it read-write let any agent — or anything that
# talked one into it, e.g. a poisoned vault note — plant a command that runs on
# the Mac, outside every container. Seeded from the host at each launch by
# agent-run.sh; see seed_fleet_claude_home().
FLEET_CLAUDE_HOME="${HOME}/.claude-agent/claude-home"

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

# Populate ${FLEET_CLAUDE_HOME} from the host's ~/.claude. Copies only what the
# agents need to start: settings, the statusline binary, and plugins — the
# credential is seed_fleet_credentials()'s job, from the keychain rather than
# from here. Everything the agents *write* — projects/, history.jsonl,
# file-history/, shell-snapshots/ — stays in the fleet home and never touches
# the host copy, so host session transcripts aren't exposed either.
#
# Re-run on every launch, so the executable bits are also *repaired* each restart:
# if an agent ever rewrote settings.json or ccline, the next relaunch (launchd
# KeepAlive, ≤30s) overwrites it from the host original.
seed_fleet_claude_home() {
  mkdir -p "${FLEET_CLAUDE_HOME}"
  chmod 700 "${FLEET_CLAUDE_HOME}"

  # Directories the host owns: mirror exactly (--delete removes agent additions).
  local d
  for d in plugins ccline; do
    [ -d "${HOME}/.claude/${d}" ] || continue
    rsync -a --delete "${HOME}/.claude/${d}/" "${FLEET_CLAUDE_HOME}/${d}/"
  done

  # Flat files the host owns.
  #
  # .credentials.json is deliberately NOT in this list. The host's copy is a
  # HUSK on this machine (empty tokens, epoch expiry — that is what Claude Code
  # writes when a credential is revoked), and copying it clobbers the real token
  # that seed_fleet_credentials() writes from the keychain. That function owns
  # this one file; nothing else may touch it.
  local f
  for f in settings.json statusline-ps1.sh; do
    [ -f "${HOME}/.claude/${f}" ] || continue
    cp -p "${HOME}/.claude/${f}" "${FLEET_CLAUDE_HOME}/${f}"
  done

  # entrypoint.sh links this to ~/.claude.json inside the container; it also
  # writes to it (trust prompt, MCP registration), which is why it's a copy.
  [ -f "${HOME}/.claude.json" ] && cp -p "${HOME}/.claude.json" "${FLEET_CLAUDE_HOME}/.claude.json"
  return 0
}

# Give the fleet a usable file credential, read from the host KEYCHAIN.
#
# The host's ~/.claude/.credentials.json is a husk here (empty tokens, epoch
# expiry); the live OAuth token lives in the keychain item. Copying the file —
# which is what this fleet used to do — seeds an expired credential with nothing
# to refresh from, and every agent comes up "Not logged in". It was invisible
# historically only because KeepAlive restarted agents often enough to re-seed.
#
# Containers have no keychain, and Claude Code needs a credential STORE rather
# than the keychain specifically: it falls back to ~/.claude/.credentials.json
# when the keychain is unreachable. So read the item here on the host and write
# it into the fleet home, which is mounted at /home/user/.claude.
#
# 0600 inside a 0700 fleet home. This is a plaintext refresh token on disk,
# which is worse at rest than the keychain and far better in blast radius than
# granting a container the host keychain.
#
# KNOWN: the fleet holds a COPY of the host's OAuth grant, and refreshing
# rotates the refresh token — whichever side refreshes second is revoked. The
# fix is the fleet having its own login or an ANTHROPIC_API_KEY, not a better
# copy. Touch ~/.claude-agent/no-seed to stop seeding once it does.
# The fleet's OWN long-lived token, from `claude setup-token`, kept in its own
# keychain item so it never lands in this repo.
#
# WHY A SEPARATE CREDENTIAL AT ALL. A copy of the host's OAuth grant collides,
# and not only with the host: all five agents share one ${FLEET_CLAUDE_HOME},
# so they share one .credentials.json. Each refreshes independently and every
# refresh ROTATES the refresh token, so the first agent to refresh revokes the
# other four, whose in-memory copies are now stale. Measured 2026-09-20: seeded
# a live token at 10:26, and by 20:44 the fleet file was a husk (empty tokens,
# epoch expiry) while the host keychain held a different token entirely.
#
# So a second Claude ACCOUNT does not fix this — five agents on one grant
# collide whoever owns the grant. What fixes it is a credential that never
# refreshes. `claude setup-token` mints one against the existing subscription,
# with no metered API billing and nothing to rotate.
#
# Install it (interactive, opens a browser — run it yourself, and note the
# token never needs to be pasted anywhere but this one command):
#
#   claude setup-token
#   security add-generic-password -U -s "${FLEET_TOKEN_SERVICE}" -a "$USER" -w
#
# Remove it, to fall back to seeding from the host keychain:
#
#   security delete-generic-password -s "${FLEET_TOKEN_SERVICE}"
FLEET_TOKEN_SERVICE="claude-agent-fleet-token"

fleet_oauth_token() {
  security find-generic-password -s "${FLEET_TOKEN_SERVICE}" -w 2>/dev/null
}

seed_fleet_credentials() {
  local dest="${FLEET_CLAUDE_HOME}/.credentials.json"
  local no_seed="${HOME}/.claude-agent/no-seed"
  local token

  # A fleet token supersedes seeding entirely, and implies it rather than
  # needing the no-seed file alongside — a half-configured fleet (own token,
  # seeding still on) would put it straight back on the host's grant at the
  # next launch. Drop the stale file too, so there is exactly one credential
  # in play and "no credential" fails loudly instead of ambiguously.
  if [ -n "$(fleet_oauth_token)" ]; then
    rm -f "${dest}"
    echo "seed_fleet_credentials: fleet has its own token (${FLEET_TOKEN_SERVICE}) — not seeding from the host" >&2
    return 0
  fi

  if [ -e "${no_seed}" ]; then
    echo "seed_fleet_credentials: ${no_seed} present — leaving the fleet's own credential alone" >&2
    return 0
  fi

  token="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null)" || {
    echo "WARNING: no 'Claude Code-credentials' in the host keychain — agents will not authenticate" >&2
    return 0
  }

  # Reject a husk rather than overwrite a working fleet credential with it.
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

# launchctl bootstrap only queues the job; agent-run.sh then has to tear down the
# stale container and start a new one. Poll until every agent is running so the
# status table reflects the settled state, not a snapshot taken mid-launch.
wait_for_agents() {
  local deadline=$((SECONDS + ${1:-45})) n all_up
  while ((SECONDS < deadline)); do
    all_up=true
    for n in "${AGENTS[@]}"; do
      [[ "$(container_state "$n")" == "running" ]] || { all_up=false; break; }
    done
    $all_up && return 0
    sleep 2
  done
  return 1
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

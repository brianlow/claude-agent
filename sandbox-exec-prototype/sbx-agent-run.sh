#!/usr/bin/env bash
# sbx-agent-run.sh <N> — run one sandboxed agent (sbx-agent-N) in the
# foreground. Executed by launchd (KeepAlive), so any exit triggers a restart.
#
# Structure, outermost first:
#
#   launchd
#     └─ caffeinate -dims        keep the Mac awake while an agent is live
#        └─ sandbox-exec -f ...  KERNEL BOUNDARY — everything below is confined
#           └─ pty-run.py        pty with a real window size, kept open
#              └─ claude --remote-control
#
# sandbox-exec sits above claude, not inside it, which is the entire point:
# nothing below that line can widen the policy, including claude itself.
#
# claude itself runs fully unrestricted at the app layer — permissions bypassed
# AND its own sandbox off (see the --settings install below). That's deliberate:
# one boundary, in the kernel, where the session operator can't reach it.
#
# Why pty-run.py instead of `script -q /dev/null`: `script` is fine from an
# interactive terminal, but fails two ways under launchd.
#
#   1. It sizes the pty from its own stdin. launchd gives it no terminal, so
#      the pty comes up 0 rows x 0 columns and the TUI hangs on it — silently.
#      No error, no output, no debug file; just a wedged process that KeepAlive
#      faithfully keeps alive. Confirmed with `stty -a -f <pty>`.
#   2. It exits the moment stdin hits EOF, which under launchd is immediate.
#
# The container fleet hit neither, because `container run --tty` allocates a
# properly-sized pty and doesn't propagate EOF that way.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/sbx-common.sh"

N="${1:?usage: sbx-agent-run.sh <N>}"
SESSION="$(session_for "$N")"
PROFILE="$(profile_for "$N")"
DEBUG_LOG="${LOG_DIR}/agent-${N}-debug.log"
PTY_RUN="${HOME}/.claude-sbx/pty-run.py"
SETTINGS="${HOME}/.claude-sbx/settings.json"
AB_CONFIG="${HOME}/.claude-sbx/agent-browser.json"

mkdir -p "${LOG_DIR}" "${GEN_DIR}"

# The TUI needs a usable TERM. Without one, claude starts, allocates a few MB,
# then hangs before it opens its debug log or reaches the bridge — no error, no
# output, just a wedged process that KeepAlive happily keeps alive.
#
# Set unconditionally, NOT with ${TERM:-...}. launchd itself provides no TERM,
# but `launchctl bootstrap` passes the *calling* shell's environment into the
# job, so whatever terminal happened to run sbx-start.sh leaks in. A caller
# with TERM=dumb (any non-interactive harness, CI, or an agent's own shell)
# would otherwise hand the agent a TERM it can't render to — the same hang,
# but only for some callers, which is far worse to debug.
export TERM=xterm-256color
export COLORTERM=truecolor

# The fleet's own HOME — this is what makes every writable grant in the profile
# land outside the human's home directory. The host's ~/.claude holds two things
# the HOST's claude executes unsandboxed (settings.json hooks, ccline/ccline),
# so a writable path to it was an escape that never had to break out of the
# sandbox at all. It is now denied outright in the profile.
#
# seed_fleet_home runs FIRST and on EVERY launch: it repopulates the fleet home
# from the host one-way, so anything an agent rewrote is repaired here. Combined
# with KeepAlive that bounds tampering to one restart (<=30s).
#
# ORDERING, all three load-bearing:
#   - PTY_RUN / SETTINGS / AB_CONFIG (above) are ${HOME}-relative and must stay
#     ABOVE this export. They are the agent's INPUTS, installed fresh by the
#     host side of this script into the real ~/.claude-sbx.
#   - The `source` of sbx-common.sh must stay above it too: CLAUDE_BIN, VAULT,
#     LOG_DIR are expanded at source time and would otherwise move.
#   - render_profile is called BELOW it and is NOT protected by either, because
#     a $HOME inside a function body expands at call time. That is why it uses
#     HOST_HOME internally. Do not "simplify" it back to $HOME.
#
# seed_fleet_credentials must run AFTER seed_fleet_home (which creates
# ${FLEET_HOME}/.claude) and BEFORE the export (it reads the HOST keychain, and
# the login keychain is located relative to $HOME — reversing these two lines
# means it finds no keychain and the fleet comes up "Not logged in").
seed_fleet_home
seed_fleet_credentials
export HOME="${FLEET_HOME}"

# Re-render the profile on every launch so an edit to the template takes effect
# on restart, and a hand-edit of the generated file never silently persists.
render_profile "$N" > "${PROFILE}"

# pty-run.py runs *inside* the sandbox, so it has to live somewhere the profile
# allows reading. The prototype directory deliberately isn't such a place any
# more (~/dev is fully denied), so install a copy into the fleet's runtime dir
# on every launch — which also keeps it in sync with the source.
install -m 0755 "${SCRIPT_DIR}/pty-run.py" "${PTY_RUN}"

# Turn Claude Code's own in-app sandbox OFF for fleet agents. Same reason the
# file has to live here rather than in the repo: ~/dev is denied.
#
# The user's global ~/.claude/settings.json sets sandbox.enabled = true with
# denyRead ["/", "~/"] / allowRead ["~/dev"], which the agent inherits. Under
# sandbox-exec that layer is worse than redundant:
#
#   - it's the *app's* boundary, and this whole prototype exists because an
#     in-app boundary can be talked out of by a hostile session operator. The
#     kernel one below already covers everything it covers, and more (~/dev is
#     allowed by Claude's policy and denied by ours).
#   - it forces dangerouslyDisableSandbox — and so a permission round-trip — on
#     every command that touches an allow-listed path like Bear.
#   - both layers return an identical "Operation not permitted", so having two
#     of them makes denials unattributable. That cost is documented: NOTES.md's
#     criterion-#3 section needed a dedicated discriminator (~/dev) to tell the
#     layers apart, and a later in-session test misread Seatbelt denials as TCC.
#
# --settings takes precedence over the user settings file (verified: the same
# `ls ~/Documents` that returns EPERM without it lists the directory with it).
install -m 0644 "${SCRIPT_DIR}/sbx-settings.json" "${SETTINGS}"

# Point agent-browser at the browser sandbox's CDP port, so the agent doesn't
# have to know it exists — `agent-browser open <url>` just works and lands in
# the sandboxed CloakBrowser.
#
# Via AGENT_BROWSER_CONFIG rather than ~/.agent-browser/config.json, which is
# shared with whatever the human runs on the host: the fleet should not silently
# repoint an interactive agent-browser at the fleet's browser.
#
# Note what this does NOT do: it gives the agent no way to *launch* a browser.
# That's the design. Without a reachable CDP port, agent-browser falls back to
# auto-launching /Applications/Google Chrome, and the profile denies it —
#   Failed to launch Chrome at "/Applications/Google Chrome.app/...":
#   Operation not permitted (os error 1)
# — so a wedged browser job degrades to "no browser", never to "an unconfined
# browser outside the sandbox".
install -m 0644 "${SCRIPT_DIR}/sbx-agent-browser.json" "${AB_CONFIG}"
export AGENT_BROWSER_CONFIG="${AB_CONFIG}"

# --- session continuity ------------------------------------------------------
# Restarts are ROUTINE for this fleet: the bridge watcher recycles on credential
# rotation ~2-3x/day, and each one used to discard whatever the agent was
# working on. Resuming a stable per-agent session makes a recycle cost a few
# seconds instead of the conversation.
#
# --session-id on first run, --resume afterwards. Not `--continue`: all five
# agents share one cwd, so "the most recent conversation here" is whichever
# agent wrote last, and they would resume each other's work.
SESSION_UUID="$(agent_session_uuid "$N")"
RESUME_ARGS=(--session-id "${SESSION_UUID}")
if agent_transcript_exists "${SESSION_UUID}"; then
  RESUME_ARGS=(--resume "${SESSION_UUID}")
fi

# A rename in the desktop app is the human labelling what an agent is FOR, so
# losing it on recycle is losing information. The watcher records it; replay it
# here. Empty/missing means the derived default, which is correct for a fresh
# agent.
NAME_ARGS=()
_saved_name="$(cat "$(agent_name_file "$N")" 2>/dev/null || true)"
[ -n "${_saved_name}" ] && NAME_ARGS=(-n "${_saved_name}")

[ -x "${CLAUDE_BIN}" ] || { echo "claude not executable at ${CLAUDE_BIN}" >&2; exit 1; }
[ -d "${VAULT}" ]      || { echo "vault not found at ${VAULT}" >&2; exit 1; }

# Fail fast and loudly if the profile doesn't compile. Without this a syntax
# error would surface as a confusing claude failure, and KeepAlive would spin
# on it every 30s.
if ! sandbox-exec -f "${PROFILE}" /usr/bin/true 2>/dev/null; then
  echo "FATAL: profile ${PROFILE} failed to compile:" >&2
  sandbox-exec -f "${PROFILE}" /usr/bin/true 2>&1 | head -5 >&2
  exit 1
fi

echo "$(date '+%Y-%m-%dT%H:%M:%S') starting ${SESSION}"
echo "  profile : ${PROFILE}"
echo "  home    : ${HOME} (fleet; host ~/.claude is denied)"
echo "  session : ${RESUME_ARGS[0]} ${SESSION_UUID}${_saved_name:+ (name: ${_saved_name})}"
echo "  workdir : ${VAULT}"
echo "  claude  : ${CLAUDE_BIN} ($("${CLAUDE_BIN}" --version 2>/dev/null || echo '?'))"
echo "  settings: ${SETTINGS} (in-app sandbox off)"
echo "  node    : $(command -v node || echo 'NOT ON PATH')"
echo "  browser : CDP 127.0.0.1:${BROWSER_CDP_PORT} (via ${AB_CONFIG})"
echo "  debug   : ${DEBUG_LOG}"

cd "${VAULT}"
exec caffeinate -dims \
  sandbox-exec -f "${PROFILE}" \
  /usr/bin/python3 "${PTY_RUN}" 120 40 \
  "${CLAUDE_BIN}" \
    --settings "${SETTINGS}" \
    --dangerously-skip-permissions \
    --permission-mode bypassPermissions \
    "${RESUME_ARGS[@]}" \
    ${NAME_ARGS[@]+"${NAME_ARGS[@]}"} \
    --remote-control "${SESSION}" \
    --debug \
    --debug-file "${DEBUG_LOG}"

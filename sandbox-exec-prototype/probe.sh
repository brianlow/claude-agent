#!/usr/bin/env bash
# Fast Phase 1 iteration loop: run a short non-interactive `claude -p` under a
# profile and report every Seatbelt denial it produced.
#
#   ./probe.sh <profile.sb> [prompt] [workdir]
#
# Why `-p` and not `--remote-control`: it exercises the same startup path
# (dyld, config/cache I/O, subprocess spawn, network) without needing
# --dangerously-skip-permissions, so it can run unattended. The remote-control
# verification runs are separate and need a human to start them.
#
# Denials only show up in the *live* kernel log — `log show` after the fact
# doesn't carry them — so the stream has to be running before the process
# starts. Note `/usr/bin/log`: `log` is shadowed by a shell function in the
# user's zsh profile.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROFILE="${1:?usage: probe.sh <profile.sb> [prompt] [workdir]}"
PROMPT="${2:-Reply with exactly: SANDBOX_PROBE_OK}"
WORKDIR="${3:-$HERE/scratch}"

[ -f "$PROFILE" ] || PROFILE="$HERE/profiles/$PROFILE"
PROFILE="$(cd "$(dirname "$PROFILE")" && pwd)/$(basename "$PROFILE")"

CLAUDE="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
mkdir -p "$WORKDIR" "$HERE/logs"
STREAM="$HERE/logs/denials-$(basename "$PROFILE" .sb).txt"

/usr/bin/log stream --style syslog \
  --predicate 'eventMessage contains "deny("' >"$STREAM" 2>&1 &
LPID=$!
cleanup() { kill "$LPID" 2>/dev/null || true; }
trap cleanup EXIT
sleep 2   # let the stream attach before anything runs

echo "=== profile: $(basename "$PROFILE")"
set +e
OUT="$(cd "$WORKDIR" && sandbox-exec -f "$PROFILE" "$CLAUDE" -p "$PROMPT" 2>&1)"
RC=$?
set -e
sleep 2   # let trailing denials flush

echo "--- exit=$RC"
echo "$OUT" | head -25

# The kernel log carries every sandboxed process on the machine, so filter to
# ours. Deny-list the known system noise rather than allow-listing our own
# process names: the Claude binary is a versioned file, so it shows up as
# `2.1.220`, not `claude` — an allow-list silently hides the denials that
# matter most.
echo "--- denials:"
grep -oE 'Sandbox: [A-Za-z0-9._-]+\([0-9]+\) deny\(1\) .*' "$STREAM" \
  | grep -vE 'Sandbox: (MessagesBlastDoorService|textcomposerd|modelmanagerd|mediaanalysisd|SafariBookmarksSyncAgent|com\.apple\.|Safari|Spotlight|mds|photoanalysisd|suggestd|parsecd|WeatherWidget|IMTransferAgent|AppleSpell|QuickLook|PerfPowerServices|routined)' \
  | sed -E 's/\([0-9]+\)//' | sort -u | head -40
echo "--- (full stream: $STREAM)"

exit $RC

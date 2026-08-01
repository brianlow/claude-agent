#!/usr/bin/env bash
# Wrap `claude --remote-control` in sandbox-exec with a given Seatbelt profile.
#
# Usage: ./run-test.sh <profile.sb> <session-name> [workdir]
#
# Debug log goes to logs/<session-name>.log. Everything stays under this
# prototype directory; nothing here touches the running Apple Container fleet.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROFILE="${1:?usage: run-test.sh <profile.sb> <session-name> [workdir]}"
SESSION="${2:?usage: run-test.sh <profile.sb> <session-name> [workdir]}"
WORKDIR="${3:-$HERE/scratch}"

# Accept either a bare profile name (00-allow-all.sb) or a path.
[ -f "$PROFILE" ] || PROFILE="$HERE/profiles/$PROFILE"
PROFILE="$(cd "$(dirname "$PROFILE")" && pwd)/$(basename "$PROFILE")"
[ -f "$PROFILE" ] || { echo "no such profile: $PROFILE" >&2; exit 1; }

# Plain Claude Code from the official installer — deliberately NOT the
# cmux-wrapped binary on PATH (/Applications/cmux.app/...), so this stays
# comparable to the container diagnostics.
CLAUDE="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
[ -x "$CLAUDE" ] || { echo "claude not executable at $CLAUDE" >&2; exit 1; }

mkdir -p "$HERE/logs" "$WORKDIR"
LOG="$HERE/logs/$SESSION.log"
: >"$LOG"

echo "profile : $PROFILE"
echo "session : $SESSION"
echo "workdir : $WORKDIR"
echo "claude  : $CLAUDE ($("$CLAUDE" --version 2>/dev/null || echo '?'))"
echo "log     : $LOG"
echo

cd "$WORKDIR"

# The TUI needs a pty. The container fleet gets one from `container run --tty`
# (no --interactive, since launchd attaches no stdin); `script -q /dev/null` is
# the native equivalent. sandbox-exec is outermost so the policy covers script,
# claude, and every child either of them forks.
exec sandbox-exec -f "$PROFILE" \
  /usr/bin/script -q /dev/null \
  "$CLAUDE" \
    --dangerously-skip-permissions \
    --permission-mode bypassPermissions \
    --remote-control "$SESSION" \
    --debug \
    --debug-file "$LOG"

#!/usr/bin/env bash
# Direct Chromium probe. Much faster than driving it through `claude -p` +
# the playwright MCP, and the denials are attributable to the browser rather
# than mixed in with Claude Code's own startup noise.
#
#   ./probe-chromium.sh <profile.sb>

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROFILE="${1:?usage: probe-chromium.sh <profile.sb>}"
[ -f "$PROFILE" ] || PROFILE="$HERE/profiles/$PROFILE"
PROFILE="$(cd "$(dirname "$PROFILE")" && pwd)/$(basename "$PROFILE")"

SHELL_BIN="/Users/brianlow/Library/Caches/ms-playwright/chromium_headless_shell-1194/chrome-mac/headless_shell"
STREAM="$HERE/logs/denials-chromium.txt"
mkdir -p "$HERE/logs" "$HERE/scratch"

/usr/bin/log stream --style syslog \
  --predicate 'eventMessage contains "deny("' >"$STREAM" 2>&1 &
LPID=$!
trap 'kill "$LPID" 2>/dev/null || true' EXIT
sleep 2

echo "=== chromium under $(basename "$PROFILE")"
OUT="$(cd "$HERE/scratch" && sandbox-exec -f "$PROFILE" "$SHELL_BIN" \
        --headless --disable-gpu --no-sandbox --dump-dom about:blank 2>&1)"
RC=$?
sleep 2

echo "--- exit=$RC"
echo "$OUT" | head -12
echo "--- denials:"
grep -oE 'Sandbox: [A-Za-z0-9._-]+\([0-9]+\) deny\(1\) .*' "$STREAM" \
  | grep -viE 'MessagesBlastDoor|textcomposerd|modelmanagerd|spotlightknowledged|mediaanalysisd|suggestd|parsecd|routined' \
  | sed -E 's/\([0-9]+\)//' | sort -u | head -40
exit $RC

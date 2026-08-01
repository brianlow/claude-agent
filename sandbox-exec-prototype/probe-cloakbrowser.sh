#!/usr/bin/env bash
# CloakBrowser (stealth Chromium fork) driven by agent-browser, under a profile.
#
#   ./probe-cloakbrowser.sh <profile.sb>
#
# Same shape as probe-chromium.sh, but exercises the pair we actually want in
# production rather than playwright's headless_shell: the `agent-browser` CLI
# (a native Rust binary) launching CloakBrowser's Chromium.app.
#
# Two deliberate differences from probe-chromium.sh:
#
#   - cwd is a scratch dir under /private/tmp, not ./scratch. The production
#     profile denies ~/dev outright, and node/chromium die at startup with
#     `EPERM ... uv_cwd` if cwd is unreadable — a failure that looks like a
#     tooling bug and isn't.
#   - agent-browser runs a *daemon*, so the sequence is open → get → close
#     rather than one-shot. Each invocation is separately sandbox-exec'd; the
#     daemon inherits the policy from whichever one spawned it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROFILE="${1:?usage: probe-cloakbrowser.sh <profile.sb>}"
[ -f "$PROFILE" ] || PROFILE="$HERE/profiles/$PROFILE"
PROFILE="$(cd "$(dirname "$PROFILE")" && pwd)/$(basename "$PROFILE")"

URL="${2:-https://example.com}"
STREAM="$HERE/logs/denials-cloakbrowser.txt"
WORK="/private/tmp/sbx-cloak-probe"
mkdir -p "$HERE/logs" "$WORK"

# The path cloakbrowser's own resolver reports, so this tracks binary updates.
CLOAK_BIN="$(cd "$WORK" && cloakbrowser info --json 2>/dev/null \
  | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["binaryPath"])' 2>/dev/null)"
[ -n "$CLOAK_BIN" ] || CLOAK_BIN="$(ls -d "$HOME"/.cloakbrowser/chromium-*/Chromium.app/Contents/MacOS/Chromium 2>/dev/null | tail -1)"
[ -x "$CLOAK_BIN" ] || { echo "cloakbrowser binary not found — run: cloakbrowser install" >&2; exit 1; }
export AGENT_BROWSER_EXECUTABLE_PATH="$CLOAK_BIN"

# --no-sandbox: Chromium's *internal* sandbox is itself Seatbelt-based, and
# Seatbelt does not nest — inside sandbox-exec the zygote can't issue its own
# sandbox extension and the browser dies before writing DevToolsActivePort:
#   deny(1) file-issue-extension ... extension-class:com.apple.app-sandbox.read
# The outer profile still confines every process in the tree; what's lost is
# Chromium's renderer/browser split, not our boundary. See NOTES.md.
export AGENT_BROWSER_ARGS="${AGENT_BROWSER_ARGS:---no-sandbox}"

echo "=== cloakbrowser: $CLOAK_BIN"
echo "=== profile:     $(basename "$PROFILE")"

# Denials only show up in the *live* stream — starting it after the fact gets
# nothing. See NOTES.md. /usr/bin/log because `log` is shadowed by a zsh func.
/usr/bin/log stream --style syslog \
  --predicate 'eventMessage contains "deny("' >"$STREAM" 2>&1 &
LPID=$!
trap 'kill "$LPID" 2>/dev/null || true' EXIT
sleep 2

# Never leave a daemon from a previous run behind — it would serve the next
# probe from *outside* the new profile and silently fake a pass.
(cd "$WORK" && agent-browser close --all >/dev/null 2>&1)

sbx() { (cd "$WORK" && sandbox-exec -f "$PROFILE" "$@"); }

echo "--- open $URL"
sbx agent-browser open "$URL" 2>&1 | tail -5
RC=$?
echo "--- get title"
sbx agent-browser get title 2>&1 | tail -3
echo "--- screenshot"
sbx agent-browser screenshot "$WORK/shot.png" 2>&1 | tail -3
ls -l "$WORK/shot.png" 2>/dev/null || echo "  (no screenshot written)"
echo "--- close"
sbx agent-browser close --all 2>&1 | tail -3

sleep 2
echo "--- denials:"
grep -oE 'Sandbox: [A-Za-z0-9._-]+\([0-9]+\) deny\(1\) .*' "$STREAM" \
  | grep -viE 'MessagesBlastDoor|textcomposerd|modelmanagerd|spotlightknowledged|mediaanalysisd|suggestd|parsecd|routined' \
  | sed -E 's/\([0-9]+\)//' | sort -u | head -60
exit $RC

#!/usr/bin/env bash
# sbx-status.sh — show launchd + process state of the sandbox-exec fleet.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/sbx-common.sh"

# WHY THIS SCRUBS, AND WHY IT TAILS THE DEBUG LOG RATHER THAN agent-N.log
#
# agent-N.log is the agent's stdout, and the agent is a full-screen TUI on a
# pty (pty-run.py) — so that file is a screen recording, not text. Its tail
# reliably contains ESC[?1049h (switch to the alternate screen), ESC[2J (clear
# screen), ESC[r (reset the scroll region) and ESC[?1000h/?1002h/?1003h/?1006h
# (enable mouse reporting). The previous `tail -1 ... | cut -c1-70` piped those
# straight at whoever ran this script: it cleared their terminal and left it in
# mouse-tracking mode, where every click emits garbage. `cut` compounded it by
# slicing mid-sequence, so a dangling ESC[ swallowed whatever printed next.
#
# agent-N-debug.log (--debug-file) is plain timestamped text, so that is the
# one worth showing. It is still scrubbed on the way out: nothing read out of
# a log should be able to drive the reader's terminal, and a debug line can
# quote agent or tool output verbatim.
#
# -l, not bare -p: the whitespace squeeze below would otherwise swallow each
# line's own trailing newline and print every record joined into one enormous
# line, so `tail -1` would return the whole file and the clip would show its
# oldest content. -l chomps on input and re-adds the newline on output.
scrub() {
  perl -CSD -lpe '
    s/\e\][^\a\e]*(?:\a|\e\\)//g;   # OSC — window title etc, ends BEL or ST
    s/\e\[[0-?]*[ -\/]*[@-~]//g;    # CSI — colour, cursor, screen + mouse modes
    s/\e[ -\/]*[0-~]//g;            # two-character escapes: ESC 7, ESC 8, ESC c
    s/[\x00-\x08\x0b-\x1f\x7f]//g;  # any remaining C0 control, notably CR
    s/\s+/ /g; s/^ //; s/ $//;
  '
}

# Last line of a log that carries any text, scrubbed and clipped to one row.
# Reads a bounded tail rather than the file: agent-N.log is megabytes, and a
# TUI log can hold very few newlines, so "one line" is not a bounded amount of
# data. Starting mid-line is fine — only the last line is used.
last_log_line() {
  tail -c 8192 "$1" 2>/dev/null | scrub | grep -v '^$' | tail -1 || true
}

print_status
echo
echo "logs: ${LOG_DIR}"
for n in "${AGENTS[@]}"; do
  log="${LOG_DIR}/agent-${n}-debug.log"
  [ -f "$log" ] || continue
  line="$(last_log_line "$log")"
  printf '  %-24s %s\n' "$(basename "$log")" "${line:0:78}"
done
browser_log="${LOG_DIR}/browser.log"
if [ -f "${browser_log}" ]; then
  line="$(last_log_line "${browser_log}")"
  printf '  %-24s %s\n' "$(basename "${browser_log}")" "${line:0:78}"
fi

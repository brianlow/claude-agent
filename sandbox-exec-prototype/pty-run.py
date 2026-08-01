#!/usr/bin/python3
"""pty-run.py <cols> <rows> <command> [args...]

Run a command on a pty that has a real window size, and keep it alive.

Replaces `script -q /dev/null` for the launchd fleet. `script` works fine from
an interactive terminal, but under launchd it fails two ways at once:

  1. It copies the pty window size from its own stdin. launchd gives it no
     terminal, so the pty comes up 0 rows x 0 columns and Claude Code's TUI
     hangs on it — no error, no output, a wedged process that KeepAlive keeps
     alive forever.
  2. It exits as soon as stdin hits EOF, which under launchd is immediate.

This sets the winsize explicitly before exec, and never closes the child's
stdin. It deliberately does NOT forward our stdin to the child: a remote-control
agent takes its input from the bridge, not from the terminal.

Runs INSIDE the sandbox (sandbox-exec is outermost), so it gets no privilege
the agent doesn't already have.
"""

import fcntl
import os
import pty
import signal
import struct
import sys
import termios


def main() -> int:
    if len(sys.argv) < 4:
        sys.stderr.write("usage: pty-run.py <cols> <rows> <command> [args...]\n")
        return 2

    cols, rows, argv = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3:]

    pid, master = pty.fork()
    if pid == 0:
        # Child: pty.fork() has already made the slave our controlling terminal
        # and wired it to fd 0/1/2.
        os.execvp(argv[0], argv)
        os._exit(127)  # only reached if exec fails

    # Parent. Set the window size the child will see. This is the whole point:
    # without it the TUI sees a 0x0 terminal.
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    # Pass signals through so `launchctl bootout` / KeepAlive stop the agent
    # cleanly instead of orphaning it.
    def forward(signum, _frame):
        try:
            os.kill(pid, signum)
        except ProcessLookupError:
            pass

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, forward)

    # Drain the child's output to our stdout, which launchd has pointed at the
    # agent log. Draining matters for more than logging: if nobody reads the
    # pty the child eventually blocks writing to it.
    while True:
        try:
            data = os.read(master, 65536)
        except OSError:
            break          # child closed the pty
        except InterruptedError:
            continue       # a forwarded signal interrupted the read
        if not data:
            break
        try:
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
        except BrokenPipeError:
            break

    _, status = os.waitpid(pid, 0)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return os.WEXITSTATUS(status)


if __name__ == "__main__":
    sys.exit(main())

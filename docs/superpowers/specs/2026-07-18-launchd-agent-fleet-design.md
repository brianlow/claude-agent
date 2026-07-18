# launchd Agent Fleet — Design

**Date:** 2026-07-18
**Status:** Approved (pending spec review)

## Problem

We run 5 Claude Code agents, each as an Apple Container (`agent-1`..`agent-5`)
running `claude --remote-control`. Today `run-claude.sh` starts **one** agent in
a foreground terminal, kept alive by a bash `while` loop (Ctrl-C to stop). Pain
points:

1. **No single start command.** Getting all 5 up means running the script in 5
   terminals.
2. **Post-reboot wedge.** After a reboot the `agent-N` containers still exist but
   are *stopped*; the slot-picker sees them in `container list --all` and refuses
   to start, so nothing comes up until they're manually removed.
3. **Supervision is tied to a terminal.** Crash recovery lives in a foreground
   bash loop, so it dies when the terminal closes.

## Goals

- **One command** brings all 5 agents up: `start-agents`.
- **Idempotent.** Running `start-agents` when some/all agents are already up is
  safe: it leaves running agents alone and brings up only the missing ones
  (self-healing). Same for `stop-agents` / re-runs.
- **Crash recovery** that survives terminal close, logout, and the supervisor
  itself — an agent that crashes or idle-times-out comes back automatically.
- **Reachable remotely** via the Claude desktop app (remote control). Fixed agent
  names → fixed, predictable remote-control session names.
- **Status output** on every command, plus a standalone status command.
- **No post-reboot wedge**, ever.

## Non-goals

- **No terminal/TTY access to agents.** Dropped by decision — all interaction is
  through the Claude desktop app's remote control. Agents run detached.
- **No auto-start at login.** Startup is a deliberate manual `start-agents`. The
  launchd jobs are *not* installed into `~/Library/LaunchAgents`, so they do not
  load at login.
- Not changing the container image, mounts, or `entrypoint.sh` behavior (remote
  control, keepalive, MCP registration) beyond what's needed for supervision.

## Approach: launchd, loaded on demand

Apple Container has **no `--restart` policy and no supervising daemon** (verified:
`container run` exposes only `-d/--detach`, `--rm`, `--name`, etc.). So crash
recovery must come from a host-side supervisor. We use **launchd** — the
macOS-native supervisor — as five per-agent jobs, but loaded on demand by
`start-agents` rather than auto-loaded at login.

Why launchd over backgrounded `nohup` loops: launchd restarts a job on *any*
exit (crash or clean idle-timeout) via `KeepAlive`, and launchd itself never
dies — supervision survives terminal close, logout, and OOM of any shell. A
backgrounded bash loop is an ordinary process that can be killed, ending
recovery. launchd's `ThrottleInterval` replaces the old "give up after N rapid
crashes" cap with retry-slowly-forever, which self-heals once a bad config is
fixed.

## Components

All new files live in the `claude-agent` repo.

### 1. `agent-run.sh <N>` — per-agent wrapper (what launchd executes)

The single source of truth for how one agent runs. Steps:

1. Set an explicit `PATH` (launchd jobs get a minimal environment) so
   `container`, `caffeinate`, `cp`, `jq`, etc. resolve.
2. `container rm -f agent-N` — clears any stale/stopped container from a prior
   run or reboot. **This is what permanently kills the post-reboot wedge:** every
   launch starts from a clean slot.
3. Do the same host-side prep the current script does (sync gcalcli oauth, stash
   `~/.claude.json` into `~/.claude/`) so a fresh container is correctly
   configured.
4. `exec caffeinate -dims container run --name agent-N --rm --tty
   --env AGENT_SESSION_NAME=agent-N <mounts…> <image>` — **foreground** (no
   `-d`), so launchd observes the process lifetime and restarts on exit.
   `caffeinate -dims` prevents sleep as today.

Runs in the foreground under launchd; `exec` so signals/lifetime map directly to
the container run.

### 2. launchd plists — `com.brianlow.claude-agent.<N>.plist` (N=1..5)

**Generated** by `start-agents` from a single template (DRY, absolute paths
baked in) into a repo-local dir (e.g. `./launchd/`), overwritten idempotently on
each start. Not placed in `~/Library/LaunchAgents` (no login auto-load). Key
settings:

- `Label`: `com.brianlow.claude-agent.<N>`
- `ProgramArguments`: `[<repo>/agent-run.sh, <N>]`
- `RunAtLoad`: `true` — starts immediately on bootstrap.
- `KeepAlive`: `true` — restart on any exit (crash or idle-timeout).
- `ThrottleInterval`: `30` — min seconds between restarts; prevents hammering,
  retries forever.
- `StandardOutPath` / `StandardErrorPath`: `~/.claude-agent/logs/agent-<N>.log`.
- `WorkingDirectory`: repo dir.

### 3. `start-agents.sh` — the one command

1. Ensure `container system` is running; ensure image exists (optional
   `--build`).
2. (Re)generate the 5 plists from the template.
3. For each N: if the job is already bootstrapped
   (`launchctl print gui/$UID/com.brianlow.claude-agent.N` succeeds), leave it;
   else `launchctl bootstrap gui/$UID <plist>`. → **idempotent + self-healing**.
4. Print the status table (see §5).

### 4. `stop-agents.sh`

1. For each N: `launchctl bootout gui/$UID/com.brianlow.claude-agent.N` (ignore
   "not loaded"). Booting out removes the job so `KeepAlive` no longer restarts
   it.
2. `container rm -f agent-N` for each (agents are disposable).
3. Print status.

### 5. `agents-status.sh` — status table (shared function)

Per agent, one row: **launchd** (loaded / not loaded) and **container**
(running / stopped / absent), sourced from `launchctl print` and
`container list`. Called at the end of start/stop and runnable standalone.
Example:

```
AGENT     LAUNCHD      CONTAINER
agent-1   loaded       running
agent-2   loaded       running
agent-3   not loaded   absent
...
```

## Data / control flow

```
start-agents ──generates──> 5 plists
     │
     └─ launchctl bootstrap ──> launchd (per agent, persistent)
                                   │  KeepAlive + ThrottleInterval
                                   └─ runs agent-run.sh N
                                        ├─ container rm -f agent-N   (clean slot)
                                        └─ exec caffeinate container run --name agent-N …
                                              │  claude --remote-control agent-N
                                              └─ on exit ──> launchd restarts (≥30s apart)

Desktop app ── remote control ──> agent-1 … agent-5   (fixed session names)
```

## Error handling

- **Reboot / stale container:** handled per-launch by `container rm -f agent-N`.
- **Crash / idle-timeout exit:** launchd `KeepAlive` restarts; `ThrottleInterval`
  paces retries.
- **Bad config crash-loop:** retries every 30s indefinitely (self-heals on fix)
  rather than giving up. Logs land in `~/.claude-agent/logs/agent-N.log`.
- **Double start:** idempotent check skips already-loaded jobs.
- **`container system` down:** `start-agents` starts it first; `agent-run.sh`
  assumes it is up (launchd will retry if a start races the system coming up).

## Risks / to verify during implementation

- **TTY under launchd.** `claude` is a TUI; under launchd there is no controlling
  terminal. We allocate a pty inside the container with `--tty`. Verify the TUI +
  remote control run cleanly with stdin as `/dev/null`; if not, add a pty shim.
- **Full Disk Access / TCC prompt.** Mounts point at protected locations (iCloud
  vault, Bear group container). FDA is already granted to the container runtime
  helper (per README); verify no interactive TCC prompt fires under launchd
  (there is no terminal to answer it). If it does, document the FDA grant for the
  launchd context.
- **launchd PATH/env.** Confirm `agent-run.sh`'s explicit `PATH` covers every
  binary it and the container CLI need.

## Retirement of old scripts

`run-claude.sh` (single foreground agent) and `remove-agents.sh` are superseded
by `start-agents.sh` / `stop-agents.sh` / `agents-status.sh`. Keep `run-claude.sh`
temporarily as a convenience for one-off interactive/terminal sessions, or remove
it — decide during implementation. `pick_container_name` slot logic is gone;
slots are fixed per launchd job.

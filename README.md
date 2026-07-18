This is a container for running Claude Code with remote session on

It is using Apple Container tech
https://github.com/apple/container

## Running the fleet (5 agents under launchd)

Agents run detached and are reached through the Claude desktop app (remote
control) — no terminal is attached. launchd (`KeepAlive`) restarts any agent
that crashes or idle-times-out. Startup is manual (no login auto-start).

```sh
./start-agents.sh          # bring all 5 up (idempotent; --build to rebuild image first)
./agents-status.sh         # show launchd + container state of each agent
./stop-agents.sh           # tear all 5 down (idempotent)
```

- Agents are `agent-1`..`agent-5`; the container name is also the remote-control
  session name shown in the desktop app.
- Idempotent: re-running `start-agents.sh` leaves running agents alone and brings
  up only missing ones (self-healing).
- After a reboot just run `./start-agents.sh` again — each launch does
  `container rm -f agent-N` first, so stale containers never wedge a slot.
- Logs: `~/.claude-agent/logs/agent-N.log`. Generated plists: `./launchd/`.
- Crash-loop protection: `ThrottleInterval=30` — launchd retries a failing agent
  every 30s indefinitely (self-heals once the cause is fixed).

`run-claude.sh` remains for one-off interactive/terminal sessions.

## Troubleshooting

### macOS "allow container to access files…" popup on every run

This is a macOS privacy (TCC) prompt, not something Apple Container controls. It
fires because the mounts point at protected locations — the Obsidian vault lives
in iCloud Drive (`~/Library/Mobile Documents/...`) and the Bear dir lives in
Group Containers (`~/Library/Group Containers/...`).

To stop the prompt, grant **Full Disk Access** (System Settings → Privacy &
Security → Full Disk Access) to:

- `/usr/local/bin/container` (the CLI)
- The per-VM runtime helper that actually performs the mounts:
  `/usr/local/libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux`
  (in the file picker press **⌘⇧G** and paste this path — `libexec` is hidden by
  default)
- Your terminal app (Terminal.app / iTerm / Ghostty / VS Code) — whichever you
  launch `run-claude.sh` from

Then quit and relaunch the terminal app (FDA only takes effect on process
restart), and restart the helper so it picks up the new grant:

```sh
container system stop && container system start
```

Notes:

- A prompt worded **"…would like to access data from other apps"** is the Group
  Containers TCC class — i.e. the Bear mount. If you don't need Bear, removing
  its `--mount …/bear` line from `run-claude.sh` also makes that prompt go away.
- Clicking "Allow" on the iCloud Drive variant of the prompt often doesn't
  stick — Full Disk Access is the reliable fix.


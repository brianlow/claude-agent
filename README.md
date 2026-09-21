This is a container for running Claude Code with remote session on

It is using Apple Container tech
https://github.com/apple/container

> **This fleet is the running one again, as of 2026-09-20.** It was mothballed
> because it could not pair with Remote Control —
> `Remote Control requires a claude.ai subscription`, which
> `sandbox-exec-prototype/` was built to route around by running agents as
> native macOS processes. **That blocker is gone.** On a subscription held
> directly with Anthropic rather than through the App Store, all five containers
> pair:
>
> ```
> Opus 4.8 (1M context) · Claude Pro
> /remote-control is active · Continue here, on your phone, or at
> https://claude.ai/code/session_…
> ```
>
> So `NOTES.md`'s conclusion that "the entitlement check is platform-based, not
> account-based" is wrong, or no longer holds. It was drawn from a single
> experiment that held `billingType: apple_subscription` constant and varied the
> platform; varying the billing type instead unblocks the container.
>
> The sandbox-exec fleet is **not running**; it stays in the tree as the better
> operational record. Three things it learned still apply here:
>
> - **The `~/.claude` seed used to copy a husk**, and that is why this fleet
>   reported `Not logged in`. `~/.claude/.credentials.json` on the host has
>   empty tokens — what Claude Code writes when a credential is revoked — while
>   the live token is in the keychain item. **Fixed:**
>   `seed_fleet_credentials()` reads the keychain and writes the file; the husk
>   is no longer copied over it. It used to work by accident, because agents
>   restarted often enough to re-seed a live token before anyone noticed.
> - **The fleet and you share one OAuth grant, and refreshing rotates it**, so
>   whichever side refreshes second is revoked (~2–3x/day, either direction).
>   Still true here. `./reset-agents.sh` repairs the fleet side; nothing stops
>   the fleet from revoking *you*. The real fix is the fleet having its own
>   login or an `ANTHROPIC_API_KEY` — touch `~/.claude-agent/no-seed` to stop
>   seeding once it does.
> - **`KeepAlive` cannot see a dead bridge** — the process does not exit, so
>   launchd thinks the job is healthy. `sandbox-exec-prototype/sbx-bridge-watcher.sh`
>   is the fix; this fleet still has no equivalent, and the `Fleet Reset.md`
>   note is the manual substitute.
>
> Two more ports worth making, both sandbox-exec-only today: **session resume**
> (a stable per-agent `--session-id`, so a restart costs seconds rather than the
> conversation) and **stripping `projects` from the seeded `.claude.json`**,
> which currently carries 16 host project paths into every container.
>
> Full write-up: `sandbox-exec-prototype/NOTES.md`, "Fleet HOME, credentials,
> and the OAuth collision".

## Running the fleet (5 agents under launchd)

Agents run detached and are reached through the Claude desktop app (remote
control) — no terminal is attached. launchd (`KeepAlive`) restarts any agent
that crashes or idle-times-out. Startup is manual (no login auto-start).

```sh
./start-agents.sh          # bring all 5 up + the reset watcher (idempotent; --build to rebuild image first)
./agents-status.sh         # show launchd + container state of each agent
./reset-agents.sh          # force-recycle all 5 now (removes containers; launchd relaunches)
./stop-agents.sh           # tear all 5 down + the watcher (idempotent)
./build.sh                 # rebuild the image without touching running agents
./prune-images.sh          # reclaim leaked snapshots/blobs (dry run; --yes to delete)
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

## Isolation

The agents run `--dangerously-skip-permissions` and Hermes has an unguarded
write path to the whole vault, so the container is the only thing standing
between an agent — or anything that talks one into it, e.g. a poisoned vault
note or a web page — and the Mac. Two host-side boundaries close the paths that
led back out of it.

**The fleet gets its own `~/.claude`.** Containers mount
`~/.claude-agent/claude-home`, not the host's `~/.claude`. The host directory
holds `settings.json` (hooks) and the `ccline` statusline binary, both of which
your *own* `claude` executes on launch — mounting it read-write meant an agent
could plant a command that runs on the Mac, outside every container. Read-only
isn't an option: Claude Code writes `history.jsonl`, `projects/`, and
`file-history/` continuously, and `entrypoint.sh` rewrites `.claude.json` on
every start.

`seed_fleet_claude_home()` (in `common.sh`) copies the host-owned pieces —
credentials, `settings.json`, `plugins/`, `ccline/` — into the fleet home at
every launch. So the flow is one-way, and because launchd relaunches within
30s, anything an agent rewrote gets repaired on the next start. Agent-written
state (sessions, transcripts) stays in the fleet home and never reaches yours;
your 87MB of host session history is no longer exposed to them either.

**Containers can't reach the home LAN.** Apple Container bridges every
container onto `192.168.64.0/24` and NATs it out, which also hands it the
router's admin page, the NAS, and the aquarium controller. `container run` has
no egress policy (only `--network` / `--dns`), so it's enforced on the host with
pf:

```sh
sudo ./lan-block.sh install    # load the anchor + a LaunchDaemon so it survives reboot
./lan-block.sh test            # probe LAN + internet from inside a live container
./lan-block.sh status          # pf state and the active rules
sudo ./lan-block.sh uninstall
```

Rules live in `pf/claude-agent.pf`: DNS to the bridge and container-to-container
traffic pass (the agents drive `sbx-browser` that way), everything else RFC1918
is dropped, and the public internet falls through untouched. To let agents reach
one LAN device again, add a `pass … to <ip>` line above the block rule and
re-run `install`.

Two things that will waste an hour if you don't know them:

**A full `pfctl -f /etc/pf.conf` silently kills container internet.** It reloads
the main ruleset, which discards the NAT rules Apple Container's vmnet service
installed at `container system start`. The symptom is misleading — DNS still
resolves (that's the bridge itself, not NAT) so it looks like a bad filter rule,
but every outbound connection dies. Recover with:

```sh
container system stop && container system start
./hermes/hermes-run.sh     # launchd restarts agent-1..5 on its own
```

`lan-block.sh` only does the full load on the *first* install; afterwards it
loads into the anchor alone (`pfctl -a claude-agent -f …`), which leaves NAT
alone — so editing rules later is non-disruptive. `test` reports `dns=ok`
alongside the probes precisely so this failure is identifiable.

**`/etc/pf.conf` is Apple's file** — a macOS update can replace it and silently
drop the anchor. `./lan-block.sh status` tells you; re-run `install` to fix.

## Remote reset (recover a hung agent from anywhere)

launchd auto-restarts an agent that *exits*, but not one that's wedged/hung while
still "running". The reset lever recycles the whole fleet on demand:

- **Locally / over SSH:** run `./reset-agents.sh`.
- **Remotely (from your phone):** edit and save the note **`Fleet Reset.md`** in
  the Obsidian vault. iCloud syncs it to the Mac; a launchd poller
  (`reset-watcher`, every 15s) notices the note's changed modification time and
  runs `reset-agents.sh`. This works even when every agent is wedged, since the
  trigger path is iCloud → filesystem, not through any agent.

How the trigger is debounced: it fires only on a modification-time **change of an
already-present note**. Merely *viewing* the note doesn't change it; the note
first appearing (or an undownloaded iCloud placeholder materializing) records a
baseline without firing — so startup never triggers a spurious reset. Baseline
state lives in `~/.claude-agent/reset-last-seen`; watcher log is
`~/.claude-agent/logs/reset-watcher.log`.

> One-time setup: create `Fleet Reset.md` in the vault once (it's self-documenting
> — see the vault's `CLAUDE.md`). After that, each save recycles the fleet.

## Disk usage

`~/Library/Application Support/com.apple.container` grows without bound, and
`container image prune` cannot stop it. Every `./build.sh` mints a new
`claude-code:latest` manifest digest, but `state.json` is a flat tag→digest map
— the old digest is *overwritten*, not left behind as a dangling `<none>`
image. Prune looks for dangling images, finds none, and exits happy while the
previous snapshot (~3.8GB) and its layers sit orphaned forever. This is why
`container system df` once reported 1.79GB reclaimable against 45GB of actual
garbage: it is blind to the leak. Seventeen builds had grown the directory to
95GB.

`./prune-images.sh` does the reachability walk the CLI won't: `state.json` →
index → manifest → config + layers, then deletes every snapshot dir and blob
the walk never reached. `build.sh` runs it with `--yes` after each build, so
the leak is collected at the moment it's created. Run it by hand any time —
it's a dry run unless you pass `--yes`.

The one thing it must never get wrong: `snapshots/` contains dirs that *no
image* references but *every container* mounts — `vminit` (the guest init
filesystem) and the BuildKit builder. Deleting those bricks every container on
the host. So there's a second root set, scraped from each container's
`runtime-configuration.json`, and a guard that refuses to prune at all if
`state.json` yields no reachable images. Both are covered by
`test/test-prune-images.sh`.

Two more sources worth knowing:

- **Multi-arch pulls unpack every platform.** Pulling a multi-arch image gives
  you an amd64 rootfs this Mac cannot execute — 3.1GB for hermes alone.
  `build.sh` exports `CONTAINER_DEFAULT_PLATFORM=linux/arm64` to stop it;
  `container image pull --platform linux/arm64` does the same by hand.
- **The BuildKit cache is unbounded** and has no prune subcommand. It reached
  7.6GB. `container builder delete` is the only lever; the builder restarts
  itself on the next build.

**Deleting files here may not free any space right away.** Time Machine local
APFS snapshots are whole-volume and block-level — taken *before* Time Machine
applies your exclusions — so a local snapshot pins every block you just freed,
even though this directory is excluded from backups. Deleting 76GB can move
`df` by zero. The space returns when the snapshot rotates (usually within 24h,
sooner under disk pressure), or immediately via:

```sh
tmutil listlocalsnapshots /
sudo tmutil deletelocalsnapshots com.apple.TimeMachine.<stamp>.local
```

Don't let a `df` right after a prune convince you the prune failed.

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
  launch `start-agents.sh` from

Then quit and relaunch the terminal app (FDA only takes effect on process
restart), and restart the helper so it picks up the new grant:

```sh
container system stop && container system start
```

Notes:

- A prompt worded **"…would like to access data from other apps"** is the Group
  Containers TCC class — i.e. the Bear mount. If you don't need Bear, removing
  its `--mount …/bear` line from `agent-run.sh` also makes that prompt go away.
- Clicking "Allow" on the iCloud Drive variant of the prompt often doesn't
  stick — Full Disk Access is the reliable fix.


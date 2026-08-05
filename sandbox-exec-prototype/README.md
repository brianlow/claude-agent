# The sandbox-exec fleet

Five Claude Code agents (`sbx-agent-1`..`5`) running as native macOS processes
under launchd, each confined by a Seatbelt profile the agent cannot lift, plus
one shared browser in a Linux container. Reached from the Claude desktop app's
Fleet view — no terminal attached.

This replaced the Apple Container fleet in the parent directory, which could not
pair with Remote Control at all. **That fleet is no longer running; the
top-level `README.md` still describes it.**

## Commands

```sh
./sbx-start.sh              # bring up 5 agents + browser + bridge watcher (idempotent)
./sbx-status.sh             # launchd + process state, and the tail of each log
./sbx-stop.sh               # tear it all down (idempotent)

./sbx-verify.sh             # 34 assertions about the AGENT sandbox
./sbx-verify-browser.sh     # 12 assertions about the BROWSER container
./sbx-verify-detection.sh   # bot-detection scores against the live browser
./test/test-sbx-bridge-watcher.sh   # 21 assertions about the bridge watcher
```

Logs are `~/.claude-sbx/logs/` — `agent-N-debug.log` is the readable one
(`agent-N.log` is the raw TUI screen recording, full of escape codes), plus
`bridge-watcher.log`, which stays empty while everything is converged.

Restart one wedged agent without touching the others:

```sh
launchctl kickstart -k gui/$(id -u)/com.brianlow.claude-sbx.3
```

Change the sandbox by editing `profiles/agent.sb.template`, then
`./sbx-verify.sh` (it renders and tests the profile without restarting
anything) and `launchctl kickstart -k …` to pick it up. Every agent re-renders
its profile from the template on launch, so a hand-edit of `generated/` never
survives.

## One-time setup

1. **Full Disk Access** — System Settings → Privacy & Security → Full Disk
   Access, for your terminal app *and* `~/.local/bin/claude`. Without it the
   vault (iCloud Drive) and Bear (Group Containers) are blocked by TCC, which
   `sandbox-exec` cannot grant back — it only ever subtracts. Note the TCC grant
   is keyed to Claude Code's versioned binary path, so **an update can silently
   drop vault access until you re-approve.**
2. **Apple Container** — <https://github.com/apple/container>, for the browser
   job. `sbx-start.sh` skips the browser with a warning if it is missing; the
   agents are useful without it.
3. **`agent-browser`** on `PATH`, if you want the browser driven from a session.
4. Claude Code at `~/.local/bin/claude` (the plain installer build, not a
   wrapped one), and the vault at the path in `sbx-common.sh`.

Nothing auto-starts at login. After a reboot, run `./sbx-start.sh`.

## How it works

```
launchd  (KeepAlive, ThrottleInterval=30)
  └─ caffeinate -dims          keep the Mac awake while an agent is live
     └─ sandbox-exec -f …      KERNEL BOUNDARY — nothing below can widen it
        └─ pty-run.py          a pty with a real window size, kept open
           └─ claude --remote-control sbx-agent-N   (cwd = the vault)
```

`sandbox-exec` sits *above* `claude`, not inside it. That is the entire point.
Claude Code's own `sandbox.enabled` is an in-app toggle, so anyone who gets into
a live remote-control session can talk the agent into turning it off — and the
threat model here is a hostile *operator of the session*, not just an agent
misbehaving on its own. So the agents run `--dangerously-skip-permissions` with
the in-app sandbox explicitly **off** (`sbx-settings.json`), leaving exactly one
boundary, in the kernel, where the session operator cannot reach it. Verified:
the denials survive `/sandbox` off.

What an agent can touch: the vault (rw), Bear (**read-only**, enforced twice),
`~/.gcalcli` (rw), and what Claude Code itself needs. Not `~/.ssh`, `~/.aws`,
`~/.gnupg`, `~/Documents`, `~/Desktop`, `~/dev`, or Messages. Three real escapes
were found and closed along the way — LaunchServices (`open -a Calculator`
worked, and launched an app entirely outside the sandbox), a GUI-capable
browser, and the host's `~/.claude` (below). The first two are written up in the
header of `profiles/agent.sb.template`; read it before adding any `mach-lookup`.

Network egress is **not** restricted (`allow network*`) — full internet is
wanted for research. The profile bounds what an agent can *reach on this Mac*,
not what it can *send off it*, so vault contents and gcalcli tokens remain
exfiltratable. Accepted deliberately.

### The fleet's own HOME

Agents run with `HOME=~/.claude-sbx/home`, not yours. This is not tidiness —
`~/.claude/settings.json` (hooks) and `~/.claude/ccline/ccline` (a binary) are
executed by **your** Claude Code, unsandboxed, on every launch, and both were
writable from inside the sandbox. That is an escape which never has to break out
of anything: an agent leaves a command on disk and the host runs it later, as
you. The host's `~/.claude`, `~/.claude.json` and `~/.npm` are now explicitly
denied, not merely un-granted.

`seed_fleet_home()` repopulates the fleet home from yours on **every** launch,
one-way, with `rsync --delete`. That is what makes it safe for the fleet's copy
to be writable: tampering has a shelf life of one restart. Your session
transcripts (`projects/`, `history.jsonl`, `sessions/` — 196MB) are deliberately
not copied. `sbx-verify.sh` sections `[5]`–`[8]` assert all of it, including
tampering with the fleet's `settings.json` and `ccline` and checking the seed
restores them byte-for-byte.

Two grants changed meaning as a bonus, both real: `~/.npm` is now fleet-private
(an agent could previously poison `_cacache` against your next `npm install`),
and `~/.agent-browser` is now fleet-private (your saved browser auth states were
readable).

### Auth and the bridge watcher

**There is no keychain in this profile.** The login keychain is located relative
to `$HOME`, so giving the fleet its own home made it unreachable regardless of
what the profile granted — the two changes are one change, not two.
`seed_fleet_credentials()` reads your keychain item and writes it to
`${FLEET_HOME}/.claude/.credentials.json` (0600 inside 0700) on every launch.
Claude Code needs a credential *store*, not the keychain specifically; verified
with the keychain and both `securityd` mach services denied.

**`sbx-bridge-watcher.sh`** polls every 60s and recycles agents, because
`KeepAlive` cannot: an agent whose remote-control bridge dies does **not exit**,
so launchd sees a healthy job (measured: 25 hours up and unreachable). It fires
on either credential drift from your keychain or a bridge-failure line newer
than the agent's process start. The restart is required, not cosmetic —
`.credentials.json` is read once at startup and cached, so writing the file
alone heals nothing until the process restarts.

```sh
tail -f ~/.claude-sbx/logs/bridge-watcher.log   # silence == everything converged
```

Expect it to act ~2–3 times a day. Why, and the two gotchas that cost a day —
locale-dependent `ps` output, and a monitor that reported "healthy" when it
meant "could not check" — are in `NOTES.md`, "Fleet HOME, credentials, and the
OAuth collision".

### The browser

`cloakhq/cloakbrowser:0.5.3` in an Apple container, published to
`127.0.0.1:9222`, driven by `agent-browser` over CDP. It is a container and not
a second Seatbelt profile because CloakBrowser needs LaunchServices and
WindowServer to run natively — precisely the grants that closed escape #1. A
second profile would have *moved* that escape, not deleted it; a Linux container
has neither service to grant.

launchd owns the browser's command line, not the agent: the image, the single
`--mount`, the `--publish` host address and cloakserve's flags are literal argv
in `sbx-browser-run.sh`, so a session operator cannot add `--allow-file-access`,
mount anything, load an extension, or move CDP off loopback. CDP has no auth, so
loopback *is* the security model — and no verb of it spawns a process. If the
browser job is wedged the failure mode is "no browser", never "an unconfined
browser": `agent-browser`'s fallback is to launch Google Chrome, and the agent's
profile denies that exec.

## Outstanding

**The fleet and you share one OAuth grant, and it rotates.** This is the live
one. The fleet holds a *copy* of your credential, and refreshing rotates the
refresh token, so whichever side refreshes second is revoked — roughly 2–3 times
a day. `sbx-bridge-watcher.sh` repairs the fleet side within 60s (see "Auth and
the bridge watcher" above), but it cannot stop the fleet from refreshing *first*
and revoking **you** — observed once, as an `auth failed` prompt on the Mac
needing `/login`. The real fix is giving the fleet its own credential: a second
Claude account, or an `ANTHROPIC_API_KEY` (keys never refresh, so the failure
mode disappears rather than being recovered from). Neither is done.

**Five agents share one browser, and steal each other's page.** One Chromium,
one device identity, one set of tabs. Tested: an agent can issue commands
against another agent's page and never see an error. Per-agent *tabs* were
tried and do not fix it — `agent-browser` follows the browser's newest target.
The mechanism that does work is cloakserve's per-seed multiplexer (one Chromium
per agent inside the one container); not built, and it needs a decision on
whether five device identities behind one IP is wanted. Full write-up in
`NOTES.md`.

**Five agents share one cwd**, the vault. Inherited from the container fleet,
not new here.

**No remote reset.** The container fleet's iCloud-note reset watcher is still
wired to `reset-agents.sh` in the parent directory; two watchers on one sentinel
would fight. A wedged agent needs `launchctl kickstart` over SSH today.

**Browser state is ephemeral.** Cookies and localStorage do not survive a
container restart, under either `--data-dir` or the `--user-data-dir` fallback
(both tested). The pinned fingerprint seed keeps the *device* stable across
restarts; it does not keep the *session*. Anything that depends on staying
logged in will silently log out when KeepAlive recycles the browser.

**Smaller ones.** `/private/tmp` is granted rw and is world-writable and shared
with every process on the Mac — worth narrowing to a private temp dir. The
fleet's `~/.credentials.json` is a plaintext refresh token on disk, which is
worse at rest than the keychain it replaced and far better in blast radius —
a deliberate trade. `~/Library/Caches/ms-playwright` is still the host's and
still writable, so an agent can rewrite a Chromium binary you later run; the fix
is a fleet-private playwright install. `claude → @playwright/mcp → browser` has never been driven from
inside a live session (it is an independent path from the CloakBrowser one:
Playwright drives `headless_shell` *inside* the agent sandbox). The vault's own
`Bear DB.md` still documents container-era mount paths. And `sandbox-exec` is
deprecated by Apple — an accepted risk for a personal project, not a blocker.

## Files

```
sbx-start.sh / sbx-stop.sh / sbx-status.sh    the fleet controls
sbx-verify*.sh                                the security assertions
sbx-bridge-watcher.sh                         60s poller: credential sync + recycle
sbx-common.sh                                 all fleet config; sourced by every script
sbx-agent-run.sh                              one agent, foreground — launchd invokes this
sbx-browser-run.sh                            the browser container — launchd invokes this
pty-run.py                                    pty with a real window size (replaces `script`)
sbx-settings.json                             installed as --settings; in-app sandbox off
sbx-agent-browser.json                        installed via AGENT_BROWSER_CONFIG; points at CDP
profiles/agent.sb.template                    THE SANDBOX. Read its header.
NOTES.md                                      the running log: findings, escapes, dead ends

generated/ launchd/ browser-profile/          runtime artifacts (gitignored)
```

Fleet runtime state lives outside the repo in `~/.claude-sbx/` — logs, and the
installed copies of `pty-run.py` and the two JSON configs.

`NOTES.md` is the archive of how this was built and what was tried; it is long,
chronological, and still the authoritative record of every finding. `PLAN.md`
and the numbered profile revisions `00`–`05` were deleted once the spike
finished — they are in git history if the iteration is ever worth re-reading.

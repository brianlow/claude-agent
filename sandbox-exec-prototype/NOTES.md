# Running log

## Setup deviations from PLAN.md

**Claude binary.** The plan says "plain npm-installed `claude`". There is no
npm-installed Claude Code on this host — `npm ls -g` shows only a placeholder
`claude-code@0.0.2`, not `@anthropic-ai/claude-code` (which is what the
container's Dockerfile installs). What's actually here:

| candidate | path | used? |
|---|---|---|
| cmux-wrapped | `/Applications/cmux.app/Contents/Resources/bin/claude` (first on PATH) | no — plan excludes it |
| official installer | `~/.local/bin/claude` → `~/.local/share/claude/versions/2.1.220` | **yes** |

`~/.local/bin/claude` is plain, unwrapped Claude Code 2.1.220, which satisfies
the intent of the constraint (not cmux). `run-test.sh` hardcodes it rather than
resolving `claude` from PATH, so the cmux binary can never be picked up by
accident. Override with `CLAUDE_BIN=` if we ever want to compare.

**pty.** `--remote-control` still runs the TUI, which needs a pty. The fleet
gets one from `container run --tty` (deliberately no `--interactive` — launchd
attaches no stdin). The native equivalent is `script -q /dev/null`, so
`run-test.sh` runs `sandbox-exec → script → claude`. sandbox-exec stays
outermost so the policy covers `script`, `claude`, and everything they fork.

**Data-safety guard in `00-allow-all.sb`.** The plan calls for a pure
`(allow default)` no-op. Ours is `(allow default)` plus an explicit
`(deny file-write*)` on the Obsidian vault and the Bear group container. The
plan already notes Phase 0 has *no* boundary at either layer
(`--dangerously-skip-permissions` + allow-all), and mitigates that with "run
from a scratch directory". This is the same mitigation, enforced by the kernel
instead of by convention. It cannot affect the Phase 0 exit criteria — dyld,
fork/exec, and the Fleet handshake don't write to either path. If Phase 0 ever
fails, re-test with those two lines removed before concluding anything.

## Verified before the first real run

Ran against `profiles/00-allow-all.sb` with `sandbox-exec`:

1. Profile compiles; `sandbox-exec -f ... /bin/echo` runs. → the mechanism
   itself works on this macOS build (Darwin 25.5.0), deprecation warnings
   notwithstanding.
2. Vault **read** still allowed (listed the vault root fine).
3. Vault **write** denied — `touch` failed `Operation not permitted`, no file
   created.
4. Bear group-container **write** denied — same.

Probe filenames were unique (`.sbx-probe-$$-DELETEME`) and confirmed
non-existent beforehand, so nothing could be overwritten. Both probes verified
absent afterward. **No data was written to the vault or to Bear at any point.**

This is a useful early signal beyond data safety: it shows `file-write*` subpath
denial is enforced against a child process of `sandbox-exec`, which is the
core mechanism Phase 1 depends on.

## Phase 0 — PASSED (2026-08-01)

Started by hand (see blocker below). Session `sandbox-diag-0` appeared in
Claude Desktop's Fleet view, and the debug log confirms a clean pairing:

```
05:23:20 [INFO]  Bridge URL: wss://bridge.claudeusercontent.com
05:23:21 [DEBUG] [remote-bridge] Created session cse_01ToeYhkWjY63yUApqLDiif1
05:23:21 [DEBUG] [remote-bridge] Fetched bridge credentials (expires_in=28800s)
05:23:21 [DEBUG] [remote-bridge] v2 transport connected
05:23:21 [DEBUG] [bridge:repl] handleStateChange state=connected
```

Grepping the log for `subscription|reject|denied|unauthoriz|forbidden|403`
returns **nothing**. The container-era failure
(`Remote Control requires a claude.ai subscription`) does not reproduce.

**This settles the plan's main open question.** Same account, same
`billingType: apple_subscription`, same CLI version, same bridge — a native
macOS process pairs, a Linux container does not. The entitlement check is
platform-based, not account-based. So the whole premise holds: running agents
as native processes sidesteps it, and `sandbox-exec` wrapping doesn't disturb
dyld, fork/exec, or the handshake.

Incidental finding, unrelated to sandboxing: the bridge warns
`no session-anchored default-branch evidence — omitting requested branch
'main'`, because the scratch cwd isn't a git repo. Harmless here; worth
remembering when this points at a real working directory
(`git remote set-head origin -a`).

### Blocker hit along the way (not a Phase 0 result)

Claude Code's own permission classifier refused to let the agent spawn
`run-test.sh`, because the command combines `--dangerously-skip-permissions`
with a sandbox-disabled Bash call. The refusal is correct — it's exactly the
"don't let the agent hand itself a boundaryless child process" property this
prototype is trying to move down to the OS layer — but it means every
`--remote-control` run needs a human to start it.

Consequence for Phase 1: iterate the profile with `claude -p '<prompt>'`
probes, which need none of the blocked flags and which the agent can run
itself. That exercises startup, config/cache I/O, subprocess spawning and
network — where essentially all the denials live. Only the *verification* runs
(steps 4 and 5 of the plan) actually need `--remote-control` and a human.

## Phase 1 — in progress

### Tooling

- `probe.sh <profile>` — runs `claude -p` under a profile, prints exit status
  and every Seatbelt denial. The fast loop.
- `verify.sh <profile>` — PLAN.md step 5. Asserts the security property with
  direct `sandbox-exec` probes: allow-list works, everything else denied.

Two instrumentation traps cost time; both are fixed, note them before
re-deriving:

1. **Denials only appear in the *live* kernel log.** `log show --start ...`
   after the fact returns nothing useful — the stream has to already be
   running when the process starts. `probe.sh` starts it 2s ahead.
2. **`log` is shadowed by a shell function in the user's zsh profile**
   (`too many arguments`). Use `/usr/bin/log`.

And one self-inflicted one: revision 01 originally carried
`(deny default (with no-log))`, which silenced the exact denials being hunted.
It reported a clean run while claude was failing to authenticate.

Also: the Claude binary is a *versioned file*, so it appears in the log as
`2.1.220`, not `claude`. An allow-list-by-process-name filter hides every
denial that matters. `probe.sh` deny-lists system noise instead.

### Revision log

| rev | change | result |
|---|---|---|
| 01 | `(deny default)` + `bsd.sb` + system exec/read, scratch cwd | Started first try — dyld and fork/exec fine. Failed at auth. |
| 02 | keychain (securityd mach-lookup + `user-preference-read`), `~/.claude.json.tmp.*`, `~/.local/state/claude`, git/node/npx exec | `SANDBOX_PROBE_OK`, exit 0 |
| 03 | target allow-list: vault rw, Bear **ro**, gcalcli rw, plus deny-backstops | works; **verify.sh found a real escape** |
| 04 | close LaunchServices hole; `~/.npm`; DNSConfiguration | works; verify.sh fail=0 |

`(import "bsd.sb")` is available on this machine and does a lot of the heavy
lifting — worth knowing before hand-writing syscall rules.

### Finding: LaunchServices is a second confused-deputy path

Revision 03 passed every filesystem test *and* both `osascript` tests, and
still failed the security property. `open -a Calculator` **succeeded** — a
real Calculator window opened on the desktop.

`open` doesn't run the app itself; it asks `launchservicesd` to, and
`launchservicesd` is outside the sandbox, so the app it launches is entirely
unconfined. Blocking Apple Events was necessary but **not sufficient**.

The cause was mine: `com.apple.coreservices.launchservicesd` and
`com.apple.lsd.mapdb` were in revision 01's mach-lookup list as speculative
"probably needed" entries — never justified by an actual denial. Removing them
closes the hole and Claude Code still runs fine (`node` does try
launchservicesd, gets denied, and doesn't care).

Generalisation worth carrying into the real profile: **an unexplained
mach-lookup grant is a potential escape, not a harmless convenience.** Every
name in that list should trace to an observed denial *and* a reason. This is
the concrete instance of the risk PLAN.md flagged — a profile that passes
every functional check while being wide open.

### Finding: Bear read-only is a TCC problem, not a Seatbelt one

Bear reads fail under the profile — and fail identically **without**
`sandbox-exec`. So this isn't the profile. Group Containers are TCC-protected,
TCC is a separate layer, and `sandbox-exec` can only ever *subtract*
permissions — it can't grant what the launching process doesn't already have.

Same issue the README documents for the container fleet ("would like to access
data from other apps"), reached by a different route. To read Bear natively,
whatever launches the agent needs Full Disk Access. That's a deployment
question for productionizing, not a profile fix; `verify.sh` now reports it as
`n/a` with attribution rather than a spurious FAIL.

Bear write-denial is verified working regardless, which is the direction that
matters for data safety.

### verify.sh against revision 04 — fail=0

Denied: `~/.ssh` read/list/write, `~/Documents`, `~/Desktop`, `~/dev`,
`/etc` write, `~/Library/Messages`, Bear writes (both the group container and
`Application Data`), `osascript`→Finder, `osascript`→System Events,
`open -a`.
Allowed as intended: vault read, vault write, `~/.gcalcli` read.

**No vault or Bear data was modified.** The one write-probe that is *supposed*
to succeed creates `.sbx-probe-$$-DELETEME` in the vault root, after checking
that path doesn't already exist, and deletes it immediately. Nothing existing
is ever opened for write, appended to, or truncated.

### Audit against the target allow-list (PLAN.md step 4)

Beyond the three target entries, revision 04 allows the following. Each is a
deliberate, named addition:

| grant | why | keep in production? |
|---|---|---|
| `~/.claude`, `~/.claude.json*`, `~/.cache/claude`, `~/.local/state/claude`, `~/Library/Caches/claude-cli-nodejs` | Claude Code's own config/cache/locks | yes |
| `~/Library/Keychains` rw | where the OAuth credential actually lives; auth fails without it | yes, **but see below** |
| `/opt/homebrew`, `~/.asdf` read+exec | git, node, npx | yes |
| `~/.npm` rw | npx-launched MCP servers | yes |
| `~/.gitconfig`, `~/.config/git` read | git identity | yes |
| `/private/tmp`, `/private/var/folders` rw | temp | yes (`/private/tmp` is shared and world-writable — worth revisiting) |
| `~/dev/claude-agent` read, `sandbox-exec-prototype` rw | **spike scaffolding only** | **no — drop** |
| `network*` | Phase 2 | open |
| `file-read-metadata` global | path resolution; metadata only, no contents | yes |

Two things to flag rather than quietly accept:

1. **Keychain access is the widest grant in the profile.** It's `~/Library/
   Keychains` read/write, i.e. the whole login keychain file, not just Claude's
   item. Item-level ACLs are enforced by `securityd`, so file access is not the
   same as reading every secret — but it is meaningfully broader than the
   target allow-list implies, and it is unavoidable for this auth mechanism.
   Worth an explicit decision when productionizing.
2. `~/.claude` is both writable and executable (needed for plugin hooks like
   `run-hook.cmd`). The agent can therefore write a script there and run it.
   That is **not** a sandbox escape — children inherit the policy — but it does
   mean the profile can't be relied on to control *what code runs*, only what
   that code can reach.

### Success criterion #3 — PROVEN: denial survives `/sandbox` off

Live remote-control session `sandbox-diag-1`, profile 04, cwd = the vault,
started by hand. With Claude Code's in-app sandbox **off**, twice:

```
! cat ~/.ssh/known_hosts
cat: /Users/brianlow/.ssh/known_hosts: Operation not permitted
```

Still denied. That is the property the prototype exists to demonstrate.

**Held as provisional, because the obvious reading is not proof.** Claude
Code's in-app sandbox is *itself* Seatbelt-based on macOS, so both layers
return an identical `Operation not permitted` — the error message alone
cannot attribute the denial. The session's own narration is not evidence
either: it explained that reads are denied "across `/Users/brianlow` except
`~/dev`", which is a recital of *Claude Code's built-in* policy from its
system prompt, not an observation of what actually blocked the call. Our
profile does not allow `~/dev`.

That mismatch is the discriminator:

| path | Claude Code's own sandbox | profile 04 |
|---|---|---|
| `~/dev` | allow (`allowWithinDeny`) | **deny** |
| `~/dev/claude-agent` | allow | allow |

So `ls ~/dev` inside the session with `/sandbox` off separates the layers
cleanly: denied ⇒ our Seatbelt profile is enforcing and criterion #3 is
proven; succeeds ⇒ the `~/.ssh` denial came from Claude Code's layer and
`/sandbox` off didn't fully disengage.

Confirmed locally that profile 04 denies `~/dev` while allowing
`~/dev/claude-agent`, so the discriminator is valid.

**Result — discriminator run inside the session, `/sandbox` still off:**

```
! ls ~/dev
ls: /Users/brianlow/dev: Operation not permitted
```

Denied. The same `ls ~/dev` run unsandboxed on the host lists all 26 project
directories, so the path is plainly readable and Claude Code's own sandbox
allows it explicitly. With the in-app sandbox off, nothing but the Seatbelt
profile can account for the denial.

**Criterion #3 proven: the boundary does not depend on the app's
cooperation.** The session refused, on its own, to route around the
restriction (it declined to allow-list `~/.ssh` and suggested an outside
terminal) — but that cooperation is exactly what the OS layer makes
unnecessary. A hostile operator would not have accepted that answer, and
would still have been stopped.

## Success criteria (PLAN.md) — status

| # | criterion | status |
|---|---|---|
| 1 | wrapped `--remote-control` session pairs and appears in Fleet | **met** (Phase 0, and again with profile 04) |
| 2 | filesystem access outside allowed roots denied at OS level, confirmed live | **met** (`verify.sh` fail=0 + live session) |
| 3 | denial survives toggling the in-app sandbox off | **met** (above) |
| 4 | (stretch) network egress scoped | not started |

The spike has answered its question: `sandbox-exec` works for this, and the
Apple-subscription blocker really was platform-based.

### Revision 05 — Playwright / headless Chromium

PLAN.md flagged Chromium as the hard one and budgeted several iterations. It
took three, and the security news is better than expected.

**Chromium runs fine without any of the grants that would have been
alarming.** It asks for all of these, is denied all of these, and still exits
0 and dumps the DOM:

| requested | withheld because |
|---|---|
| `com.apple.windowserver.active` | GUI-session access — read the screen, and in general synthesize input into other apps. Same confused-deputy class as the rev-04 LaunchServices hole, and strictly worse. |
| `com.apple.dock.server` | same GUI-session surface |
| `com.apple.coreservices.launchservicesd` | this is the rev-04 hole; re-granting it would reopen `open -a` for the whole process tree |
| `com.apple.pasteboard.1` | clipboard read — a direct exfiltration path to whatever the user last copied |
| `com.apple.tccd.system` | asking the privacy daemon for grants |
| `com.apple.CoreLocation.agent`, `locationd.desktop.registration` | location |

These are permanent denials, not TODOs. Chromium degrades gracefully on all of
them; the only visible cost is cosmetic log noise
(`CVDisplayLinkCreateWithCGDisplay failed`, an `_LSModifyNotification`
warning). Worth stating clearly because the denial-fixing loop's natural
gravity is to grant whatever gets asked for — and `windowserver.active` in
particular would have quietly undone most of the profile's value.

What Chromium actually needed was mundane:

- `process-exec*` on `~/Library/Caches/ms-playwright` and `~/.npm`
  (the npx-resolved `@playwright/mcp/cli.js`)
- `mach-register` + `mach-lookup` on
  `org.chromium.Chromium.MachPortRendezvousServer.*` — it's multi-process and
  rendezvouses with its children over a per-pid service it registers itself.
  Without this it hard-fails: `bootstrap_check_in ... Permission denied`.
  Regex-scoped to Chromium's own namespace.
- `(allow signal (target children))` — it SIGTERMs its own renderers on
  shutdown. Without it the denial is non-fatal but **renderer processes leak**,
  which matters for an agent that runs for days. Still scoped to our own tree,
  not `(target others)`.
- `com.apple.DiskArbitration.diskarbitrationd`, `RootDomainUserClient`
  (power management), and a few preference reads.

`IOSurfaceRootUserClient` / `AGXDeviceUserClient` (GPU) stay denied — headless
doesn't need them.

Regression-checked after all of this: `verify.sh` still fail=0 (the `open -a`
hole stays closed), and `claude -p` still returns `SANDBOX_PROBE_OK`.

Incidentally confirmed correctly denied: the `kicad` MCP server in the user's
global config (`~/dev/tmp/KiCAD-MCP-Server`). It's outside the allow-list and
irrelevant to this agent, so its failure to start is the profile working.

### Phase 2 (network) — descoped by decision, not by difficulty

Resolved by the user rather than investigated: **full internet access is
fine — the agent is meant to do web research.** So `(allow network*)` stays
and no `pf` companion is needed.

Worth recording what this costs, since PLAN.md treated it as a real goal: the
profile constrains what the agent can *reach on this machine*, not what it can
*send off it*. Anything inside the allow-list — vault contents, Bear notes,
gcalcli tokens — can be exfiltrated over the network by a hostile operator.
The filesystem boundary is the mitigation; the network is not. That is an
accepted trade, and the right one given the intended use, but it should be an
explicit trade rather than an assumed win.

## Productionizing — fleet of 1 (`sbx-agent-1`)

Self-contained under `sandbox-exec-prototype/`. **Nothing in the Apple
Container fleet is read, written, or executed by any of this**, and every
identifier is distinct so both can be loaded simultaneously:

| | container fleet | this fleet |
|---|---|---|
| launchd label | `com.brianlow.claude-agent.N` | `com.brianlow.claude-sbx.N` |
| plists | `../launchd/` | `./launchd/` |
| logs | `~/.claude-agent/logs/` | `~/.claude-sbx/logs/` |
| session name | `agent-N` | `sbx-agent-N` |
| isolation | Linux container | sandbox-exec (Seatbelt) |

```sh
./sbx-start.sh    # bootstrap under launchd (idempotent)
./sbx-status.sh   # launchd + process state
./sbx-stop.sh     # bootout, then confirm the process is really gone
```

`profiles/06-production.sb.template` is revision 05 with the spike scaffolding
removed — `~/dev` is now **fully denied**, including this repo — plus the fleet
log dir and the python3 needed by the pty launcher. Paths are templated
(`__HOME__`, `__VAULT__`, `__LOGDIR__`) and rendered to
`generated/sbx-agent-N.sb` on every launch, so editing the generated file never
silently persists. `sbx-agent-run.sh` compile-checks the profile before exec so
a syntax error fails loudly instead of becoming a 30s KeepAlive spin.

Verified: `verify.sh generated/sbx-agent-1.sb` → fail=0, and `~/dev/claude-agent`
and the prototype dir are both denied now (they were allowed in rev 05).

### Getting it to actually start under launchd — three failures

Running under launchd is materially different from a terminal, and all three
failures presented as *the same silent hang*: process alive, 0% CPU, a few MB
RSS, no output, no debug file, and KeepAlive dutifully keeping the corpse
warm. None produced an error message.

1. **`script` exits on stdin EOF.** launchd attaches no stdin, so
   `script -q /dev/null` hit EOF immediately (`^D` in the log) and died.
2. **No `TERM`.** launchd provides none. Worse, `launchctl bootstrap` passes
   the *calling* shell's environment into the job, so the value depends on who
   ran `sbx-start.sh` — a caller with `TERM=dumb` leaks that in. Now forced
   unconditionally in both `sbx-agent-run.sh` and the plist's
   `EnvironmentVariables`, never `${TERM:-...}`.
3. **The pty had no window size** — the actual root cause. `script` copies
   winsize from its own stdin; with no terminal there, the pty came up
   `0 rows; 0 columns` (confirmed via `stty -a -f /dev/ttysNNN`) and the TUI
   hung on it.

Fixed by replacing `script` with `pty-run.py`, which sets `TIOCSWINSZ`
explicitly (120x40), never closes the child's stdin, forwards signals so
`bootout` stops the agent cleanly, and drains the pty (necessary — an undrained
pty eventually blocks the writer). It runs *inside* the sandbox, so it gets no
privilege the agent doesn't already have.

The container fleet hit none of these: `container run --tty` allocates a
properly-sized pty, doesn't propagate EOF that way, and the image set `TERM`.

`pty-run.py` is installed to `~/.claude-sbx/pty-run.py` on each launch, because
the profile can no longer read `~/dev`. `/usr/bin/python3` is only a shim, so
the profile also needs read+exec on
`/Library/Developer/CommandLineTools`.

**Confirmed working:** debug log written, `40 rows; 120 columns`,
`Bridge URL: wss://bridge.claudeusercontent.com`,
`[remote-bridge] v2 transport connected`, `state=connected`, and zero Seatbelt
denials at runtime.

### TCC prompt names the process by version number

On first vault access macOS prompted for iCloud Drive access — titled with a
bare version number rather than anything recognisable, because the binary is a
*versioned file* (`~/.local/share/claude/versions/2.1.220`), so the process
name is literally `2.1.220`.

Two consequences worth planning around:

- TCC grants are keyed to the binary path, so **every Claude Code update will
  re-prompt** under a new version number. An unattended fleet will silently
  lose vault access on update until someone clicks Allow. Pointing the fleet at
  a stable wrapper path, or granting Full Disk Access, would avoid this — and
  FDA is needed for Bear anyway.
- The prompt is genuinely unidentifiable. Anyone who doesn't know why a bare
  version number wants their iCloud Drive should reasonably deny it.

Related, and harmless: the debug log shows `Claude in Chrome` failing to
install native-messaging manifests into Chrome/Brave/Arc support dirs with
`EPERM`. That's the profile working as intended — those directories aren't on
the allow-list and a headless agent has no business writing to them.

### Two fixes from the first real in-session test drive (2026-08-01)

A live session was asked to (1) read a Bear note, (2) write to the vault, (3)
drive CloakBrowser. Test 2 passed. The other two produced a bug and a
misdiagnosis, both instructive.

**PATH: the agent had no Node at all.** The session reported `node`/`npm`/`npx`
"missing" and concluded the machine has no Node runtime. It doesn't have one on
*its* PATH — `fleet-common.sh` was exporting only
`/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`, and node lives in
`~/.asdf/shims`. The Seatbelt profile already granted read+exec on `~/.asdf`
and `/opt/homebrew`; nothing was denied. Purely a resolution bug, and it was
visible in the debug log all along:

```
[ERROR] MCP server "playwright" Connection failed (ENOENT): Executable not found in $PATH: "npx"
[ERROR] MCP server "kicad"      Connection failed (ENOENT): Executable not found in $PATH: "node"
```

So **every npx-launched MCP server had been failing since the fleet first
started**, Playwright included — which is why "Playwright MCP end-to-end" below
was never going to work as written. Fixed by prepending `~/.asdf/shims`,
`~/.asdf/bin` and `/opt/homebrew/bin`. After the fix `playwright` connects
(`Successfully connected (transport: stdio) in 1016ms`).

`kicad` now fails *differently* — it starts, then `MCP error -32000: Connection
closed` — because its code is in `~/dev/tmp`, which the profile denies. That is
the profile working, and the better failure mode: denied, not unresolvable.

One gotcha for anyone probing this by hand: run the probe with cwd inside the
vault. From `~/dev` (denied) node dies at startup with
`EPERM: operation not permitted, uv_cwd` before it does anything else, which
looks like a Node problem and isn't.

**Claude Code's own sandbox is now explicitly off** — `fleet-settings.json`,
installed to `~/.claude-sbx/settings.json` and passed with `--settings`.
The user's global `~/.claude/settings.json` sets `sandbox.enabled: true` with
`denyRead ["/", "~/"]`, `allowRead ["~/dev"]`, and fleet agents inherited it.
Under sandbox-exec that layer is redundant at best: it is the *app's* boundary,
which is the thing this prototype exists to stop relying on, and it costs a
`dangerouslyDisableSandbox` round-trip on every command touching an
allow-listed path. Verified on the host: `ls ~/Library/Caches/ms-playwright`
returns `Operation not permitted` with the user settings, and lists with
`--settings` pointed at the fleet file.

Worth knowing, though not relied on: nested under `sandbox-exec` the in-app
sandbox appears to *already* self-disable — the same `ls` succeeded first try
under the profile even without `--settings`, while failing on the host. Seatbelt
can't meaningfully nest, and `isSandboxingEnabled()` requires its init to be
error-free. The `--settings` file makes the state declared instead of emergent.

**The session couldn't attribute its own denials** — the recurring theme. It
reported `/Applications` as blocked by TCC (it's Seatbelt — the profile has no
rule for `/Applications`), and read `~/dev`, `/Volumes` and `~/Library` denials
as Claude Code's sandbox when the profile denies them outright. Same lesson as
the criterion-#3 discriminator: an agent inside the box narrates its own system
prompt's policy, not the kernel's. Attribution has to come from outside — the
Seatbelt log, or a path the two layers treat differently.

### Finding: the filesystem boundary is not the whole boundary

The same debug log shows this, every launch:

```
MCP server "claude.ai Google Drive": Successfully connected (transport: claudeai-proxy)
MCP server "claude.ai Gmail":        Successfully connected (transport: claudeai-proxy)
```

Account-level connectors, reached over HTTPS via `mcp-proxy.anthropic.com`.
Seatbelt sees a socket. The threat model in PLAN.md is a hostile operator of the
session — that operator does not need `~/.ssh` if they can read the mail.

This is **not** the network trade-off already accepted above: that one is about
*exfiltrating* allow-listed data. This is inbound reach into accounts that were
never on the allow-list, and no filesystem profile can constrain it.

**Resolved (2026-08-01): the user removed the Gmail, Google Drive and Google
Calendar connectors from the account.** That closes it at the source rather than
per-agent, and it closes it for every client, not just the fleet. Note the
consequence for the profile's shape: this was never a Seatbelt problem and could
not have been fixed in the `.sb` file — worth remembering the next time a
capability shows up that the filesystem boundary simply doesn't see.

Related and currently closed by accident rather than intent:
`[Claude in Chrome] Extension not found in any browser`. That path would drive
the real, logged-in Chrome from outside the sandbox — the same confused-deputy
class as the rev-04 LaunchServices hole. It fails today because the browser
support dirs aren't on the allow-list. Worth keeping shut deliberately.

Also worth stating plainly: `(allow file-read-metadata)` is global, so the agent
can enumerate every path on the machine — filenames, project names, directory
structure — while being unable to read contents. Accepted for path resolution,
but it is a real leak, not nothing.

### CloakBrowser under Seatbelt — what it would actually take (SUPERSEDED)

> **Superseded 2026-08-01 by "CloakBrowser — built" below, which is the
> authoritative account.** Kept because the scorecard is instructive: this
> section was written without the software installed, and it got the
> *conclusion* right (headful/GUI is the real conflict; the answer is a second,
> differently-privileged sandbox driven over CDP) while getting most of the
> *reasons* wrong.
>
> | prediction | reality |
> |---|---|
> | "Not in `/Applications` — granting a rule there opens more than the bundle" | Wrong problem. It self-installs to `~/.cloakbrowser/chromium-<ver>/Chromium.app` — one subpath under `$HOME`, nothing to over-grant. |
> | "Its mach namespace won't match; a rebranded fork registers elsewhere" | Wrong. The fork keeps `CFBundleIdentifier = org.chromium.Chromium`, so the rev-05 regex covers it. (There *was* a second namespace — `org.chromium.Chromium.apps.*` — but that's the full app vs headless_shell, not the rebranding.) |
> | "Headful is the real question" | **Right**, and worse than expected: it needs LaunchServices to avoid `abort()` and WindowServer to avoid `SIGSEGV`, even under `--headless`. |
> | "The answer is probably a second sandbox … driven over localhost CDP" | **Right**, and that is what was built. |
>
> The transferable lesson is the one this file keeps re-learning: predictions
> about *which* rule will bite are cheap and usually wrong; the denial log is
> the only thing that actually knows.


Neither `CloakBrowser` nor `agent-browser` is installed on this host (checked
unsandboxed: no bundle in `/Applications`, not in `npm ls -g`). The vault's
`Browser Automation.md` describes the container world and is stale. Beyond
installing them:

- **Not in `/Applications`** — the profile has no rule there, and granting one
  opens more than the bundle.
- **Exec the binary directly** (`…app/Contents/MacOS/…`), never `open -a`:
  `/usr/bin/open` is exec-denied and `launchservicesd` was removed in rev 04.
  Re-adding it to launch a browser would reopen the escape.
- **Its mach namespace won't match.** The rendezvous rules are regex-scoped to
  `^org\.chromium\.Chromium\.MachPortRendezvousServer\.`; a rebranded fork
  registers elsewhere and hard-fails `bootstrap_check_in … Permission denied`.
- **Headful is the real question.** Headless Chromium runs fine without
  `windowserver.active` (rev 05). An anti-detect browser's value is fingerprint
  realism, which tends to want a real GUI session — and that grant is the one
  the profile most deliberately withholds. If it turns out to need it, the
  answer is probably a *second*, differently-privileged sandbox for the browser
  (windowserver, no vault/Bear/Keychain), driven over localhost CDP — not
  merging the two capability sets into one profile.

## CloakBrowser — built (2026-08-01), split sandbox

> **Superseded 2026-08-01 by "Browser in a container" below.** The split-sandbox
> design was right about the shape — two capability sets, joined over CDP — and
> wrong that the browser half had to be a Seatbelt profile at all. The section's
> own honest note, "the rev-04 escape is moved, not deleted", is what eventually
> retired it: a Linux container has no LaunchServices or WindowServer to grant.
> Kept because the diagnosis (the TransformProcessType abort, the -[NSWindow
> _close] SIGSEGV) is what proved the two sets are irreconcilable in one profile.

Working end to end: a live agent inside its own sandbox drives CloakBrowser
inside a *different* sandbox, and passes bot detection.

### Why it could not go in the agent's profile

Not a tuning problem — a hard incompatibility, found from the crash report
rather than guessed:

```
abort() called
HIServices  ___RegisterApplication_block_invoke
HIServices  TransformProcessType
Chromium Framework  ChromeMain
```

`TransformProcessType` is a **LaunchServices** call, and LaunchServices is
exactly the mach-lookup revision 04 removed to close the `open -a` escape.
Grant it back and it gets further, then `SIGSEGV`s in `-[NSWindow _close]`
unless **WindowServer** is granted too — the full `Chromium.app` does real
AppKit window work even under `--headless`.

Playwright's `headless_shell` tolerated both denials (rev 05). CloakBrowser
ships **only** the full bundle — the C++ fingerprint patches *are* the browser,
so there is no headless-shell variant to retreat to. The two capability sets
are irreconcilable in one profile, so they live in two:

| | agent profile | browser profile |
|---|---|---|
| vault / Bear / Keychain / gcalcli | **yes** | **no** — content *and* metadata |
| WindowServer / LaunchServices | **no** | **yes** |
| reaches the other via | CDP on 127.0.0.1:9222 | — |

`sbx-browser-run.sh` + `profiles/07-browser.sb.template`, launchd job
`com.brianlow.claude-sbx.browser`. `verify-browser.sh` → **20/20**;
`verify.sh` on the agent profile → still **fail=0**, no regression.
*(`profiles/07-browser.sb.template` and the `probe-cloakbrowser.sh` probe that
exercised it were deleted 2026-08-01, commit `9fc9211`, once the browser moved
into a container — see "Browser in a container" below. `sbx-browser-run.sh`
was not deleted; it was rewritten to drive the container instead.)*

### The security argument, and its holes

What genuinely holds:

- **launchd owns the browser's command line, not the agent.** A hostile session
  operator cannot add `--allow-file-access` (which would let pages read local
  files), repoint `--user-data-dir`, or load an extension. This is the load-
  bearing property; without it the split is decorative.
- **CDP has no verb that spawns a process.** What the agent gets is page-level
  control, not host code execution.
- **Failure degrades safely.** With no CDP port reachable, `agent-browser`
  falls back to auto-launching `/Applications/Google Chrome` — and the agent
  profile denies it (`Operation not permitted (os error 1)`). So a wedged
  browser job means "no browser", never "an unconfined browser".
- The browser sandbox is denied `pasteboard.1` (clipboard), `tccd`,
  `CoreLocation`, `bird` (iCloud), `metadata.mds`/Spotlight and `dock.server`,
  and runs fine without them. Granting the GUI surface was not treated as a
  licence to grant everything GUI-adjacent.

What does not, and should be said plainly:

1. **The rev-04 escape is moved, not deleted.** The browser sandbox holds
   LaunchServices and WindowServer. Code execution *in that process* — a
   Chromium exploit from a hostile page — lands somewhere that can launch
   unconfined GUI apps. `open`/`osascript` are exec-denied and `verify-browser`
   asserts it, but that is defense in depth over a granted capability, not the
   capability's absence. The mitigating fact is that there is nothing of value
   in reach there.
2. **CDP is unauthenticated.** Chromium's debug port trusts every local
   connection, so *any* process on this Mac can drive the browser, not only our
   agent. Loopback keeps it off the network; there is no auth to add.
3. **The browser data dir is credential-bearing.** Cookies and any logged-in
   session live in `~/.claude-sbx/browser/default`. Worse, the log shows
   `Keychain lookup failed … (-50)` — that is the Keychain deny working, and it
   means Chromium cannot use the OS keychain to encrypt cookies at rest. A
   browser that can log in is a secret store however tight its profile is.
   *(`~/.claude-sbx/browser/` — 101M — has since been deleted along with this
   profile. The container's profile lives in `browser-profile/` instead, and
   Task 4 found it does not persist cookies across a restart either — see
   "Task 4 verification" below. So the concern this bullet raised is now moot
   for a different reason than intended: not a tighter secret store, but no
   persistent secret store at all.)*
4. Two sandboxes and two restart levers now. `KeepAlive` restarts a browser
   that *exits*; a browser that wedges while still running is invisible to it,
   which is why `sbx-status.sh` probes `/json/version` rather than trusting the
   pid.

### Finding: `(deny file-read*)` does NOT cover `file-read-metadata`

Non-obvious, and it briefly produced a real hole in the browser profile:

```
(deny file-read*        (subpath "<vault>"))  →  ls -l <vault>/CLAUDE.md   SUCCEEDS
(deny file-read-metadata (subpath "<vault>")) →  ls -l ...  Operation not permitted
```

`(import "bsd.sb")` grants `file-read-metadata` broadly and a later
`(deny file-read*)` does not take it back — the operation has to be named
explicitly. Until it was, the GUI-privileged sandbox could enumerate the vault
(filenames, sizes, mtimes) while being unable to read a byte of content.

This also sharpens the existing note that the *agent* profile's global
`(allow file-read-metadata)` is a real enumeration leak: it is not merely
convenient there, it is not revocable by the obvious rule either.

Worth noting how it was nearly missed: the first check used `ls`, which needs
only metadata, and reported FAIL for the vault. The reflex is to distrust the
test; here the test was right about *something* and wrong about *what*. Content
was denied all along. Both operations are now asserted separately in
`verify-browser.sh`, because they fail separately.

### Smaller things worth keeping

- **`--no-sandbox` is required, and is not what it sounds like.** Chromium's own
  sandbox is Seatbelt-based and Seatbelt does not nest; inside `sandbox-exec`
  the zygote cannot issue its extension (`deny file-issue-extension …
  com.apple.app-sandbox.read`) and the browser dies before writing
  `DevToolsActivePort`. What is lost is Chromium's internal renderer/browser
  split, not our boundary — every process in the tree is still confined by the
  profile, which is the stronger of the two.
- **WebGL must WORK; the GPU need not be real.** With `--disable-gpu` and no
  IOKit access, sannysoft reports `WebGL Vendor: Canvas has no webgl context`,
  and "no WebGL at all" is itself a fingerprint tell. Granting
  `IOSurfaceRootUserClient` / `AGXDeviceUserClient` / `IOAccel*` fixes it:
  `ANGLE (Apple, ANGLE Metal Renderer: Apple M1 Pro)`.

  **Correction to the first reading of this.** That renderer string is not
  evidence the grants are what make it realistic — CloakBrowser *spoofs* it.
  Forced onto software rendering with `--use-angle=swiftshader`, on the same
  machine, it reports `ANGLE (Apple, ANGLE Metal Renderer: Apple M2 Max)`.
  This host is an M1 Pro (`system_profiler`), so that string is fabricated, and
  no SwiftShader/llvmpipe tell leaks through.

  The requirement is therefore *a working GL context*, not hardware
  acceleration. That matters well beyond this profile: it means a GPU-less
  environment — a VM or container — does not automatically lose the WebGL
  fingerprint, which is the opposite of what the first reading implied.
- **The code-sign clone needs `file-link`, not just `file-write*`.** Modern
  Chromium `clonefile()`s its own bundle into
  `/private/var/folders/.../org.chromium.Chromium.code_sign_clone/`;
  a write grant alone yields `forbidden-link-priv<file-write*>`.
- **Probe with cwd somewhere the profile allows.** Same trap as the PATH fix:
  from a denied cwd things die at startup in ways that look unrelated.
- `verify.sh`'s Bear probe can **hang for minutes** rather than failing fast —
  TCC blocking, not Seatbelt. Kill the `ls` and the run completes. Pre-existing,
  not caused by any of this.

### Still open

Everything PLAN.md asked for is answered. What's left is productionizing,
which the plan scoped as a separate follow-on:

- **Drop the spike scaffolding** from the profile: `~/dev/claude-agent` read
  and `sandbox-exec-prototype` read/write. Nothing else should need them.
- **Bear needs Full Disk Access** on whatever launches the agent, or Bear
  reads stay broken (TCC, not Seatbelt — see above). Same grant the README
  already documents for the container fleet.
- **Decide on the Keychain grant** — the widest thing in the profile, and
  unavoidable for this auth mechanism.
- **launchd integration**: per-agent profiles and session names, `KeepAlive`,
  and the reset-watcher path, mirroring `agent-run.sh` without touching it.
- **Playwright MCP end-to-end**: the server now *connects* (it never could
  before the PATH fix), but `claude → @playwright/mcp → browser` still hasn't
  been driven from inside a live session. Lower priority now that CloakBrowser
  covers the browser case end to end — but note the two are independent paths:
  Playwright drives `headless_shell` *inside* the agent sandbox, CloakBrowser
  is driven over CDP in the *other* sandbox.
- **The browser from a live remote-control session, against a real retailer.**
  The browser is now `cloakhq/cloakbrowser:0.5.3` in a container (see "Browser
  in a container" below), not the Seatbelt profile this bullet originally
  meant. `verify-detection.sh` already drives `agent-browser` against the live
  launchd job and gets clean bot-detection scores (Task 5), but that is a
  scripted probe, not a real Fleet session. Still open, still a human's job —
  this is Task 8.
- ~~**Decide whether the browser should stay logged in.**~~ **Settled by
  force, not by decision.** The container profile is ephemeral: Task 4
  confirmed cookies do not survive a container restart under either
  `--data-dir=/profile` or the `--user-data-dir` fallback, and the spec forbids
  account logins outright. There is no persistent session to decide about.
- `/private/tmp` is granted read/write and is world-writable and shared with
  every other process on the machine. Probably worth narrowing to a private
  temp dir.
- **Update the vault docs for the native fleet.** `Bear DB.md` and
  `Browser Automation.md` still describe container-era paths and mounts
  (`/mnt/...`), which are wrong for a sandbox-exec agent — it sees real host
  paths, Bear reads are TCC-blocked, and `Claude in Chrome` is deliberately
  shut. Outside this repo, so not touched here.
- `~/.claude` and `~/.npm` are both writable and executable, so the agent can
  write a script there and run it. Not an escape — children inherit the
  policy — but the profile controls what code can *reach*, not what code
  *runs*.

## Browser in a container — Phase 0 (2026-08-01)

Spike: `cloakhq/cloakbrowser:0.5.3` under Apple `container`, driven over CDP
from the host via `agent-browser`, container name `cb-spike`. Torn down
completely at the end — nothing left running or on disk.

### Port used: 9223, not 9222

`curl -s http://127.0.0.1:9222/json/version` answered before this spike
started — the existing native browser job (`com.brianlow.claude-sbx.browser`)
already holds it. Per the task brief, the spike published on
`127.0.0.1:9223:9222` instead and every command below uses 9223. The native
browser was never stopped and was re-checked healthy (same
`webSocketDebuggerUrl` generation, `Chrome/145.0.7632.109`) after the spike's
teardown.

### Q4 — free binary runs with no license key: YES

`container run --rm cloakhq/cloakbrowser:0.5.3 cloaktest` ran to completion,
no license key set. Startup banner:

```
Running the free binary (v146). The latest binary (v150) is free too, with 1 concurrent session.
Get your key: run  cloakbrowser login  or visit https://cloakbrowser.dev/free
For more than one concurrent session → https://cloakbrowser.dev
```

Not a warning that blocks anything — informational only, exit path unaffected.
`cloaktest` result: 4/6 detectors passed (`bot.sannysoft.com` 56/56,
`bot.incolumitas.com` 35/36, Rebrowser 🟢7⚪3 clean, CreepJS lies:0;
`deviceandbrowserinfo.com` flagged `isBot: True` and `BrowserScan` timed out
navigating — both look like target-site flakiness/geo/IP-reputation issues
external to the container, not re-investigated).

**Surprise, and it matters for later tasks**: the free binary phones home on
every `cloakserve` start regardless of license key — `GET
https://pypi.org/pypi/cloakbrowser/json`, `GET
https://api.github.com/repos/CloakHQ/cloakbrowser/releases`, and if a newer
Chromium build exists it **downloads and installs it in the background
unprompted** (`~198MB` fetched from `cloakbrowser.dev`/GitHub release assets,
signature-verified with Ed25519 and SHA-256 before extracting to
`~/.cloakbrowser/chromium-<ver>`). This happened on every fresh `cb-spike`
start in this spike. Not a blocker here — outbound egress from the container
is expected and unrestricted — but Task 3/4 should decide whether to pin this
off (env var not checked; not investigated) since it means the pinned image
tag does not guarantee a pinned Chromium binary at runtime.

### Critical finding not anticipated by the brief: `cloakserve` binds to loopback *inside* the container by default, and Apple `container --publish` cannot reach it

The very first `container run --detach ... cloakserve --data-dir=/profile
--fingerprint=41337` came up, logged `CDP multiplexer starting on port 9222`,
and then **`curl -s --max-time 5 http://127.0.0.1:9223/json/version` from the
host got "Empty reply from server" indefinitely** (curl exit 52), while
`container exec cb-spike curl -s http://localhost:9222/json/version` from
*inside* the container succeeded immediately with a normal CDP document.

Root-caused by reading `/usr/local/bin/cloakserve` inside the image:

```python
in_container = os.path.exists("/.dockerenv") or os.path.exists("/run/.containerenv")
host = "0.0.0.0" if in_container else "127.0.0.1"
web.run_app(app, host=host, port=port, print=None)
```

`cloakserve` decides whether to bind all-interfaces vs. loopback-only by
checking for Docker's `/.dockerenv` or Podman's `/run/.containerenv` marker
files. Apple's `container` runtime creates **neither** — confirmed with
`container exec cb-spike ls /.dockerenv /run/.containerenv` (both "No such
file or directory") — so `in_container` evaluates `False` and `cloakserve`
binds `127.0.0.1:9222` *inside its own network namespace*. Apple
`container --publish` NATs onto the container's routable interface, not its
loopback, so a host-published port can never reach a loopback-only listener:
confirmed independently with a throwaway container running
`python3 -m http.server --bind 0.0.0.0` (publish worked, HTTP 200) versus the
same bound to `127.0.0.1` (unreachable, same as `cloakserve`) — and directly
via `cat /proc/net/tcp` inside `cb-spike`, which showed the listen socket as
`0100007F:2406` (127.0.0.1:9222) until the workaround below, and `00000000:2406`
(0.0.0.0:9222) after.

**Workaround used for the rest of this spike** (Steps 4 onward): start the
container with a shell wrapper that creates the marker file `cloakserve`
checks for, before exec'ing it:

```
container run --detach --name cb-spike \
  --publish "127.0.0.1:9223:9222" \
  --mount "source=/tmp/cb-spike-profile,target=/profile" \
  --memory 4g --cpus 2 \
  cloakhq/cloakbrowser:0.5.3 \
  sh -c "touch /run/.containerenv && exec cloakserve --data-dir=/profile --fingerprint=41337"
```

After this, `/proc/net/tcp` showed `00:2406` bound on `0.0.0.0`, and
`curl http://127.0.0.1:9223/json/version` from the host returned the CDP
document immediately, with `webSocketDebuggerUrl` correctly rewritten to
`ws://127.0.0.1:9223/...` (cloakserve reads the incoming `Host` header to
build this, so it tracks whatever host:port the client actually connects
through).

**This is the single most expensive-to-miss fact in this spike.** The brief's
literal `cloakserve --data-dir=/profile --fingerprint=41337` command line, run
exactly as written, produces a container that starts cleanly, logs no error,
and is **permanently unreachable from the host** — a silent hang, not a crash.
Tasks 3 and 4 must not hardcode the brief's bare command; they need the
`sh -c "touch /run/.containerenv && exec cloakserve ..."` wrapper (or an
equivalent — e.g. a `--mount` that pre-creates `/run/.containerenv`, or an
image-level fix) or the fleet's browser container will come up looking healthy
in `container ls` while serving nothing.

Not proven: whether a future `cloakserve` release fixes the detection (e.g.
checking `/proc/1/cgroup` or a cgroup-driver-agnostic signal instead of the
Docker/Podman marker files), or whether Apple ships a lower-level fix. Treat
the wrapper as necessary until re-verified against whatever image tag Task 3
actually pins.

### Q1 — is the port confined to loopback: YES, with one unexplained mismatch

```
$ LANIP="$(ipconfig getifaddr en0)"; echo "$LANIP"
192.168.1.52
$ curl -s --max-time 3 "http://192.168.1.52:9223/json/version"; echo "exit=$?"
exit=7
```

`exit=7` is curl's "failed to connect" — the LAN-IP curl **failed**, exactly as
required. The gate passes.

```
$ sysctl -n net.inet.ip.forwarding
1
```

This does **not** match the brief's "expected and required" value of `0`.
Checked twice (`sysctl -n` and `sysctl -a | grep forwarding`, both `1`), and
`net.inet6.ip6.forwarding` is also `1`. `netstat -nr` shows a `bridge100`
interface and default routes over `utun0`/`utun1` in addition to `en0` — this
Mac has other networking software (VM/VPN bridging, not investigated which)
that turns on IP forwarding independent of Apple `container`. So the two
brief-listed signals disagree: the LAN curl (direct empirical test of
reachability) says confined; the sysctl (a proxy for "is *anything* capable of
routing off-host") says forwarding is on for some unrelated reason. **The
loopback confinement conclusion rests on the curl result, not on
`ip.forwarding`, on this host.** Also directly confirmed: connecting to the
container's own vmnet address from the host
(`curl http://192.168.64.7:9222/...`, bypassing the published-port NAT
entirely) got connection refused — consistent with `cloakserve` listening
only on `127.0.0.1` inside its namespace once the workaround is applied, i.e.
even the container's *own* routable address doesn't expose it.

Not proven: what specifically has `net.inet.ip.forwarding=1` on this host, or
whether that matters for a *different* published port/service that binds
`0.0.0.0` the way `cloakserve` now does with the workaround. The empirical
LAN-curl test is the one to re-run if this is ever re-verified, not the sysctl
alone.

### Q2 — does the profile survive a restart: NO

Set `document.cookie = 'sbxprobe=1; ...'` via `agent-browser eval` against the
first `cb-spike`, confirmed `document.cookie` read back `"sbxprobe=1"`. Then:

```
container stop cb-spike && container rm cb-spike
container run --detach --name cb-spike ... (same command, same bind mount)
```

After the restart, `agent-browser eval "document.cookie"` on
`https://example.com` returned `""` — the cookie is gone.

The bind mount itself does persist and is reused — `/tmp/cb-spike-profile/41337/Default/Cookies`
exists on the host both before and after the restart, is a real non-empty
SQLite file (20480 bytes), and Chrome profile directories
(`GrShaderCache`, `Local State`, `component_crx_cache`, etc.) are present with
plausible content. But querying the post-restart `Cookies` DB directly
(`sqlite3 ... "select * from cookies where name='sbxprobe'"`) returns no rows,
and every file under the profile tree carries the *second* container's start
time, not the first's — consistent with the profile being freshly
reinitialized on start rather than the existing SQLite state being reused, but
this is inference from mtimes, not a confirmed mechanism.

**Per the brief's contingency: the spec's "persistent profile" goal is not
achievable through `cloakserve --data-dir` as tested.** Task 4 should plan on
the fallback already anticipated in the brief — try `--user-data-dir=/profile`
as a Chromium passthrough flag instead of `cloakserve`'s own `--data-dir`, and
re-test with the same cookie probe.

Not proven: *why* — whether `cloakserve` deliberately treats `--data-dir` as
scratch space and ignores it for the actual Chromium profile, whether the
container's SIGTERM on `stop` cuts off Chromium before it flushes its cookie
store, or something else. Not root-caused further in this spike; worth a
targeted follow-up (graceful shutdown timing, or a diff of the Cookies file's
raw bytes before/after) only if Task 4's passthrough-flag fallback also fails.

### Q3 — is the fingerprint seed pinned: YES

With `--fingerprint=41337` on both the pre-restart and post-restart
container:

| reading | before restart | after restart |
|---|---|---|
| `navigator.hardwareConcurrency + '/' + navigator.deviceMemory` | `8 / 8` | `8 / 8` |
| WebGL `UNMASKED_RENDERER_WEBGL` | `ANGLE (NVIDIA, NVIDIA GeForce RTX 5080 Laptop GPU (0x00002C19) Direct3D11 vs_5_0 ps_5_0, D3D11)` | identical, byte-for-byte |

Identical across the restart that lost the cookie — so fingerprint pinning and
profile persistence are independent mechanisms in `cloakserve`; the former
works, the latter (as tested) doesn't. The WebGL context is a real working GL
context reporting a plausible discrete-GPU renderer string on this Mac's own
GPU-less headless container — consistent with the sandbox-exec prototype's
earlier finding (see "WebGL must WORK; the GPU need not be real" above) that
the fingerprint is spoofed software, not a reflection of real hardware; this
host has neither an RTX 3080 nor an RTX 5080.

### Multi-seed behavior (not one of Q1-Q4, but flagged per the brief as worth knowing)

A second `curl ".../json/version?fingerprint=99999"` against the same
`cb-spike` **spawned a second, independent Chromium process** (confirmed via
the multiplexer's own status page, `curl http://127.0.0.1:9223/`  →
`"active": 2`, with distinct `pid`/`port` entries for seeds `41337` and
`99999`) rather than being refused or silently degrading. The free-binary
banner advertises "1 concurrent session" as a **Pro** upsell
(`cloakbrowser.dev`), but nothing in the free binary observed here enforces
that limit locally — a second seed just works. Not a blocker (one agent uses
one seed, per the brief), but worth knowing: nothing about the free tier stops
a caller from driving multiple seeds against one `cb-spike`, so any
enforcement of "one session" has to come from how the fleet calls it, not from
the image.

### `container ls -q` / `container ls -a --format json` shape (for Task 2's mount parser, Task 3's `grep -qx`)

`container ls -q` prints **all running containers on the host, one name per
line**, not filtered to ones this spike started — on this host it printed:

```
hermes-1
cb-spike
```

(`hermes-1` is an unrelated running container from other work on this
machine.) `grep -qx cb-spike` against that output is exactly right — it
matches the exact line regardless of what else is running, and correctly
returns non-zero once `cb-spike` is torn down. Stopped containers (`agent-1`
through `agent-5`, `buildkit`) do **not** appear in `ls -q` — only `-a`
surfaces them, confirming `ls -q`'s output is running-only.

`container ls -a --format json` returns a **JSON array**, one object per
container, no wrapping key. The fields Task 2's mount parser and Task 3's
container-existence check care about, from `cb-spike`'s own entry:

```json
{
  "status": "running",
  "configuration": {
    "id": "cb-spike",
    "mounts": [
      {
        "destination": "/profile",
        "source": "/tmp/cb-spike-profile",
        "type": { "virtiofs": {} },
        "options": []
      }
    ],
    "publishedPorts": [
      {
        "containerPort": 9222,
        "hostPort": 9223,
        "hostAddress": "127.0.0.1",
        "proto": "tcp",
        "count": 1
      }
    ],
    "initProcess": {
      "executable": "/entrypoint.sh",
      "arguments": ["sh", "-c", "touch /run/.containerenv && exec cloakserve --data-dir=/profile --fingerprint=41337"]
    }
  },
  "networks": [
    { "network": "default", "hostname": "cb-spike", "ipv4Address": "192.168.64.7/24" }
  ]
}
```

Notes for later tasks: the container's own `id` lives at
`.configuration.id`, not top-level; mounts are `.configuration.mounts[]` with
`source`/`destination` (not `src`/`dst`); published ports are
`.configuration.publishedPorts[]` with `hostPort`/`containerPort` as separate
integer fields and `hostAddress` as a string (`"127.0.0.1"`, confirming the
loopback binding is recorded in the container's own config, inspectable
without a live curl). `initProcess.arguments` reflects whatever command was
actually passed — this is where Task 3's `grep -qx`-style check should look if
it ever needs to confirm the `.containerenv` workaround shipped, since the
raw entrypoint (`cloakserve --data-dir=... --fingerprint=...`) alone would not
show the wrapper.

### Teardown — confirmed clean

```
container stop cb-spike && container rm cb-spike
rm -rf /tmp/cb-spike-profile
container ls -a          # no cb-spike
container ls -q           # no cb-spike (only hermes-1, unrelated)
ls /tmp/cb-spike-profile  # No such file or directory
```

The pre-existing native browser job on port 9222 was re-verified healthy
afterward (`curl http://127.0.0.1:9222/json/version` → `Chrome/145.0.7632.109`,
same as before the spike started) — nothing about this spike touched it.

### What's not proven, stated plainly

- **Why** cookies don't survive a restart through `--data-dir` — inferred from
  file mtimes and an empty SQLite query, not from reading `cloakserve`'s
  profile-management code path.
- Whether the `/.dockerenv`/`/run/.containerenv` detection gap is something
  Apple `container` could fix on its side (e.g. by creating one of those
  marker files itself, the way it presumably intends containers to detect
  their environment) rather than needing a wrapper in every `container run`
  invocation — not investigated; the wrapper is the pragmatic fix, not
  necessarily the right long-term one.
- The `net.inet.ip.forwarding=1` discrepancy's root cause on this host.
- Whether the free binary's background Chromium self-update can be disabled,
  and whether it should be for a pinned fleet image (an env var was not
  searched for or tested).
- Whether `bot.sannysoft`/`bot.incolumitas`/Rebrowser detection results hold up
  against a real target site relevant to this project — `cloaktest`'s battery
  is generic bot-detection demo sites, not validated against anything
  project-specific.

## Task 4 verification — launchd/container evidence, and the persistence fallback re-tested

### KeepAlive self-healing: CONFIRMED

`container rm -f sbx-browser` while the `com.brianlow.claude-sbx.browser` job
was loaded, then polled `container ls` / `curl .../json/version`: the
container reappeared on its own (`sbx-browser` back in `container ls` within
seconds, `STARTED` timestamp updated) with no `launchctl` call of any kind.
`./sbx-status.sh` afterward showed `browser  loaded  running (container, CDP
9222 ok)` and `./verify-browser.sh` passed 11/11. This is the property that
made the native (`sandbox-exec`) browser job self-healing, and it survived the
substrate change to a container intact — launchd's `KeepAlive` on the
`container run` foreground process is sufficient; no wrapper logic was needed.

### Q2 re-tested with the brief's fallback flag: STILL NO — the design goal is not met, and this is a deliberate, documented gap

The committed `sbx-browser-run.sh` does **not** carry `--user-data-dir`. Confirmed empirically why not, by testing it directly rather than assuming:

1. **Baseline (committed form)** — set `document.cookie='sbxprobe=1'` via
   `agent-browser eval` against `https://example.com`, confirmed the readback,
   then `container rm -f sbx-browser` and waited for launchd to bring it back.
   Reconnected, reloaded `https://example.com`, read `document.cookie` back:
   `""`. Cookie lost, matching Phase 0 exactly.

2. **Fallback** — temporarily edited the `cloakserve` line to add
   ` --user-data-dir=/profile/chrome` (extra args are forwarded to the
   browser per the brief), restarted the container the same way, repeated the
   cookie probe (`sbxprobe=2`), confirmed the readback, restarted again,
   reconnected: `document.cookie` → `""` again. Fallback does not persist
   cookies either.

3. **Root cause found, not just observed**: after the fallback run, `find
   sandbox-exec-prototype/browser-profile -maxdepth 2` showed only the
   fingerprint-keyed `41337/` directory — **no `chrome/` subdirectory was ever
   created**. `--user-data-dir=/profile/chrome` was silently ignored;
   `cloakserve` does not forward it to the underlying Chromium the way the
   brief's contingency assumed (or intercepts/overrides it before Chromium
   sees it). This isn't a timing or shutdown-signal problem — the flag simply
   had no observable effect on where the profile is written.

**Reverted the edit; `sbx-browser-run.sh` is byte-for-byte the committed
version** (`git diff` clean after revert). No code change was justified by
this experiment.

**Stated plainly, because this is a stated design goal and not just an
implementation detail**: the browser profile is ephemeral across container
restarts under both forms tested. Fingerprint pinning (`--fingerprint`)
persists correctly (per Phase 0's Q3, unaffected by this task); cookies,
localStorage, and any other login/session state do not survive a restart.
Anything that depends on staying logged in across a browser-job restart will
silently log out. Neither `--data-dir` nor Chromium's own
`--user-data-dir` (as passed through `cloakserve`) solves this with the
current image (`cloakhq/cloakbrowser:0.5.3`); a real fix would need either a
`cloakserve` flag/behavior this image doesn't expose, or reading its source to
find the actual profile-write path and mounting *that* path directly — not
attempted here, out of scope for Task 4's verification pass.

### Self-update suppression: CONFIRMED

Across all restarts performed during this verification (several, in quick
succession), `~/.claude-sbx/logs/browser.log` never showed a GitHub fetch or
any large download — no lines resembling a Chromium binary pull, only the
`cloakserve` banner, `CDP multiplexer starting`, `Launching Chrome`, and
`Chrome ready`. `curl http://127.0.0.1:9222/json/version` after a fresh
restart reported `Chrome/146.0.7680.177`, matching the banner's own "Running
the free binary (v146)" line and **not** the "latest binary (v150)" the
banner separately advertises — confirming `CLOAKBROWSER_AUTO_UPDATE=false` is
holding the image's shipped binary rather than the image silently drifting
to whatever the free binary would otherwise fetch.

Time from container start to `Chrome ready` was **not consistent**: a cold
start (fleet otherwise idle) reached `Chrome ready` in ~11s, but several
restarts performed back-to-back in this session (as fast as `container rm -f`
+ launchd relaunch allows, roughly every 1-2 minutes) took 60-115s, all spent
between the `Openbox-Message` log line and `Launching Chrome` with **no log
output at all** in between — not a download signature (no repeated lines, no
network-error lines), more consistent with I/O or profile-recovery cost from
back-to-back ungraceful (`SIGKILL`-via-`rm -f`) restarts against the same
bind-mounted profile directory. Not root-caused further here; worth knowing
if `KeepAlive` ever has to cycle this job repeatedly in a short window in
production, since a 100s+ gap before `Chrome ready` is a long way from
"self-healing in seconds."

## Task 5 — bot-detection scores for the containerized browser (2026-08-01)

`verify-detection.sh` drives the *live fleet* browser
(`com.brianlow.claude-sbx.browser`, currently the container, CDP on 9222) over
`agent-browser`, not a one-off `cloaktest` invocation. The captured output is
reproduced in full under "Container results" below — this file is the record;
there is no separate report to go and find.

### Finding the macOS baseline (this was not a single number to look up)

There is **no full sannysoft/incolumitas score table for the native macOS
build** anywhere in this file — that was checked directly (`grep -n
'sannysoft\|incolumitas\|/56\|/36'`) before writing anything down. The
`56/56` / `35/36` / Rebrowser / CreepJS numbers that appear above under
"Browser in a container — Phase 0" are the **container's own** `cloaktest`
run, already flagged in that section as informational, not a macOS number.

What macOS *does* have on record, under "CloakBrowser — built" above, is
narrower but load-bearing:

- **WebGL must work; the GPU need not be real.** Without GPU IOKit grants,
  sannysoft reported `WebGL Vendor: Canvas has no webgl context` — a real
  failure. With `IOSurfaceRootUserClient`/`AGXDeviceUserClient` granted it
  became a working context reporting `ANGLE (Apple, ANGLE Metal Renderer:
  Apple M1 Pro)` — and forced onto SwiftShader software rendering on the same
  M1 Pro host, CloakBrowser instead reported `ANGLE (Apple, ANGLE Metal
  Renderer: Apple M2 Max)`, a fabricated string with no SwiftShader/llvmpipe
  tell leaking through.
- The qualitative claim "a live agent inside its own sandbox drives
  CloakBrowser inside a different sandbox, **and passes bot detection**" (no
  itemized score attached).
- No `navigator.webdriver` value was ever recorded for the macOS build.

So the comparison below is against *that* — a working-vs-broken WebGL
context and a fabricated-but-plausible renderer string — not a numeric
sannysoft/incolumitas delta, because macOS never had one recorded.

### Container results (headless, the committed configuration)

```
=== environment
  userAgent   : Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36
  platform    : Win32
  webdriver   : false
  cores/mem   : 8 / 8
  screen      : 1920x1080

=== WebGL
Google Inc. (NVIDIA) | ANGLE (NVIDIA, NVIDIA GeForce RTX 5080 Laptop GPU (0x00002C19) Direct3D11 vs_5_0 ps_5_0, D3D11)

=== incolumitas (bot.incolumitas.com #detection-tests)
intoli: 6/6 OK (userAgent, webDriver, webDriverAdvanced, pluginsLength, pluginArray, languages)
fpscanner: 20/21 OK, 1 FAIL (WEBDRIVER)
total: 26/27 OK

=== sannysoft (bot.sannysoft.com)
`verify-detection.sh` captures and prints the first 25 of 58 table rows (per
the brief) — all "ok"/"passed"/plain informational, no red/FAIL rows. The
remaining 33 rows were spot-checked by hand at the time and were likewise
clean, but that check is not part of the committed script, so it is a
one-off observation here, not something a re-run of `verify-detection.sh`
reproduces.
```

The WebGL string is byte-for-byte the same fabricated `RTX 5080 Laptop GPU`
renderer the "Browser in a container — Phase 0" section recorded weeks
earlier for the bare image — confirming the fingerprint survived being wired
into the fleet (launchd job, `sh -c "touch /run/.containerenv && exec
cloakserve ..."` wrapper, port republish) intact.

The lone incolumitas failure (`fpscanner.WEBDRIVER`) is the same test that
Phase 0's `cloaktest` run flagged as `35/36` — one failure, and
`navigator.webdriver` reads `false` directly, so this is the known
false-positive in that specific probe, not a real webdriver leak. No other
suite reported a failure.

### Headed mode (Step 3) — not attempted

The brief offers `--headless=false` as a remedy "if anything fails." Nothing
did: `webdriver` false, WebGL a working context with a plausible fabricated
string, sannysoft clean, incolumitas 26/27 with the one known false positive.
Editing `sbx-browser-run.sh` and cycling the fleet job for a remedy the
results don't call for would cost RAM and restart time (see the 60-115s
"Chrome ready" gap noted above) for no evidenced gain, so headed mode was not
tried and the file was not touched.

### Verdict: no worse than the macOS baseline — the one thing macOS had recorded, WebGL fabrication, is intact in the container

- `navigator.webdriver` is `false` — never regressed, and now recorded for the
  first time on either platform.
- WebGL is a **working** context with a plausible, fabricated GPU string —
  the exact property macOS was shown to require (a missing context is itself
  the tell) — and it survived unchanged from the bare-image Phase 0 spike
  into the live fleet job.
- sannysoft and incolumitas both come back clean modulo one known
  false-positive test, matching what the container's own `cloaktest` run
  found independently in Phase 0.
- **Nothing regressed.** The only asterisk is that macOS never had a
  comparable full-suite number recorded to regress *from* — the real,
  provable continuity is the WebGL finding, and that one holds.

Restated per this task's scope: these are synthetic-suite scores, which
measure the fingerprint, not whether a real retailer serves a logged-in
session a product page. That is Task 8's job, and a human's.

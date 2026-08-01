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
| 04 | close LaunchServices hole; `~/.npm`; DNSConfiguration | works; verify.sh 16/16 |

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

### verify.sh against revision 04 — 16/16

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
| 2 | filesystem access outside allowed roots denied at OS level, confirmed live | **met** (`verify.sh` 16/16 + live session) |
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

Regression-checked after all of this: `verify.sh` still 16/16 (the `open -a`
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
- **Playwright MCP end-to-end**: headless Chromium is verified working under
  the profile directly, but the full `claude → @playwright/mcp → browser`
  path hasn't been driven from inside a live session yet.
- `/private/tmp` is granted read/write and is world-writable and shared with
  every other process on the machine. Probably worth narrowing to a private
  temp dir.
- `~/.claude` and `~/.npm` are both writable and executable, so the agent can
  write a script there and run it. Not an escape — children inherit the
  policy — but the profile controls what code can *reach*, not what code
  *runs*.

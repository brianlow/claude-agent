# Sandbox-exec prototype

> ## STATUS — 2026-08-01: spike complete, fleet of 1 running
>
> | | |
> |---|---|
> | Phase 0 (does it pair at all) | **done** — passed first try |
> | Phase 1 (tighten the profile) | **done** — 6 revisions, `verify.sh` fail=0 |
> | Phase 2 (network) | **descoped by decision** — full internet is wanted |
> | Productionizing (launchd) | **done for a fleet of 1** (`sbx-agent-1`) |
>
> Success criteria 1–3 met, 4 descoped. Both original open questions answered:
> the Remote Control block **was** platform-based, and `sandbox-exec` **does**
> hold against an operator who turns the in-app sandbox off.
>
> **`NOTES.md` is the authoritative record** — findings, the revision log, the
> escapes that were found and closed, and everything still open. Read it before
> this file. The rest of PLAN.md below is the original plan, kept because the
> "Why" and the target allow-list still govern the work; the phase sections are
> annotated with what actually happened.
>
> **Picking this up in a new session?** Jump to
> [Next session starts here](#next-session-starts-here) at the bottom.

## Why

Remote Control fails inside the Apple Container fleet because the account's
subscription is Apple-billed (`billingType: apple_subscription`), and that
entitlement only seems to check out from a genuine native macOS client —
confirmed by `host-diag-test` pairing fine while every container-based
attempt (`--bare`, an older CLI version, `--debug`) got rejected or silently
never appeared in Fleet. Running agents as native macOS processes instead of
in a Linux container should sidestep that entirely.

That reopens the isolation question the containers were solving. Claude
Code's own `sandbox.enabled` setting isn't sufficient on its own: it's an
in-app toggle, so anyone who gets into a live remote-control session can just
tell Claude to turn it off. The threat we care about is a *hostile operator
of the session*, not just an agent misbehaving on its own — so the boundary
has to be enforced by something the app can't talk its way out of.

`sandbox-exec` wraps the process from outside, before Claude Code even
starts. The kernel enforces the policy on every syscall the process (and
anything it forks) makes; there's no in-app command that can lift it. It's
marked deprecated by Apple. That's an accepted risk, not a blocker: this is
a personal project, far more likely to change shape or be retired outright
than to survive long enough to collide with Apple actually removing the
API. This spike is about proving the mechanism works now, not committing to
it long-term. If it pans out, productionizing it might mean staying on
`sandbox-exec`, moving to App Sandbox entitlements (same underlying kernel
tech, supported surface), or a VM — that decision comes after this spike,
not before.

## Ground rules

- Everything lives under this directory. **Nothing in the existing fleet
  (`entrypoint.sh`, `agent-run.sh`, `common.sh`, `Dockerfile`, launchd
  plists) gets touched.** The 5 running containers keep running as-is.
- This is a spike to answer "does this work at all," not a rewrite of the
  fleet. Productionizing (launchd integration, per-agent profiles, mounting
  real vault/gcalcli paths, etc.) is a separate follow-on if Phase 1 succeeds.
- Uses the plain npm-installed `claude` (matches what we tested in the
  container diagnostics), not the cmux-wrapped host binary, to keep this
  consistent with earlier findings.

## Phase 0 — Is there any path to success at all?  ✅ DONE

> Passed on the first attempt. Bridge connected, zero rejection lines, session
> visible in Fleet. The container-era `Remote Control requires a claude.ai
> subscription` failure did not reproduce.

Before spending time hand-writing a tight profile, confirm the basic plumbing
works: `sandbox-exec` + `claude --remote-control` + Fleet pairing, with
essentially no restriction.

1. `profiles/00-allow-all.sb`: `(version 1) (allow default)` — a no-op
   sandbox. Proves `sandbox-exec` wrapping itself doesn't break anything
   (dyld, subprocess spawning, network) before restriction enters the
   picture at all.
2. Run: `sandbox-exec -f profiles/00-allow-all.sb -- claude
   --dangerously-skip-permissions --permission-mode bypassPermissions
   --remote-control sandbox-diag-0 --debug --debug-file <log>`
3. Check the debug log for the "Remote Control requires a claude.ai
   subscription" rejection we saw from every container attempt.
4. Check Claude Desktop's Fleet view for `sandbox-diag-0`.

**Exit criteria:** session pairs and shows up in Fleet. If it doesn't show up
even fully unrestricted, wrapping in `sandbox-exec` breaks something
unrelated to filesystem/network restriction (e.g. how it forks children, or
something in the handshake) and this approach needs rethinking before any
further profile work is worth doing.

Note: `allow-all` plus `--dangerously-skip-permissions` means this run has
*no* enforced boundary at either the OS or app layer. Run it from a scratch
directory, not one with real vault/credential access, purely as
belt-and-suspenders while nothing is actually being restricted yet.

## Phase 1 — Iterative tightening, starting from fully restricted  ✅ DONE

> Six revisions (`profiles/01`–`06`). `verify.sh` codifies step 5 and reports
> fail=0. Step 4's audit found a real LaunchServices escape that every
> functional check had already passed — exactly the risk this section warned
> about, and the single most useful result of the spike.

Only proceed here once Phase 0 passes.

### Target allow-list

Written down up front so Phase 1 has an intended destination, not just a
denial-fixing loop that stops whenever the pain stops. Anything not on this
list that ends up allowed should be a deliberate, named addition — not a
side effect of chasing a denial.

- Vault (read/write, working dir): `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Brian's Vault`
- Bear (**read-only**): `~/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data`
- gcalcli creds (read, possibly write if the OAuth token refreshes in place):
  `~/.gcalcli`
- Plus whatever `claude` itself needs to run: its own config/cache dirs,
  node/npm, system libraries.

1. Start from `(version 1) (deny default)` plus whatever bare minimum lets
   the process start at all (reading system libraries/dyld cache, basic
   mach lookups, process-exec for node/npm/its own subprocesses).
2. Run it. When something breaks, find the denial — `log stream --style
   syslog --predicate 'eventMessage contains "deny"'` (or Console.app) is
   the fastest way to see exactly what Seatbelt blocked and on what path/
   operation.
3. Add the narrowest rule that fixes that one denial. Re-run. Repeat.
4. Keep going until:
   - `claude` starts cleanly and the debug log shows no sandbox-related
     crashes.
   - Remote Control still pairs and shows in Fleet (re-verify — a tighter
     profile could break the exact thing Phase 0 proved worked).
   - Core MCP servers needed for real use start (playwright/chromium is the
     hard one — expect several iterations here; **cut it from the profile
     entirely for early iterations** and add it back once the base process
     is stable, to keep the denial noise attributable).
   - **Before calling this phase done, re-read the whole profile against
     the target allow-list above.** The denial-fixing loop can "succeed"
     while quietly allowing far more than intended — the fastest fix for a
     painful denial (npm cache, Chromium's profile dir) is often a broad
     `(subpath "/Users/...")`, which would defeat the point while still
     passing every check in step 5. Flag and narrow anything that isn't on
     the list or isn't an explicitly-justified addition.
5. **Verify the actual security property**, not just "it starts":
   - From inside the session, try to read/write outside the allowed
     project root (e.g. `~/.ssh`, another project directory, Keychain
     files). Confirm denial.
   - Try a non-filesystem escape path too: drive another app via
     `osascript`/Apple Events (e.g. ask Mail or Finder to do something) to
     see whether IPC/mach-lookup is actually scoped down, not just file
     I/O. A hostile operator doesn't need file access if they can get an
     unsandboxed process to act as a confused deputy.
   - Run whatever the in-app equivalent of turning off `sandbox.enabled` is
     (`/sandbox` or similar), then repeat the same read/write (and IPC)
     attempts. Confirm they're **still** denied — this is the actual point
     of the prototype, not a side check.

Keep every profile revision in `profiles/`, numbered, so the iteration is
visible. Log what broke and why in `NOTES.md` as we go — useful for writing
the real profile later and for anyone picking this up who wasn't in the
room for the trial-and-error.

## Phase 2 (stretch) — Network restriction  ❌ DESCOPED

> Resolved by decision rather than investigation: full internet access is
> wanted so the agent can do web research. `(allow network*)` stays and no
> `pf` companion is needed. The trade-off this accepts is recorded in
> NOTES.md — the profile bounds what the agent can *reach on this machine*,
> not what it can *send off it*, so allow-listed data (vault, Bear, gcalcli
> tokens) remains exfiltratable. Accepted deliberately.

Seatbelt's network filtering is coarser than filesystem (mostly local/remote
port-based, not hostname/SNI-based), so a clean "only allow
bridge.claudeusercontent.com and api.anthropic.com" rule may not be directly
expressible. Treat this as an open question rather than an assumed win —
if it's not cleanly achievable in Seatbelt alone, that's a real finding, not
a failure, and would push network isolation toward a companion mechanism
(e.g. `pf` rules) rather than trying to force it into the `.sb` profile.

## Directory layout

As built:

```
sandbox-exec-prototype/
  PLAN.md                  this file
  NOTES.md                 AUTHORITATIVE record — findings, revision log, open items

  profiles/
    00-allow-all.sb              Phase 0 control
    01-deny-default.sb           starts, fails at auth
    02-auth-and-tools.sb         keychain via securityd — authenticates
    03-target-allowlist.sb       vault rw / Bear ro / gcalcli rw — ESCAPABLE
    04-no-launchservices.sb      closes the `open -a` hole
    05-playwright.sb             headless Chromium
    06-production.sb.template    05 minus spike scaffolding; templated paths

  # spike tooling (interactive)
  run-test.sh              sandbox-exec + claude --remote-control, from a terminal
  probe.sh                 `claude -p` under a profile + every Seatbelt denial
  probe-chromium.sh        headless Chromium under a profile + denials
  verify.sh                the security assertions (Phase 1 step 5) — 17 checks
  verify-browser.sh        the browser container's assertions — 12 checks
  verify-detection.sh      bot-detection scores (sannysoft / incolumitas) against the live browser job

  # fleet (launchd)
  fleet-common.sh          config + plist/profile rendering
  sbx-agent-run.sh         one agent, foreground, launchd-managed
  sbx-browser-run.sh       the browser as an Apple `container`, CDP republished to loopback
  sbx-start.sh / sbx-stop.sh / sbx-status.sh
  pty-run.py               pty with a real window size (replaces `script`)
  fleet-settings.json      installed as --settings; in-app sandbox off
  agent-browser-config.json installed via AGENT_BROWSER_CONFIG; points at CDP

  generated/               rendered per-agent profiles   (gitignored)
  launchd/                 rendered plists               (gitignored)
  browser-profile/         bind-mounted browser data dir; fully ephemeral — cookies/localStorage do not
                           survive a container restart. The fingerprint seed that keeps the device
                           stable across restarts is config in fleet-common.sh, not state in here.
                           (gitignored)
  scratch/ logs/           spike working dirs            (gitignored)
```

Fleet runtime state lives outside the repo in `~/.claude-sbx/`
(logs, and the installed copy of `pty-run.py`).

## Success criteria

1. ✅ A `sandbox-exec`-wrapped native `claude --remote-control` session pairs
   and appears in Claude Desktop's Fleet view.
2. ✅ Filesystem access outside the allowed roots is denied at the OS level,
   confirmed by direct test from inside a live session.
3. ✅ That denial survives toggling Claude Code's own in-app sandbox setting
   off — proving the boundary doesn't depend on the app's cooperation.
   Discriminator: `~/dev`, which Claude Code's own sandbox allows and this
   profile denies, so the denial can only be attributed to Seatbelt.
4. ❌ (Stretch) Network egress scoped — descoped by decision.

## Open questions / risks — resolved

- ~~Unconfirmed whether the Apple-subscription/Remote-Control check is really
  platform-based.~~ **It is.** Same account, same billing, same CLI: native
  pairs, container doesn't.
- ~~The subprocess tree is wide; expect real iteration, especially Chromium.~~
  Chromium took three iterations and — the good news — runs fine while denied
  windowserver, dock, LaunchServices, pasteboard, tccd and CoreLocation.
- ~~Real risk is "does the final profile match the target allow-list".~~
  Correct call: the audit caught a live escape. Now codified in `verify.sh`.

**New risk found along the way:** an unexplained `mach-lookup` grant is a
potential escape, not a harmless convenience. Two speculative entries added in
revision 01 let a sandboxed process launch unconfined GUI apps via
LaunchServices, while passing every filesystem and Apple Events check. Every
name in that list should trace to an observed denial *and* a reason.

## Next session starts here

**Read `NOTES.md` first** — it carries the findings and the full open list.

Current state: `sbx-agent-1` runs under launchd, sandboxed, cwd = the vault,
paired to Fleet — **plus a second launchd job, `com.brianlow.claude-sbx.browser`,
running the browser as an Apple `container`** (`cloakhq/cloakbrowser:0.5.3`),
which the agent reaches only over CDP on `127.0.0.1:9222`. `./sbx-status.sh`
to check both, `./sbx-start.sh` / `./sbx-stop.sh` to control. The Apple
Container *fleet* (the agent-side container world this prototype replaced) is
untouched and not running — the browser container is unrelated to that and is
the current, live arrangement.

The browser was never put in the agent's Seatbelt profile, and now there is no
Seatbelt profile for it at all: `profiles/07-browser.sb.template` and
`probe-cloakbrowser.sh` are deleted (commit `9fc9211`). A Linux container has
no LaunchServices or WindowServer to grant in the first place, which is what
made the container the actual fix rather than a workaround. Read "Browser in a
container" in NOTES.md before touching the browser job; the split is still
load-bearing, and the reason it is safe is unchanged: **launchd owns the
browser's command line, not the agent.** Stated precisely, because an earlier
draft of this paragraph overclaimed it:

- **Structurally fixed** — literal argv elements in `sbx-browser-run.sh`: the
  image reference, the single `--mount`, the `--publish` host address
  `127.0.0.1`, and `cloakserve`'s flag list. A hostile session operator cannot
  add `--allow-file-access`, repoint the profile dir, add a mount, load an
  extension, or move CDP off loopback.
- **Operator-influenceable** — the browser plist has no `EnvironmentVariables`
  dict, so the job inherits the launchd gui-domain environment, and
  `launchctl setenv` is reachable from inside the agent's Seatbelt profile.
  `BROWSER_FINGERPRINT` and `BROWSER_CDP_PORT` read from that environment. Each
  is passed as one fully-quoted argv element (the seed via `--env`,
  dereferenced by name *inside* the container, never spliced into the `sh -c`
  string), so the most either can do is change its own value: a different seed,
  or a different loopback port. Neither can grow the argv.

CDP has no verb that spawns a process, and the browser holds nothing of value.

Ground rule still in force: **nothing outside `sandbox-exec-prototype/` gets
modified** — not `entrypoint.sh`, `agent-run.sh`, `common.sh`, `Dockerfile`,
or the `../launchd/` plists.

Needs a decision from Brian, not more engineering:

1. **Full Disk Access.** Bear reads are blocked by TCC, not Seatbelt, and
   `sandbox-exec` can only subtract permissions. Separately, the iCloud TCC
   grant is keyed to the versioned binary path, so **every Claude Code update
   silently drops vault access until someone clicks Allow.** FDA addresses
   both; it's one decision, not two.
2. **The Keychain grant** — the widest rule in the profile, and unavoidable
   for this auth mechanism.

Ready to build:

3. **Playwright end-to-end.** Headless Chromium is verified under the profile
   directly, but `claude → @playwright/mcp → browser` has never been driven
   from inside a live session. Lower priority now that the containerized
   browser path works end to end (see NOTES.md, "Browser in a container").
4. **Scale past one agent.** `AGENTS=(1)` in `fleet-common.sh`. Worth thinking
   about whether N agents sharing one vault cwd is actually wanted — note the
   container fleet had the same property, so this isn't a regression.
5. **Reset watcher.** Deliberately not built: the existing one is wired to the
   old `reset-agents.sh`, and two watchers on the same sentinel would fight.
   Needs its own sentinel and its own reset script if wanted.
6. **Narrow `/private/tmp`** to a private temp dir — it's currently granted
   read/write and is world-writable and shared with every process on the Mac.
7. **Update the vault docs** for the native fleet — they still document
   container mount paths. `Browser Automation.md` — **done** (rewritten for the
   split-sandbox CDP setup). `Bear DB.md` — still stale, and blocked on the FDA
   decision above, since whether Bear is readable at all depends on it.

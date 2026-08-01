# Sandbox-exec prototype

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

## Phase 0 — Is there any path to success at all?

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

## Phase 1 — Iterative tightening, starting from fully restricted

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

## Phase 2 (stretch) — Network restriction

Seatbelt's network filtering is coarser than filesystem (mostly local/remote
port-based, not hostname/SNI-based), so a clean "only allow
bridge.claudeusercontent.com and api.anthropic.com" rule may not be directly
expressible. Treat this as an open question rather than an assumed win —
if it's not cleanly achievable in Seatbelt alone, that's a real finding, not
a failure, and would push network isolation toward a companion mechanism
(e.g. `pf` rules) rather than trying to force it into the `.sb` profile.

## Directory layout

```
sandbox-exec-prototype/
  PLAN.md              (this file)
  NOTES.md             (running log: what broke, what fixed it, open questions)
  profiles/
    00-allow-all.sb
    NN-<short-description>.sb   (numbered, most-restricted-so-far last)
  run-test.sh          (wraps sandbox-exec + claude invocation, takes a
                         profile path + session name + debug log path)
```

## Success criteria

1. A `sandbox-exec`-wrapped native `claude --remote-control` session pairs
   and appears in Claude Desktop's Fleet view.
2. Filesystem access outside the allowed roots is denied at the OS level,
   confirmed by direct test from inside a live session.
3. That denial survives toggling Claude Code's own in-app sandbox setting
   off — proving the boundary doesn't depend on the app's cooperation.
4. (Stretch) Network egress is scoped to what the agent actually needs.

## Open questions / risks

- Unconfirmed whether the Apple-subscription/Remote-Control check is really
  platform-based — Phase 0 is the direct test of that theory using this
  mechanism specifically.
- The subprocess tree (node, npm, chromium, git, ripgrep, MCP servers) is
  wide; expect Phase 1 to take real iteration, especially around Chromium.
- Real risk isn't "does the loop terminate" but "does the final profile
  match the target allow-list" — see the audit step added to Phase 1.

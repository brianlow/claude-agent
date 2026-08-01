# Containerized Stealth Browser — Design

**Date:** 2026-08-01
**Status:** Approved (pending spec review)

## Problem

`sbx-agent-1` drives CloakBrowser over CDP, and CloakBrowser runs on the host in
its own Seatbelt profile (`profiles/07-browser.sb.template`, launchd job
`com.brianlow.claude-sbx.browser`). It works and it passes bot detection — but
that profile holds **LaunchServices and WindowServer**, the two grants revision
04 and revision 05 of the agent profile deliberately removed to close the
`open -a` confused-deputy escape.

`NOTES.md` states the consequence plainly: *"the rev-04 escape is moved, not
deleted."* Code execution in the browser process — a Chromium exploit from a
hostile page — lands in a sandbox that can launch unconfined GUI apps. The
mitigation today is that there is nothing of value in reach there, which is a
statement about the blast radius, not about the capability.

CloakBrowser cannot simply be folded back into the agent's profile. It aborts in
`TransformProcessType` without LaunchServices and `SIGSEGV`s in
`-[NSWindow _close]` without WindowServer, even under `--headless`, because it
ships only the full `Chromium.app` — the C++ fingerprint patches *are* the
browser, so there is no `headless_shell` to retreat to.

## Goals

- **Remove the GUI-privileged Seatbelt profile from the machine entirely.** No
  process on this Mac holds WindowServer + LaunchServices on the agent's behalf.
- **Keep the design that already works**: launchd owns the browser, the agent
  reaches it only over CDP on loopback, and the agent never launches it.
- **Do not regress bot-detection results.** The browser binary changes
  (macOS Chromium 145 / 26 patches → Linux Chromium 146 / 58 patches), so
  "still passes" has to be measured, not assumed.
- **Keep the agent profile untouched** — `verify.sh` stays 16/16.

## Non-goals

- No change to the agent (`sbx-agent-run.sh`, `profiles/06-production.sb.template`,
  the pty launcher, `fleet-settings.json`).
- **No Docker.** Apple `container` only, by decision. If a step doesn't work
  under Apple `container`, the answer is a different approach within it, not a
  second runtime.
- Not solving IP reputation, proxies, or CAPTCHA solving. Detection passes today
  from this host's residential IP; nothing here changes the egress path.
- Not logging the browser into retailer accounts (see Persistence).
- Not scaling past one browser.

## Approach

Swap the browser's substrate from a Seatbelt profile to a Linux container. The
topology is unchanged:

| | today | proposed |
|---|---|---|
| agent | native, Seatbelt profile 06 | **unchanged** |
| browser | native, Seatbelt profile 07 (WindowServer + LaunchServices) | Apple container, `cloakhq/cloakbrowser`, `cloakserve` |
| link | CDP on 127.0.0.1:9222 | **unchanged** |
| owns the browser command line | launchd | launchd |

The last row is the load-bearing security property and it survives intact.
launchd owns the `container run` invocation, so a hostile session operator still
cannot add `--allow-file-access` (which would let pages read local files),
repoint `--user-data-dir`, load an extension, or add a mount. The agent's only
reach remains CDP, and CDP has no verb that spawns a process.

What changes is the blast radius of code execution *in the browser*: from a
macOS process holding the GUI grants, to a Linux VM holding one volume and one
published port.

### Why CloakBrowser, and why the container is an upgrade rather than a lateral move

- **Camoufox** is a Firefox fork that deliberately does not speak CDP — it uses
  Juggler, on the argument that CDP is itself a detection surface. Adopting it
  means discarding both the CDP design and `agent-browser`.
- **Firecrawl** is not a browser. It is a scrape-to-markdown API service;
  self-hostable, but there is no CDP endpoint to drive, and its evasion story
  leans on its hosted proxy pool.
- **CloakBrowser** is already proven in this setup, and its Linux build carries
  **58 free patches against macOS's 26** (Pro: 71 on both). Moving to Linux
  buys fingerprint patches, not just isolation.

`NOTES.md` already establishes that a GPU-less environment does not
automatically lose the WebGL fingerprint — forced onto SwiftShader, CloakBrowser
still reported a fabricated `ANGLE Metal Renderer: Apple M2 Max` on an M1 Pro
host. That finding is what makes a VM viable at all, and Phase 1 tests whether
it holds when there is no GPU to lie about.

### Image

`cloakhq/cloakbrowser`, pinned to a version tag (`0.5.3`, matching the installed
npm package), never `latest`. Verified from the registry: OCI image index with a
real `linux/arm64` manifest, cosign signatures, version tags tracking the npm
releases. Xvfb and the Linux fonts are baked in — fonts being the usual Linux
fingerprint tell.

The image's `cloakserve` command is a CDP multiplexer listening on 9222 with
per-connection fingerprint seeds, i.e. the server side of the design
`sbx-browser-run.sh` currently hand-rolls.

### Persistence

A host directory (`~/.claude-sbx/browser-profile`) is bind-mounted for the
user-data-dir, so cookies and history accrue across restarts — a browser that
arrives with zero cookies on every launch is itself a mild tell and will eat more
challenges.

**No account logins.** The volume therefore holds no retailer credentials. This
matters more in a container than on the host: `NOTES.md` records
`Keychain lookup failed … (-50)`, meaning Chromium cannot keychain-encrypt
cookies at rest, and that remains true in Linux (no OS keyring in the image).

## Components

Filenames and the launchd label `com.brianlow.claude-sbx.browser` are kept, so
`sbx-start.sh` / `sbx-stop.sh` / `sbx-status.sh` barely move.

**Rewritten**

- `sbx-browser-run.sh` — ensure `container system status`, `container rm -f` the
  stale container, then foreground `container run` (no `-d`, so launchd tracks
  the process) with the pinned image, `--publish 127.0.0.1:9222:9222`, and the
  profile bind mount. Mirrors `../agent-run.sh`, which is the established pattern
  for a launchd-supervised Apple container in this repo.
- `verify-browser.sh` — the current 20 Seatbelt assertions no longer apply. It
  asserts container properties instead:
  1. CDP answers on `127.0.0.1:9222`.
  2. CDP is **not** reachable on the host's LAN address (this is a gate, see
     Risks).
  3. The container has no mounts beyond the profile directory.
  4. The browser cannot read a host path (probe a known file through CDP
     `file://` and confirm failure).
  5. The agent's fallback path is still denied — `agent-browser` auto-launches
     `/Applications/Google Chrome` when no CDP port answers, so assert directly
     (under the agent profile via `sandbox-exec`, without stopping the browser)
     that exec'ing that binary still fails. A wedged browser must mean "no
     browser", never "an unconfined browser".
- `fleet-common.sh` — the browser block becomes image / tag / container name /
  volume path / CDP port. `render_browser_profile` and `cloak_bin` are deleted.
  `browser_pid` no longer matches a `--remote-debugging-port` command line;
  `browser_state` queries container state plus the existing `/json/version`
  probe, which stays because it is the only thing that detects a wedged browser
  (launchd's `KeepAlive` sees only that the process exists).

**New**

- `verify-detection.sh` — drives the running container over CDP against
  `bot.incolumitas.com` and sannysoft, prints the scores, and records them in
  `NOTES.md`. Required because the browser binary changes; "better patches on
  paper" is not evidence.

**Deleted**

- `profiles/07-browser.sb.template`
- `probe-cloakbrowser.sh`
- `~/.claude-sbx/browser/` (the old macOS user-data-dir)

**Docs**

- `NOTES.md` gains a section for this work. The existing "CloakBrowser — built"
  section gets a *superseded* banner rather than deletion, matching the
  convention already used there for the earlier prediction section.
- `PLAN.md`'s "Next session starts here" is updated: the split is still
  load-bearing, but the browser half is now a container.

## Data flow

```
launchd ──exec──> sbx-browser-run.sh ──exec──> container run cloakhq/cloakbrowser:0.5.3 cloakserve
                                                     │
                                              Xvfb + CloakBrowser
                                                     │ CDP :9222 (0.0.0.0 inside the container)
                                                     │
                                          --publish 127.0.0.1:9222:9222
                                                     │
sbx-agent-1 (Seatbelt profile 06) ──agent-browser──> 127.0.0.1:9222
        via ~/.claude-sbx/agent-browser.json { "cdp": "9222" }
```

Chromium binds CDP to `127.0.0.1` inside the container by default, so it must
listen on `0.0.0.0` *within the container's network namespace* to be publishable.
`cloakserve` is built for this. Chromium's Host-header validation accepts IP
literals, so a client connecting to `127.0.0.1:9222` passes it.

The agent side needs no code change: `agent-browser connect` accepts a port or a
full URL, and the agent profile already allows `network*`.

## Build order

Each phase ends in a check that can fail loudly.

**Phase 0 — plumbing.** `container system start`; pull the pinned image; run
`cloakserve` by hand; `curl /json/version` from the host; `agent-browser connect`
then `open example.com`. Resolve where the image expects the user-data-dir so the
bind mount lands in the right place.
*Exit:* a page loads over CDP from the host.

**Phase 1 — detection.** `verify-detection.sh` against the container. Compare
against the macOS baseline in `NOTES.md`. Specifically confirm WebGL yields a
working context with a plausible renderer string in a genuinely GPU-less VM.
*Exit:* scores recorded, and no worse than the host build.

**Phase 2 — the swap.** Rewrite `sbx-browser-run.sh`, `fleet-common.sh`,
`verify-browser.sh`; delete profile 07 and `probe-cloakbrowser.sh`; reload the
launchd job.
*Exit:* `verify-browser.sh` passes, and `verify.sh` on the agent profile is
**still 16/16**.

**Phase 3 — end to end.** Drive the container from a live Fleet remote-control
session, which `NOTES.md` lists as still open even for the host browser.
*Exit:* a real product-research task runs from the desktop app.

## Risks

1. **Port exposure is a gate, not a detail.** Apple `container` gives each
   container its own IP on a vmnet subnet, and CDP is unauthenticated. `container
   run -p [host-ip:]host-port:container-port` exists in CLI 0.11.0 on macOS
   26.5.2, but "the flag is accepted" is not "the port is confined to loopback."
   Phase 0 must confirm, from another device on the LAN and by inspecting the
   listening socket, that 9222 is not reachable off-host — *and* that the
   container's own vmnet IP does not expose 9222 to anything beyond this Mac.
   With Docker off the table, failing this means finding a different Apple
   `container` networking mode, not switching runtimes.
2. **Free tier is one concurrent session,** and `cloakserve` multiplexes by
   spawning a browser per fingerprint seed. Plan is a single seed; Phase 0
   confirms one connection is enough and that additional connections fail
   visibly rather than silently degrading. The container also calls
   `cloakbrowser.dev` at startup to validate the license — a new outbound
   dependency, and a new failure mode if it is unreachable.
3. **No GPU in the VM.** The SwiftShader finding says the renderer string is
   spoofed rather than observed, but it was measured on a machine that had a GPU.
   Phase 1 checks it where there is none.
4. **CDP stays unauthenticated,** so any local process can drive the browser.
   Unchanged from today; loopback is the whole boundary and there is no auth to
   add.
5. **A Linux fingerprint from a residential IP** is a different profile than what
   passes today. Phase 1 is the check; Phase 3 is the real-world one.
6. **Two failure modes launchd cannot see.** A wedged-but-running browser was
   already invisible to `KeepAlive`; a container adds "container alive, browser
   inside it dead." Both are covered by keeping the `/json/version` probe in
   `sbx-status.sh` as the source of truth rather than the pid.

## Success criteria

1. No Seatbelt profile on this machine grants WindowServer or LaunchServices —
   `profiles/07-browser.sb.template` is gone and its launchd job runs a container.
2. `verify.sh` on the agent profile: still 16/16.
3. `verify-browser.sh`: passes, including the off-host CDP reachability check.
4. `verify-detection.sh`: scores recorded and no worse than the host baseline.
5. A live Fleet session drives the container to research a real product.

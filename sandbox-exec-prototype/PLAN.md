# Sandbox-exec Fleet Hardening — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the sandbox-exec fleet's escape path to the host (`~/.claude` and the login keychain, both writable from inside), stand up an egress chokepoint, and settle whether LAN egress can be closed at all — without weakening any property the current profile already proves.

**Architecture:** Three changes, in dependency order. (1) The fleet gets its own `HOME`, so every writable grant lands in `~/.claude-sbx/home` instead of the host's home directory; a one-way seed repopulates the host-owned pieces on every launch. (2) The keychain is dropped from the profile outright — Claude Code needs a credential *store*, not the keychain, and falls back to `~/.claude/.credentials.json` when the keychain is unreachable (verified below), so a seeded file replaces the widest grant in the profile. (3) LAN egress is **not** fixed: Seatbelt cannot express "deny RFC1918" and the loopback-only design that would work breaks `--remote-control`. Task 5 still lands the proxy — it carries the API traffic and is where a domain allow-list goes — but Task 6 is a documented decision, not an edit.

**Tech Stack:** bash, Apple Seatbelt (`sandbox-exec`), launchd, `/usr/bin/python3` (stdlib only — already a fleet dependency via `pty-run.py`), `security(1)`, Apple `container` (browser only, unchanged).

> **STATUS 2026-08-03: Tasks 1–4 are DONE and live.** Five agents running on
> `HOME=~/.claude-sbx/home` with the host's `~/.claude` and the login keychain
> both denied. `sbx-verify.sh` pass=34 fail=0 (sections `[5]`–`[8]` are new),
> `sbx-verify-browser.sh` 12/12. Remaining: Tasks 5–8 (proxy, LAN decision,
> NOTES, README).
>
> **The plan was wrong about one thing that matters, and it cost a fleet
> restart.** Task 2 and Task 4 are *not separable*. The login keychain is
> located **relative to `$HOME`**, so the moment the fleet got its own home the
> keychain became unreachable no matter what the profile granted:
>
> ```
> HOME=/Users/brianlow                     -> keychain item FOUND
> HOME=/Users/brianlow/.claude-sbx/home    -> NOT FOUND (rc=44)
> ```
>
> The correction added below on 2026-08-02 spotted the coupling but blamed the
> profile grant and proposed spelling it `__HOSTHOME__` to defer it. That was
> tried and it does not work — the grant was never the binding constraint. Five
> agents came up `Not logged in`, the fleet was rolled back, and Tasks 2+3+4
> landed together as one commit.
>
> Two things that made this worse than it needed to be, worth keeping in mind
> for Tasks 5–8:
>
> - **`sbx-verify.sh` reported `fail=0` on the broken fleet.** It asserts the
>   profile's properties, and every one of them held. It has no assertion that
>   an agent can authenticate. Same blind spot Task 6 already warns about for
>   the bridge — the verifier cannot see a fleet that is confined and useless.
> - **`grep "Failed to authenticate"` is the wrong probe.** This Claude Code
>   version prints `Not logged in · Run /login` in the TUI banner and nothing
>   matching that string in the log. Step 9 below still says to grep for it.
>   Use the banner, or better, add a real auth assertion.

**Revised 2026-08-02 after a read-through against the live files.** Five corrections, all in Tasks 1–3, all folded in below:

1. **Task 1 is already done** — the three dangling references were fixed in `87c2693`. Verify and move on.
2. **Task 2 breaks authentication as originally written.** Remapping the keychain grant to the fleet home takes effect at the end of Task 2, not Task 4, and the seeded `.credentials.json` is a husk — so all five agents come back unauthenticated. Task 2 Step 5 now makes this a deliberate choice; Step 9's "authentication still works at this point" was simply wrong.
3. **`render_profile` expands `${HOME}` at call time**, and `sbx-agent-run.sh` reassigns `$HOME` *before* calling it — so `__LOGDIR__` would have rendered under the fleet home and hung every agent on an unreadable `pty-run.py`. Fixed with a `HOST_HOME` captured at source time.
4. **Two template sites were unlisted**: the Bear write-deny backstop (`:321`, same orphaning defect the plan already caught for `.ssh`/`.aws`/`.gnupg`) and the `process-exec*` grant on `~/.npm` (`:83`).
5. **Task 3's `ccline` test could pass without proving anything** — `! grep -q TAMPERED` is true for a file that does not exist.

Nothing in Tasks 4–8 was re-verified at this depth; treat their step-level details as unreviewed.

## Global Constraints

- **No new package dependencies.** Everything uses macOS-stock binaries. `/usr/bin/python3` is already required by `pty-run.py`.
- **Fail closed.** Every change must degrade to "the agent can't do the thing" rather than "the agent falls back to an unconfined path." This is the existing design rule from `sbx-agent-run.sh:100-106`; keep it.
- **The profile is the boundary; env vars are convenience.** Never rely on an environment variable the agent can unset for a security property. If unsetting it breaks the agent, that's correct.
- **Every grant traces to an observed denial.** Existing rule from `NOTES.md:157`. Do not add a rule to silence a denial without recording the denial text in a comment above it.
- **Last match wins in Seatbelt.** Backstop `deny` rules go at the bottom of the profile and must stay there.
- **Do not copy host Claude Code history into the fleet.** Explicit requirement: `projects/`, `history.jsonl`, `file-history/`, `shell-snapshots/`, `sessions/`, `todos/`, `debug/`, `telemetry/`, and `.claude.json`'s `projects` key stay on the host.
- **Verification is `sbx-verify.sh`.** A change is not done until the script asserts it. Tests come before implementation in every task below.
- Fleet home path: `~/.claude-sbx/home` (alongside the existing `~/.claude-sbx/logs`).
- Proxy listen address: `127.0.0.1:8888`.
- **Renumber the verifier sections as you go.** `sbx-verify.sh` currently ends at
  `[4]`; the tasks below append blocks labelled `[7]`–`[11]`, which was written
  against a draft that had more sections than the committed script does. Land them
  as `[5]`–`[9]` — the numbers are only labels, but a gap reads as "two sections
  were deleted" to the next person.
- **`HOST_HOME`, not `$HOME`, anywhere in `sbx-common.sh` that means "the human's
  home".** From Task 2 onward `sbx-agent-run.sh` reassigns `$HOME`, and function
  bodies expand it at call time. This has already produced one live bug in this
  plan (Task 2, Step 4).

---

## Findings this plan addresses

| # | Finding | Disposition |
|---|---|---|
| 1 | Sandboxed agents can write the host's `~/.claude`, including `settings.json` and the `ccline` statusline binary that the *host's* Claude Code executes unsandboxed | **Fix** — Tasks 2–3 |
| 2 | Keychain: is it needed? | **No — answered below.** Dropped entirely, Task 4 |
| 3 | Agents reach the whole home LAN; the container fleet's pf rules don't apply to native processes | **Blocked — see below.** Task 5 lands; Task 6 cannot as written |
| 4 | No compartmentalization between the five agents | **Deferred** — ideas recorded in Task 7, no code |
| 5 | Unauthenticated CDP on loopback is ambient authority for all local processes | **Accepted** — documented in Task 7, no code |

### Finding 2, answered: keychain access is NOT required. Drop it.

The first pass on this was wrong and the correction matters, so here is the whole chain.

What the keychain holds is one generic-password item, `Claude Code-credentials`, containing the OAuth **access token, refresh token and expiry**. It is a credential store. Nothing validates a subscription against it — `subscriptionType: pro` rides along in the same JSON blob, which is probably where the subscription intuition comes from, but the token is what authenticates.

The initial test looked conclusive and was not:

```
keychain DENIED  → "Failed to authenticate: OAuth session expired and could not be refreshed"
keychain ALLOWED → works
```

That reads as "keychain required," but it only shows *there was no usable credential anywhere else*. The reason is specific to this host:

```
~/.claude/.credentials.json   accessToken: ""   refreshToken: ""   expiresAt: 0 (epoch)
keychain item                 accessToken: 108 chars   refreshToken: 108 chars   expiresAt: valid
```

The on-disk file is a **husk** — the real tokens exist only in the keychain, so denying the keychain left claude with an empty, epoch-expired credential and nothing to refresh from.

Seed that file with the real token and the picture inverts. Tested with `~/Library/Keychains` hard-denied **and** `com.apple.SecurityServer` / `com.apple.securityd.xpc` mach-lookup denied:

```
FILE_CREDS_OK
```

**So Claude Code needs a credential store, not the keychain.** macOS prefers the keychain when it is reachable and falls back to `~/.claude/.credentials.json` when it is not. That makes Task 4 much smaller than originally planned: no fleet keychain, no `security create-keychain`, no empty-password unlock. Seed a file, deny the keychain outright, and the widest grant in the profile — `rw` on the file holding every secret Brian owns, flagged and deferred at `NOTES.md:209` — is simply gone.

**Open question this creates, and it needs a decision (Task 4, Step 6).** The seeded access token expires in hours; the refresh token on 2026-08-28. When the fleet refreshes, does the OAuth grant **rotate** the refresh token? If it does, the fleet's refresh invalidates the host keychain's copy and Brian gets logged out of his own Mac — or the reverse. Two independent refreshers of one grant is the hazard, and it exists for the keychain design too, so it is not a reason to prefer one over the other. Task 4 includes a non-destructive way to detect it.

**Unexplained, and worth knowing before trusting the same mechanism:** the container fleet's `seed_fleet_claude_home()` copies this same husk — `~/.claude-agent/claude-home/.credentials.json` also has empty tokens and an epoch expiry — yet those agents were plainly doing real work. There is no `CLAUDE_CODE_OAUTH_TOKEN`, no `ANTHROPIC_API_KEY` and no `apiKeyHelper` anywhere in the container fleet's scripts or Dockerfile. Either those agents authenticated by some path not visible in the repo, or the seed has been quietly overwriting a working credential with a husk on every launch and the fleet is currently logged out. It is not running right now, so this is untested either way. Check it before Task 4 ships.

### Finding 3, scoped: the profile cannot express this, so egress moves to loopback

Every CIDR and per-host spelling is rejected by the compiler on this machine:

```
(deny network-outbound (remote ip "192.168.1.0/24"))    → port missing in network address
(deny network-outbound (remote ip "192.168.1.1:*"))     → host must be * or localhost
(deny network-outbound (remote tcp "192.168.1.1:80"))   → host must be * or localhost
(deny network-outbound (remote ip (regex #"^192\.168\."))) → remote expects string argument
```

pf can't be keyed on the process either — `pf/claude-agent.pf` filters `on $cont_if from $cont_net`, which matches only the container bridge. A pf `user` rule would need the fleet to run as a separate uid, and that uid cannot read the vault (it lives in Brian's iCloud container).

What *does* compile and behave correctly, verified against the live profile:

```
(deny network-outbound)
(allow network-outbound (remote ip "localhost:*"))
(allow network-outbound (remote unix-socket))
```

```
router 192.168.1.1:80    blocked/closed (PermissionError)
router 192.168.1.1:443   blocked/closed (PermissionError)
internet example.com:443 blocked/closed (PermissionError)
CDP 127.0.0.1:9222       CONNECTED
DNS  api.anthropic.com   resolved → 160.79.104.10      # mDNSResponder is out-of-sandbox
```

DNS survives because resolution goes over the already-granted mach service and the actual UDP happens in `mDNSResponder`, outside the sandbox. So the shape is: sandbox allows loopback only; a proxy on loopback does the real egress and refuses private destinations. Fail-closed by construction — an agent that unsets `HTTPS_PROXY` gets no network at all rather than direct access.

**The proxy itself works. The remote-control bridge does not go through it — this blocks Task 6.**

Built and tested the proxy end to end. Policy is correct and `wss` is a non-issue: `CONNECT` is an opaque byte tunnel, so a WebSocket upgrade rides through it unmodified (verified against `echo.websocket.org`). Claude Code has genuine proxy support — undici's `EnvHttpProxyAgent` plus `setGlobalDispatcher`, reading `https_proxy` / `HTTPS_PROXY` / `http_proxy` / `HTTP_PROXY` / `NO_PROXY`. A one-shot prompt under the loopback-only profile works, and the proxy log shows exactly the expected traffic:

```
claude -p, no proxy env   → "Execution error"          (fail-closed, as designed)
claude -p, proxy env      → "PROXY_TEST_OK"
proxy log                 → api.anthropic.com:443 ×10, registry.npmjs.org:443,
                            http-intake.logs.us5.datadoghq.com:443
```

But `--remote-control` is a different path, and it does not use the dispatcher. Identical `pty-run.py` + `--remote-control` invocations, measured at 30s by `lsof` on the sandboxed claude process:

| run | established connections at 30s |
|---|---|
| real profile, full network | `→160.79.104.10:443`, `→160.79.104.10:443`, `→34.149.66.165:443` |
| loopback-only + proxy | **none**; proxy saw one transient `api.anthropic.com` CONNECT and closed it |

The bridge holds two persistent connections when it works and establishes none through the proxy. The debug logs are byte-identical between the two runs (8876 bytes each) and record no bridge activity at all, so the socket evidence is the only signal — but it is unambiguous.

**Consequence:** Task 6 as originally written produces a fleet that is confined and unreachable. That is worse than the LAN exposure it fixes. Task 6 is therefore restructured into a spike-and-decide, and it must not be merged on the strength of `sbx-verify.sh` passing — the verifier would report `fail=0` on a fleet nobody can drive.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `sbx-common.sh` | modify | Add `FLEET_HOME`, `PROXY_PORT`, `seed_fleet_home()`, `seed_fleet_keychain()`; fix the stale `PROFILE_TEMPLATE` path; add `__HOSTHOME__` to `render_profile()`; add proxy label/plist helpers |
| `sbx-agent-run.sh` | modify | Fix the stale `source` path; export `HOME`/`HTTPS_PROXY`/`NO_PROXY`; call the seeds before launch |
| `profiles/agent.sb.template` | modify | Split `__HOME__` into fleet-home (writable) and `__HOSTHOME__` (read/exec only); loopback-only egress; keychain backstop |
| `sbx-proxy.py` | **create** | Loopback HTTP/CONNECT proxy that resolves the destination and refuses RFC1918, loopback, link-local and CGNAT |
| `sbx-proxy-run.sh` | **create** | launchd wrapper for the proxy (runs *outside* the sandbox — it is the boundary) |
| `sbx-start.sh` / `sbx-stop.sh` | modify | Bootstrap / bootout the proxy job alongside the browser |
| `sbx-verify.sh` | modify | New assertions for every property above |
| `NOTES.md` | modify | Record the keychain answer, the Seatbelt network-grammar limit, and the deferred items |

---

### Task 1: Repair the in-flight rename — ALREADY DONE (verify only, 2026-08-02)

**All three references are correct in the committed tree (`87c2693`); there is nothing to edit.** Verified:

```
sbx-agent-run.sh:34   source "${SCRIPT_DIR}/sbx-common.sh"                  ✓
sbx-common.sh:32      PROFILE_TEMPLATE="${SBX_DIR}/profiles/agent.sb.template"  ✓
sbx-agent-run.sh:106  install … "${SCRIPT_DIR}/sbx-agent-browser.json"      ✓

render_profile 1 → 328 lines, sandbox-exec -f … /usr/bin/true → COMPILES
launchctl: 5 agents + browser loaded
```

Note 328 lines, not the ~343 the original Step 3 predicted — that number came from a pre-rename draft. Run Steps 3 and 4 as a smoke test if you want the confidence, skip Steps 2 and 5 entirely.

The original description follows, for the record:

> A rename pass landed mid-review and left three dangling references. The five agents are running only because they started *before* it. The next launchd restart — a crash, an idle timeout, a reboot — fails immediately and `KeepAlive` spins every 30s. It fails safe (nothing runs unsandboxed), but the fleet does not come back. Do this first; every later task needs a fleet that restarts.

**Files:**
- Modify: `sbx-agent-run.sh:35`
- Modify: `sbx-common.sh:31`
- Modify: `sbx-agent-run.sh:107`

**Interfaces:**
- Consumes: nothing.
- Produces: a fleet that restarts cleanly. All later tasks assume `./sbx-stop.sh && ./sbx-start.sh` works.

- [ ] **Step 1: Confirm the breakage before fixing it**

```bash
cd ~/dev/claude-agent/sandbox-exec-prototype
bash -n sbx-agent-run.sh && ./sbx-agent-run.sh 1
```

Expected: `sbx-agent-run.sh: line 35: .../fleet-common.sh: No such file or directory`

- [ ] **Step 2: Fix all three references**

In `sbx-agent-run.sh:35`:
```bash
source "${SCRIPT_DIR}/sbx-common.sh"
```

In `sbx-common.sh:31`:
```bash
PROFILE_TEMPLATE="${SBX_DIR}/profiles/agent.sb.template"
```

In `sbx-agent-run.sh:107` (the file is now `sbx-agent-browser.json`):
```bash
install -m 0644 "${SCRIPT_DIR}/sbx-agent-browser.json" "${AB_CONFIG}"
```

- [ ] **Step 3: Verify the profile renders and compiles**

```bash
source ./sbx-common.sh && render_profile 1 > /tmp/p.sb && wc -l /tmp/p.sb && sandbox-exec -f /tmp/p.sb /usr/bin/true && echo COMPILES
```

Expected: ~343 lines, then `COMPILES`. A zero-line file means `PROFILE_TEMPLATE` is still wrong.

- [ ] **Step 4: Recycle the fleet and confirm it comes back**

```bash
./sbx-stop.sh && ./sbx-start.sh && ./sbx-status.sh
```

Expected: five `running (pid …)` rows and a browser row.

- [ ] **Step 5: Commit**

```bash
git add sbx-agent-run.sh sbx-common.sh
git commit -m "fix(sbx): repair dangling references left by the file rename"
```

---

### Task 2: Give the fleet its own HOME

This is the fix for finding 1. Mirrors what the container fleet already does (`../common.sh:57` `seed_fleet_claude_home()`), adapted: there is no mount here, so the isolation comes from `HOME` plus the profile's placeholder split.

The template currently uses one placeholder, `__HOME__`, for two different things: state the agent legitimately writes, and host toolchain it only reads. Splitting them is the whole task.

**Files:**
- Modify: `sbx-common.sh` (add `FLEET_HOME`, `seed_fleet_home()`, extend `render_profile()`)
- Modify: `profiles/agent.sb.template` (placeholder split)
- Modify: `sbx-agent-run.sh` (export `HOME`, call the seed)
- Modify: `sbx-verify.sh` (assertions first)

**Interfaces:**
- Consumes: Task 1's working `render_profile`.
- Produces:
  - `FLEET_HOME="${HOME}/.claude-sbx/home"` — the sandboxed process's `$HOME`.
  - `seed_fleet_home()` — no args, returns 0; idempotent; safe to call on every launch.
  - `render_profile <n>` now substitutes `__HOME__` → `$FLEET_HOME` and `__HOSTHOME__` → the real `$HOME`.
  - Task 4 consumes `FLEET_HOME` for the keychain; Task 6 consumes nothing from here.

- [ ] **Step 1: Write the failing assertions**

Append to `sbx-verify.sh`, before the summary block:

```bash
echo "--- [7] the host's ~/.claude must be unreachable"
check "read  host ~/.claude/settings.json"  deny  sb /bin/cat "${HOME}/.claude/settings.json"
check "write host ~/.claude probe"          deny  sb /usr/bin/touch "${HOME}/.claude/.sbx-verify-probe"
check "write host ccline statusline binary" deny  sb /bin/test -w "${HOME}/.claude/ccline/ccline"
check "read  host session transcripts"      deny  sb /bin/ls "${HOME}/.claude/projects"
check "read  host ~/.claude.json"           deny  sb /bin/cat "${HOME}/.claude.json"
check "write host ~/.npm"                   deny  sb /usr/bin/touch "${HOME}/.npm/.sbx-verify-probe"

echo "--- [8] the fleet's own home must work"
check "write fleet ~/.claude"               allow sb /usr/bin/touch "${FLEET_HOME}/.claude/.sbx-verify-probe"
check "read  host claude install (ro)"      allow sb /bin/ls "${HOME}/.local/share/claude"
check "write host claude install"           deny  sb /usr/bin/touch "${HOME}/.local/share/claude/.sbx-verify-probe"
rm -f "${FLEET_HOME}/.claude/.sbx-verify-probe"
```

- [ ] **Step 2: Run it and watch the host-`~/.claude` block fail**

```bash
./sbx-verify.sh
```

Expected: the six `[7]` checks report `expected deny, got allow`. The `[8]` fleet-home checks fail too (`FLEET_HOME` is unset — that is fine, they pass by the end of the task).

- [ ] **Step 3: Add the fleet home and its seed to `sbx-common.sh`**

Above `LOG_DIR`, pin the host home **before** anything can reassign `$HOME`. This
is not defensive decoration — see Step 4; `render_profile` reads `${HOME}` at call
time, and `sbx-agent-run.sh` reassigns it before calling.

```bash
# The real home directory, captured at source time. Everything below that must
# mean "the human's home" uses this, never $HOME — sbx-agent-run.sh reassigns
# $HOME to FLEET_HOME before it calls render_profile.
HOST_HOME="${HOME}"
```

Below the `LOG_DIR` line:

```bash
# The fleet's own HOME. Every writable grant in the profile resolves here, so an
# agent that rewrites settings.json, a plugin hook, or the ccline binary rewrites
# the FLEET's copy — which launchd repairs from the host original within 30s.
# The host's ~/.claude is not in the profile at all.
FLEET_HOME="${HOST_HOME}/.claude-sbx/home"
```

And the seed function:

```bash
# Populate ${FLEET_HOME} from the host. One-way: host → fleet, never back.
# Re-run on every launch, so anything an agent rewrote is REPAIRED on restart
# (launchd KeepAlive, <=30s).
#
# Copies only what an agent needs to START. Deliberately absent, and this is a
# hard requirement rather than an oversight: projects/, history.jsonl,
# file-history/, shell-snapshots/, sessions/, todos/, debug/, telemetry/. Those
# are Brian's own session transcripts and the fleet has no business reading them.
seed_fleet_home() {
  mkdir -p "${FLEET_HOME}/.claude" "${FLEET_HOME}/Library/Keychains" "${FLEET_HOME}/.npm"
  chmod 700 "${FLEET_HOME}"

  # Directories the host owns: mirror exactly. --delete removes agent additions,
  # which is the repair property — a planted file in plugins/ does not survive.
  local d
  for d in plugins ccline; do
    [ -d "${HOME}/.claude/${d}" ] || continue
    rsync -a --delete "${HOME}/.claude/${d}/" "${FLEET_HOME}/.claude/${d}/"
  done

  # Flat files the host owns. .credentials.json is copied for parity with the
  # container fleet; on macOS the live token is in the keychain (see
  # seed_fleet_keychain), so this is belt-and-braces, not the auth path.
  local f
  for f in .credentials.json settings.json statusline-ps1.sh; do
    [ -f "${HOME}/.claude/${f}" ] || continue
    cp -p "${HOME}/.claude/${f}" "${FLEET_HOME}/.claude/${f}"
  done

  # ~/.claude.json carries 16 project entries with exampleFiles — host paths the
  # fleet must not see. Strip `projects` wholesale and re-add ONLY the vault,
  # pre-trusted, so the agent doesn't hit the trust dialog on a fresh home.
  if [ -f "${HOME}/.claude.json" ]; then
    VAULT="${VAULT}" /usr/bin/python3 - "${HOME}/.claude.json" "${FLEET_HOME}/.claude.json" <<'PY'
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src))
d["projects"] = {os.environ["VAULT"]: {"hasTrustDialogAccepted": True,
                                       "hasCompletedProjectOnboarding": True}}
json.dump(d, open(dst, "w"))
PY
    chmod 600 "${FLEET_HOME}/.claude.json"
  fi
  return 0
}
```

- [ ] **Step 4: Split the placeholder in `render_profile()`**

```bash
render_profile() {
  local n="$1"
  sed -e "s|__HOME__|${FLEET_HOME}|g" \
      -e "s|__HOSTHOME__|${HOST_HOME}|g" \
      -e "s|__VAULT__|${VAULT}|g" \
      -e "s|__LOGDIR__|${HOST_HOME}/.claude-sbx|g" \
      "${PROFILE_TEMPLATE}"
}
```

**`HOST_HOME`, not `$HOME`, in both of the last two — this is the trap in this task.** The `${HOME}` inside a function body is expanded when the function is *called*, not when `sbx-common.sh` is sourced. `sbx-agent-run.sh` exports `HOME="${FLEET_HOME}"` at line ~58 (Step 7) and calls `render_profile` at line 61, so a `${HOME}`-spelled `__LOGDIR__` renders as `~/.claude-sbx/home/.claude-sbx`. The agent then has no read grant on the real `~/.claude-sbx`, where `pty-run.py`, `settings.json` and the debug log live — and `pty-run.py` is read *inside* the sandbox (`sbx-agent-run.sh:133`), so the agent hangs at startup with no useful error.

The four shell variables Step 7's note calls out (`CLAUDE_BIN`, `VAULT`, `LOG_DIR`, `SETTINGS`) genuinely are expanded at source time and genuinely are fine. That asymmetry is exactly what makes this easy to miss.

Order of the first two lines does not matter: `__HOSTHOME__` does not contain `__HOME__` as a sed-matchable substring at the point `sed` scans it — `s|__HOME__|` requires the leading underscores. Verify with Step 6 rather than trusting either claim.

- [ ] **Step 5: Retarget the template's placeholders**

In `profiles/agent.sb.template`, change these to `__HOSTHOME__` — read-only host toolchain and credentials that must stay on the host:

```
(allow process-exec* ... (subpath "__HOSTHOME__/.local/share/claude")
                         (subpath "__HOSTHOME__/.asdf")
                         (subpath "__HOSTHOME__/Library/Caches/ms-playwright"))
(allow file-read* ... (subpath "__HOSTHOME__/.asdf")
                      (literal "__HOSTHOME__/.tool-versions"))
(allow file-read* (subpath "__HOSTHOME__/.local/share/claude"))
(allow file-read* (literal "__HOSTHOME__/.local/bin"))
(allow file-read* (literal "__HOSTHOME__/.gitconfig")
                  (literal "__HOSTHOME__/.gitignore_global")
                  (subpath "__HOSTHOME__/.config/git"))
(allow file-read* file-write* (subpath "__HOSTHOME__/.gcalcli"))
(allow file-read* file-write* (subpath "__HOSTHOME__/Library/Caches/ms-playwright"))
(allow file-read* process-exec* (subpath "__HOSTHOME__/.cloakbrowser"))
(allow file-read*
  (subpath "__HOSTHOME__/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data"))
```

Leave as `__HOME__` (now the fleet home) everything the agent writes:

```
(subpath "__HOME__/.claude")            (subpath "__HOME__/.cache/claude")
(subpath "__HOME__/.local/state/claude")(subpath "__HOME__/Library/Caches/claude-cli-nodejs")
(regex #"^__HOME__/\.claude\.json(\.|$)")
(subpath "__HOME__/.npm")               (subpath "__HOME__/.agent-browser")
(literal "__HOME__")
(subpath "__HOME__/.claude")  ; :81, in the process-exec* list — plugin hooks
(subpath "__HOME__/.npm")     ; :83, in the process-exec* list — npx MCP servers
```

`:83` is easy to miss because the same path appears twice in the template — the
write grant at `:187` and this exec grant. Both stay fleet-side or npx-launched
MCP servers exec out of a cache the fleet cannot populate.

**The keychain grant at `:129` is the one exception, and it is a sequencing
problem, not a mapping one:**

```
(allow file-read* file-write* (subpath "__HOME__/Library/Keychains"))
```

Leaving it spelled `__HOME__` remaps it to the fleet home — which is the correct
*destination*, but it takes effect at the end of **this** task, not Task 4. The
host keychain grant vanishes, `seed_fleet_home` has copied the host's husk
`.credentials.json` (empty tokens, epoch expiry — Finding 2), and the fleet has
no credential at all. Every agent comes back with `Failed to authenticate: OAuth
session expired and could not be refreshed`. Step 9 below used to claim the
opposite; it was wrong.

Pick one:

- **Spell it `__HOSTHOME__` here, delete it in Task 4** (recommended). Task 2
  stays a pure isolation change with authentication untouched, and Task 4 remains
  the single commit where the keychain leaves the profile. One line churned twice.
- **Land Tasks 2 and 4 together.** Fewer edits, but the commit then mixes "the
  fleet gets its own home" with "the fleet stops using the keychain", and if
  agents fail to come back you cannot tell which half did it.

Either way, `seed_fleet_home`'s `mkdir` of `${FLEET_HOME}/Library/Keychains` is
vestigial — it dates from the abandoned fleet-keychain design. Harmless; drop it
when Task 4 lands.

Two grants change meaning as a bonus, and both are improvements worth naming in the commit: `~/.npm` becomes a fleet-private npm cache (the `_cacache` poisoning path against the host's future `npm i` is gone), and `~/.agent-browser` becomes fleet-private (the human's saved browser auth states are no longer readable).

Update the backstops at the bottom to cover the host home explicitly — these are cheap and they survive a future broad rule:

```
;; The host's own Claude Code state. The fleet has its own home; the host's is
;; not merely un-granted but explicitly denied, because settings.json and the
;; ccline statusline binary are executed by the HOST's claude, unsandboxed.
(deny file-read* file-write*
  (subpath "__HOSTHOME__/.claude")
  (literal "__HOSTHOME__/.claude.json")
  (subpath "__HOSTHOME__/.npm"))

(deny file-read* file-write*
  (subpath "__HOSTHOME__/.ssh")
  (subpath "__HOSTHOME__/.aws")
  (subpath "__HOSTHOME__/.gnupg"))
```

Delete the old `__HOME__`-spelled `.ssh`/`.aws`/`.gnupg` backstop (`:326-328`) — under the new mapping it would point at the fleet home and protect nothing.

**The Bear write-deny backstop at `:321` has exactly the same defect** and is easy to skip because it sits in a different block:

```
;; Bear is read-only, permanently.
(deny file-write*
  (subpath "__HOSTHOME__/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear"))
```

Left as `__HOME__` it denies writes to a Bear directory inside the fleet home that does not exist, while the real one is no longer covered. Bear does stay unwritable either way — the allow at `:177` is `file-read*` only, so nothing grants write — but this backstop exists precisely so a *future* broad rule cannot make it writable, and orphaned it stops doing that job. Every `__HOME__` in a `deny` rule must become `__HOSTHOME__`; there are no exceptions, because the fleet home is where the agent is *supposed* to write.

- [ ] **Step 6: Confirm no placeholder survived and both homes appear**

```bash
source ./sbx-common.sh && render_profile 1 > /tmp/p.sb
grep -c "__HOME__\|__HOSTHOME__\|__VAULT__\|__LOGDIR__" /tmp/p.sb   # expect 0
grep -c "\.claude-sbx/home" /tmp/p.sb                                # expect >0
sandbox-exec -f /tmp/p.sb /usr/bin/true && echo COMPILES
```

- [ ] **Step 7: Wire `HOME` and the seed into `sbx-agent-run.sh`**

After the `TERM` exports:

```bash
# The fleet's own HOME — this is what makes every writable grant in the profile
# land outside the host's home directory. Exported BEFORE render_profile so the
# rendered paths and the process's actual $HOME cannot drift apart.
seed_fleet_home
export HOME="${FLEET_HOME}"
```

Two ordering constraints, both load-bearing:

- **Do not move the `source` line below this export.** `CLAUDE_BIN`, `VAULT`, `LOG_DIR` and `SETTINGS` are expanded from the *host* `$HOME` when `sbx-common.sh` is sourced, and keep pointing at the right places only because of that.
- **`PTY_RUN`, `SETTINGS` and `AB_CONFIG` (`:40-42`) must stay above this export.** They are `${HOME}/.claude-sbx/...` and must resolve to the host path — that directory is the agent's *input* (installed fresh on every launch by the host side of this script), not fleet state.

What does *not* get protected by ordering is `render_profile`'s own body, because it re-expands `${HOME}` when called. That is why Step 4 uses `HOST_HOME`.

- [ ] **Step 8: Run the verifier — all of `[7]` and `[8]` must pass**

```bash
./sbx-verify.sh
```

Expected: `fail=0`. If `write fleet ~/.claude` fails, `seed_fleet_home` did not run or `FLEET_HOME` is not exported.

- [ ] **Step 9: Restart the fleet and confirm the agents still authenticate**

```bash
./sbx-stop.sh && ./sbx-start.sh && sleep 20 && ./sbx-status.sh
tail -30 ~/.claude-sbx/logs/agent-1.log
```

Expected: five running agents, and no `Failed to authenticate` in the log.

Authentication surviving this step depends entirely on the choice made in Step 5. If you spelled `:129` as `__HOSTHOME__`, the host keychain is still reachable and agents authenticate exactly as before — that is the point of deferring it. If you left it as `__HOME__`, expect `Failed to authenticate: OAuth session expired and could not be refreshed` on all five, and do not debug it as a bug in this task: it is Task 4's work arriving early, and the fix is to finish Task 4 (or revert `:129` to `__HOSTHOME__` and land Task 2 alone).

Also confirm the fleet found its runtime inputs, which is where a `HOST_HOME` slip in Step 4 surfaces:

```bash
grep -c "\.claude-sbx/home/\.claude-sbx" "$(source ./sbx-common.sh && profile_for 1)"   # expect 0
```

Any hit means `__LOGDIR__` rendered under the fleet home; the symptom in the log is an agent that starts and hangs with no error, because `pty-run.py` is unreadable inside the sandbox.

- [ ] **Step 10: Commit**

```bash
git add sbx-common.sh sbx-agent-run.sh profiles/agent.sb.template sbx-verify.sh
git commit -m "security(sbx): give the fleet its own HOME; host ~/.claude now denied

The host's ~/.claude/settings.json and ~/.claude/ccline/ccline are executed by
the HOST's claude, unsandboxed, and both were writable from inside the sandbox.
Mirrors the container fleet's seed_fleet_claude_home(). Host session transcripts
are not copied. ~/.npm and ~/.agent-browser become fleet-private as a bonus."
```

---

### Task 3: Prove the repair property

The seed's value is not just isolation — it is that launchd repairs a tampered fleet home within 30s. That property is load-bearing and untested, so test it.

**Files:**
- Modify: `sbx-verify.sh`

**Interfaces:**
- Consumes: `seed_fleet_home()`, `FLEET_HOME` from Task 2.
- Produces: nothing consumed later.

- [ ] **Step 1: Write the failing test**

Append to `sbx-verify.sh`:

```bash
echo "--- [9] seed_fleet_home repairs agent tampering"
_orig="$(cat "${FLEET_HOME}/.claude/settings.json" 2>/dev/null)"
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"TAMPERED"}]}]}}' \
  > "${FLEET_HOME}/.claude/settings.json"
seed_fleet_home >/dev/null 2>&1
if grep -q TAMPERED "${FLEET_HOME}/.claude/settings.json" 2>/dev/null; then
  printf '  FAIL  %-46s tampered settings.json survived the seed\n' "seed repairs settings.json"
  FAIL=$((FAIL+1))
  [ -n "$_orig" ] && printf '%s' "$_orig" > "${FLEET_HOME}/.claude/settings.json"
else
  printf '  ok    %-46s (repaired)\n' "seed repairs settings.json"; PASS=$((PASS+1))
fi

_ccline="${FLEET_HOME}/.claude/ccline/ccline"
printf '#!/bin/sh\necho TAMPERED\n' > "${_ccline}" 2>/dev/null
seed_fleet_home >/dev/null 2>&1
# Three conditions, not one. `! grep -q TAMPERED` alone is true for a file that
# does not exist, so a seed that silently skipped ccline would report "repaired"
# while proving nothing. Assert the file is back, and that it is byte-identical
# to the host original — that is what "repaired" has to mean.
if [ ! -s "${_ccline}" ]; then
  printf '  FAIL  %-46s ccline missing after seed (did the copy run?)\n' "seed repairs ccline"; FAIL=$((FAIL+1))
elif grep -q TAMPERED "${_ccline}" 2>/dev/null; then
  printf '  FAIL  %-46s tampered ccline survived the seed\n' "seed repairs ccline"; FAIL=$((FAIL+1))
elif ! cmp -s "${HOST_HOME}/.claude/ccline/ccline" "${_ccline}"; then
  printf '  FAIL  %-46s ccline differs from the host original\n' "seed repairs ccline"; FAIL=$((FAIL+1))
else
  printf '  ok    %-46s (repaired)\n' "seed repairs ccline"; PASS=$((PASS+1))
fi
```

The `settings.json` test above does not need the same treatment — if the host file is missing, the seed skips it, the tampered copy survives, and the test fails loudly. That is the right outcome. The `ccline` case is different only because the missing-file path silences the check instead of tripping it.

Both tests assume the host actually has these files. It does today (`~/.claude/ccline/ccline`, `~/.claude/settings.json`, and `~/.claude/plugins/` all present), and `cmp` against the host original turns a future absence into a failure rather than a false pass.

- [ ] **Step 2: Run it**

```bash
./sbx-verify.sh 2>&1 | grep -A3 "\[9\]"
```

Expected: both `ok`. `rsync -a --delete` handles `ccline`; `cp -p` handles `settings.json`. If `ccline` fails, the `--delete` flag is missing from the loop in `seed_fleet_home`.

- [ ] **Step 3: Confirm host transcripts genuinely did not travel**

```bash
ls ~/.claude-sbx/home/.claude/ | sort
/usr/bin/python3 -c "import json;print(list(json.load(open('$HOME/.claude-sbx/home/.claude.json'))['projects'].keys()))"
```

Expected: no `projects`, `history.jsonl`, `file-history`, `shell-snapshots`, `sessions`, `todos`, `debug` or `telemetry` in the listing; exactly one project key, the vault path.

- [ ] **Step 4: Commit**

```bash
git add sbx-verify.sh
git commit -m "test(sbx): assert seed_fleet_home repairs tampered settings.json and ccline"
```

---

### Task 4: Replace keychain access with a seeded credential file

Finding 2 above: Claude Code needs a credential store, not the keychain. Seed `~/.claude/.credentials.json` inside the fleet home from the host keychain, then deny the keychain outright. This is smaller than the fleet-keychain approach it replaces and strictly better — there is no fleet keychain to unlock, and `securityd` leaves the fleet's threat model entirely.

**Files:**
- Modify: `sbx-common.sh` (add `seed_fleet_credentials()`)
- Modify: `sbx-agent-run.sh` (call it)
- Modify: `profiles/agent.sb.template` (remove the keychain grants, add backstops)
- Modify: `sbx-verify.sh`

**Interfaces:**
- Consumes: `FLEET_HOME` and `seed_fleet_home()` from Task 2.
- Produces: `seed_fleet_credentials()` — no args, returns 0, idempotent. Must be called **after** `seed_fleet_home()` (which creates `${FLEET_HOME}/.claude`) and **before** `export HOME`.

- [ ] **Step 1: Write the failing assertions**

Append to `sbx-verify.sh`:

```bash
echo "--- [10] the keychain must be unreachable"
check "read  host login.keychain-db"   deny  sb /bin/cat "${HOME}/Library/Keychains/login.keychain-db"
check "list  host ~/Library/Keychains" deny  sb /bin/ls  "${HOME}/Library/Keychains"
check "security list-keychains"        deny  sb /usr/bin/security list-keychains
check "fleet credential file exists"   allow sb /bin/test -s "${FLEET_HOME}/.claude/.credentials.json"
```

- [ ] **Step 2: Run it and watch the first three fail**

```bash
./sbx-verify.sh 2>&1 | grep -A5 "\[10\]"
```

Expected: `read host login.keychain-db … expected deny, got allow`.

- [ ] **Step 3: Add `seed_fleet_credentials()` to `sbx-common.sh`**

```bash
# Give the fleet a file-based credential so the keychain can leave the profile.
#
# Claude Code needs a credential STORE, not the keychain specifically: on macOS
# it prefers the keychain and falls back to ~/.claude/.credentials.json when the
# keychain is unreachable. Verified with ~/Library/Keychains AND the securityd
# mach services both denied -- a populated file authenticates fine.
#
# Note the host's own ~/.claude/.credentials.json is a HUSK on this machine
# (empty tokens, epoch expiry), so copying that file is useless -- that is what
# made the keychain look mandatory at first. The live token is in the keychain
# item, so read it from there and write it out as the file.
#
# 0600, and inside FLEET_HOME which is 0700. This is a real refresh token on
# disk in plaintext; the keychain was at least encrypted at rest. Accepted
# because the alternative is granting the fleet the host login keychain, which
# is every secret Brian owns rather than this one.
seed_fleet_credentials() {
  local dest="${FLEET_HOME}/.claude/.credentials.json"
  local token
  token="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null)" || {
    echo "WARNING: no 'Claude Code-credentials' in the host keychain — agents will not authenticate" >&2
    return 0
  }
  # Reject the husk rather than overwrite a working fleet credential with it.
  printf '%s' "${token}" | /usr/bin/python3 -c '
import json, sys
d = json.load(sys.stdin).get("claudeAiOauth", {})
sys.exit(0 if d.get("accessToken") and d.get("refreshToken") else 1)
' || { echo "WARNING: host keychain credential is empty — leaving the fleet copy alone" >&2; return 0; }

  umask 077
  printf '%s' "${token}" > "${dest}"
  chmod 600 "${dest}"
  return 0
}
```

- [ ] **Step 4: Remove the keychain grants from the template**

In `profiles/agent.sb.template`, delete the whole `--- keychain / auth ---` block:

```
(allow file-read* file-write* (subpath "__HOME__/Library/Keychains"))
(allow file-read*
  (subpath "/Library/Keychains")
  (subpath "/System/Library/Keychains")
  (subpath "/private/var/db/mds"))
(allow user-preference-read
  (preference-domain "com.apple.security")
  (preference-domain "kcfpreferencesanyapplication"))
```

Keep `com.apple.SecurityServer` and `com.apple.securityd.xpc` in the mach-lookup list for now — TLS trust evaluation goes through `trustd`, which is a separate service already granted, but removing two entries at the same time as the file grants makes a failure ambiguous. Removing them is Step 8.

Add the backstop at the bottom:

```
;; The keychain. Claude Code needs a credential STORE, not this one: it falls
;; back to ~/.claude/.credentials.json, which seed_fleet_credentials() writes
;; into the fleet home. Denied rather than merely un-granted, because this was
;; the single widest grant in the profile (NOTES.md:209) and a future broad rule
;; under __HOSTHOME__/Library must not silently restore it.
(deny file-read* file-write* (subpath "__HOSTHOME__/Library/Keychains"))
```

- [ ] **Step 5: Call the seed in `sbx-agent-run.sh`**

Immediately after `seed_fleet_home`, before `export HOME`:

```bash
seed_fleet_credentials
```

- [ ] **Step 6: Settle the refresh-rotation question — do this before restarting the fleet**

The fleet now holds a *copy* of an OAuth grant that the host also holds. If refreshing rotates the refresh token, whichever side refreshes second is logged out. Detect it without breaking anything:

```bash
# Fingerprint the host's refresh token (hash only — never print the token).
security find-generic-password -s 'Claude Code-credentials' -w \
  | /usr/bin/python3 -c "import json,sys,hashlib;print(hashlib.sha256(json.load(sys.stdin)['claudeAiOauth']['refreshToken'].encode()).hexdigest()[:16])"
```

Record that value. Let one agent run past its access-token expiry (`expiresAt` in the same blob — hours, not days), then re-run the command and compare.

- **Unchanged** → the grant does not rotate refresh tokens. The design is safe; note it in `NOTES.md` and move on.
- **Changed** → rotation is live, and the seed-on-every-launch in Step 5 will fight the host. Stop and decide: either give the fleet its own login (a second Claude account, cleanest), or accept that the host's Claude Code needs re-authenticating whenever the fleet refreshes. Do not paper over this — a fleet that silently logs Brian out of his own Mac is worse than the keychain grant it replaced.

- [ ] **Step 7: The decisive test — does an agent still authenticate with no keychain at all?**

```bash
source ./sbx-common.sh && seed_fleet_home && seed_fleet_credentials
render_profile 1 > /tmp/p.sb && cp sbx-settings.json /tmp/sbx-settings.json
sandbox-exec -f /tmp/p.sb /bin/cat "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 \
  && echo "KEYCHAIN STILL READABLE — test invalid" || echo "keychain denied: ok"
cd /private/tmp && HOME="$FLEET_HOME" sandbox-exec -f /tmp/p.sb \
  "$CLAUDE_BIN" --settings /tmp/sbx-settings.json --dangerously-skip-permissions \
  -p 'reply with exactly: FILE_CREDS_OK'
```

Expected: `keychain denied: ok`, then `FILE_CREDS_OK`. If it prints `Failed to authenticate: OAuth session expired and could not be refreshed`, the seeded file is a husk — re-check Step 3's husk guard fired for the right reason.

- [ ] **Step 8: Drop the now-unused securityd mach services**

Remove from the mach-lookup list in the template:

```
(global-name "com.apple.SecurityServer")
(global-name "com.apple.securityd.xpc")
```

Re-run Step 7. If `FILE_CREDS_OK` still appears, they were only there for the keychain and are gone for good. If TLS breaks, put them back with a comment recording that trust evaluation needs them — that is a finding, not a failure.

- [ ] **Step 9: Full verify, then restart the fleet**

```bash
./sbx-verify.sh && ./sbx-stop.sh && ./sbx-start.sh && sleep 20 && ./sbx-status.sh
grep -l "Failed to authenticate" ~/.claude-sbx/logs/agent-*.log   # expect no output
```

- [ ] **Step 10: Commit**

```bash
git add sbx-common.sh sbx-agent-run.sh profiles/agent.sb.template sbx-verify.sh
git commit -m "security(sbx): drop keychain access entirely; seed a credential file

Claude Code needs a credential store, not the keychain -- it falls back to
~/.claude/.credentials.json when the keychain is unreachable, verified with both
the keychain files and the securityd mach services denied. The host's own
.credentials.json is a husk (empty tokens), which is what made the keychain look
mandatory. Removes the widest grant in the profile (NOTES.md:209)."
```

---

### Task 5: The loopback egress proxy

The proxy runs **outside** the sandbox — it is the enforcement point, so it must not be reachable for modification by anything inside. It lives in the repo (`~/dev`, already denied to agents) and runs as its own launchd job.

**Files:**
- Create: `sbx-proxy.py`
- Create: `sbx-proxy-run.sh`
- Modify: `sbx-common.sh` (port, label, plist renderer, status row)
- Modify: `sbx-start.sh`, `sbx-stop.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `PROXY_PORT=8888`, `proxy_label()` → `com.brianlow.claude-sbx.proxy`, `proxy_plist()`, `proxy_state()`.
  - A proxy on `127.0.0.1:8888` speaking HTTP `CONNECT` and absolute-URI `GET`/`POST`, returning `403` for private destinations.
  - Task 6 consumes `PROXY_PORT`.

- [ ] **Step 1: Write `sbx-proxy.py`**

```python
#!/usr/bin/env python3
"""Loopback egress proxy for the sandbox-exec fleet.

Runs OUTSIDE the sandbox. The agents' Seatbelt profile allows outbound
connections to localhost only, so this process is the fleet's sole path to the
network and the only place a destination policy can be enforced. Seatbelt
itself cannot express one: its network grammar accepts only `*` and `localhost`
as hosts -- no CIDR, no per-IP -- and pf can only be keyed on the container
bridge or on a uid the fleet cannot use (the vault lives in Brian's iCloud).

Policy: resolve the destination, then refuse private, loopback, link-local,
CGNAT and multicast addresses. Resolving BEFORE the check is the point -- it
also defeats DNS rebinding, where a hostname the agent controls resolves to
192.168.1.1. Every A/AAAA record must pass, not just the first.

Stdlib only, by design: no new dependency, and the code is short enough to audit.
"""
import ipaddress
import select
import socket
import socketserver
import sys
import threading

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8888
BUFSIZE = 65536
CONNECT_TIMEOUT = 15


def blocked(ip_str):
    """True if this address is one the fleet must not reach."""
    ip = ipaddress.ip_address(ip_str)
    return (ip.is_private or ip.is_loopback or ip.is_link_local
            or ip.is_multicast or ip.is_reserved or ip.is_unspecified)


def resolve_allowed(host, port):
    """Resolve host; return a sockaddr only if EVERY answer is public."""
    try:
        infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
    except socket.gaierror as exc:
        raise PolicyError(502, f"DNS failure for {host}: {exc}") from exc
    if not infos:
        raise PolicyError(502, f"no addresses for {host}")
    for info in infos:
        addr = info[4][0]
        if blocked(addr):
            raise PolicyError(403, f"destination {host} resolves to {addr} (private)")
    return infos[0]


class PolicyError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


class Handler(socketserver.StreamRequestHandler):
    timeout = 300

    def deny(self, code, message):
        sys.stderr.write(f"DENY {code} {message}\n")
        sys.stderr.flush()
        body = message.encode()
        self.wfile.write(
            b"HTTP/1.1 %d Forbidden\r\nContent-Length: %d\r\n"
            b"Connection: close\r\n\r\n%s" % (code, len(body), body))

    def handle(self):
        try:
            line = self.rfile.readline(65536).decode("latin-1").strip()
        except OSError:
            return
        if not line:
            return
        parts = line.split()
        if len(parts) < 3:
            return self.deny(400, "malformed request line")
        method, target = parts[0], parts[1]

        try:
            if method.upper() == "CONNECT":
                host, _, port = target.rpartition(":")
                self.tunnel(host, int(port or 443))
            else:
                self.deny(403, "only CONNECT is proxied; use HTTPS")
        except PolicyError as exc:
            self.deny(exc.code, exc.message)
        except (OSError, ValueError) as exc:
            self.deny(502, f"upstream error: {exc}")

    def tunnel(self, host, port):
        info = resolve_allowed(host, port)
        upstream = socket.socket(info[0], socket.SOCK_STREAM)
        upstream.settimeout(CONNECT_TIMEOUT)
        upstream.connect(info[4])
        upstream.settimeout(None)
        self.wfile.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        self.wfile.flush()
        self.pump(self.connection, upstream)

    @staticmethod
    def pump(a, b):
        socks = [a, b]
        try:
            while True:
                readable, _, errored = select.select(socks, [], socks, 300)
                if errored or not readable:
                    break
                for src in readable:
                    dst = b if src is a else a
                    data = src.recv(BUFSIZE)
                    if not data:
                        return
                    dst.sendall(data)
        except OSError:
            pass
        finally:
            for s in socks:
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                s.close()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    sys.stderr.write(f"sbx-proxy listening on {LISTEN_HOST}:{LISTEN_PORT}\n")
    sys.stderr.flush()
    Server((LISTEN_HOST, LISTEN_PORT), Handler).serve_forever()
```

Note the deliberate restriction to `CONNECT`: plaintext HTTP proxying is not implemented, because everything the fleet talks to is HTTPS and an absolute-URI handler is extra attack surface for no gain. If some tool turns out to need plain HTTP, that is a decision to record, not a quiet addition — the same rule the profile's mach-lookup list follows.

- [ ] **Step 2: Test the policy directly, before wiring launchd**

```bash
/usr/bin/python3 sbx-proxy.py 8888 &
sleep 1
curl -s -o /dev/null -w 'public  → %{http_code}\n' --max-time 10 -x http://127.0.0.1:8888 https://example.com
curl -s -w 'router  → %{http_code} %{stderr}\n' --max-time 10 -x http://127.0.0.1:8888 https://192.168.1.1/ 2>&1 | tail -2
curl -s -w 'loopback→ %{http_code}\n' --max-time 10 -x http://127.0.0.1:8888 https://127.0.0.1:9222/ 2>&1 | tail -1
kill %1
```

Expected: `public → 200`; the router and loopback attempts fail with the proxy reporting `403` and a `DENY 403 … (private)` line on stderr.

- [ ] **Step 3: Write `sbx-proxy-run.sh`**

```bash
#!/usr/bin/env bash
# sbx-proxy-run.sh — the fleet's egress proxy, foreground, launchd-managed.
#
# Runs OUTSIDE the sandbox deliberately. The agents' profile allows outbound
# connections to localhost only, so this is their sole path off the machine and
# the only place a destination policy can live. It sits in ~/dev, which the
# profile denies entirely, so no agent can edit the policy it is subject to.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/sbx-common.sh"
mkdir -p "${LOG_DIR}"
echo "$(date '+%Y-%m-%dT%H:%M:%S') starting egress proxy on 127.0.0.1:${PROXY_PORT}"
exec /usr/bin/python3 "${SCRIPT_DIR}/sbx-proxy.py" "${PROXY_PORT}"
```

```bash
chmod +x sbx-proxy-run.sh
```

- [ ] **Step 4: Add the proxy job to `sbx-common.sh`**

```bash
# The fleet's only path to the network once the profile is loopback-only.
PROXY_PORT="${PROXY_PORT:-8888}"

proxy_label() { printf '%s.proxy' "${LABEL_PREFIX}"; }
proxy_plist() { printf '%s/%s.plist' "${PLIST_DIR}" "$(proxy_label)"; }

proxy_state() {
  if nc -z 127.0.0.1 "${PROXY_PORT}" 2>/dev/null; then
    printf 'running (127.0.0.1:%s)' "${PROXY_PORT}"
  else
    printf 'NOT LISTENING'
  fi
}

render_proxy_plist() {
  local label log
  label="$(proxy_label)"
  log="${LOG_DIR}/proxy.log"
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${SBX_DIR}/sbx-proxy-run.sh</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>30</integer>
    <key>WorkingDirectory</key><string>${SBX_DIR}</string>
    <key>StandardOutPath</key><string>${log}</string>
    <key>StandardErrorPath</key><string>${log}</string>
</dict>
</plist>
PLIST
}
```

Add a row to `print_status()`, after the browser row:

```bash
  if is_loaded_label "$(proxy_label)"; then l="loaded"; else l="not loaded"; fi
  printf '%-13s %-12s %s\n' "proxy" "$l" "$(proxy_state)"
```

- [ ] **Step 5: Bootstrap it in `sbx-start.sh`, bootout in `sbx-stop.sh`**

In `sbx-start.sh`, before the browser block (the agents need it sooner than they need a browser):

```bash
render_proxy_plist > "$(proxy_plist)"
if is_loaded_label "$(proxy_label)"; then
  echo "proxy: already loaded — leaving running."
else
  echo "proxy: bootstrapping..."
  launchctl bootstrap "${GUI_DOMAIN}" "$(proxy_plist)" \
    || echo "proxy: WARNING — bootstrap failed (see ${LOG_DIR}/proxy.log)."
fi
```

In `sbx-stop.sh`, alongside the browser bootout:

```bash
if is_loaded_label "$(proxy_label)"; then
  echo "proxy: booting out..."
  launchctl bootout "${GUI_DOMAIN}/$(proxy_label)" || echo "proxy: WARNING — bootout failed."
else
  echo "proxy: not loaded."
fi
```

- [ ] **Step 6: Bring it up under launchd and confirm**

```bash
./sbx-start.sh && ./sbx-status.sh
curl -s -o /dev/null -w '%{http_code}\n' -x http://127.0.0.1:8888 https://api.anthropic.com/
```

Expected: a `proxy  loaded  running (127.0.0.1:8888)` row, and a non-000 status code from the curl.

- [ ] **Step 7: Commit**

```bash
git add sbx-proxy.py sbx-proxy-run.sh sbx-common.sh sbx-start.sh sbx-stop.sh
git commit -m "feat(sbx): loopback egress proxy that refuses private destinations

Seatbelt's network grammar accepts only * and localhost as hosts, so 'deny
RFC1918' cannot be written in the profile; pf can only key on the container
bridge. Enforcement moves to a proxy outside the sandbox. Resolves before
checking, so DNS rebinding to a LAN address is refused too."
```

---

### Task 6: BLOCKED — spike the bridge, then decide. Do not merge on a green verifier.

Flipping the profile to loopback-only is a two-line change and it is *tested to break the fleet*: the `--remote-control` bridge does not use Claude Code's proxy dispatcher, so the agents become confined and unreachable from the desktop app. See "Finding 3, scoped" above for the measurement — three established connections on full network, none through the proxy, at 30s, same invocation otherwise.

`sbx-verify.sh` would report `fail=0` on that fleet. **The verifier cannot see this failure**, which is exactly why this task is a decision rather than an edit.

The one-shot API path *is* proxy-aware, so Task 5's proxy is not wasted — it is a working chokepoint for everything except the bridge, and it is the natural home for a domain allow-list later. Keep it running.

**Files:** none yet. This task produces a decision recorded in `NOTES.md`, and only then an implementation.

**Interfaces:**
- Consumes: the working proxy from Task 5.
- Produces: nothing until the decision is made.

- [ ] **Step 1: Reproduce the break, so the decision rests on your own measurement**

```bash
source ./sbx-common.sh
render_profile 1 | sed 's|^(allow network\*)|(allow network-bind network-inbound)\n(deny network-outbound)\n(allow network-outbound (remote ip "localhost:*"))\n(allow network-outbound (remote unix-socket))|' > /tmp/lb.sb
sandbox-exec -f /tmp/lb.sb /usr/bin/true && echo compiles

HTTPS_PROXY=http://127.0.0.1:${PROXY_PORT} https_proxy=http://127.0.0.1:${PROXY_PORT} \
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost TERM=xterm-256color \
timeout 60 sandbox-exec -f /tmp/lb.sb /usr/bin/python3 ~/.claude-sbx/pty-run.py 120 40 \
  "$CLAUDE_BIN" --settings ~/.claude-sbx/settings.json --dangerously-skip-permissions \
  --remote-control sbx-bridge-spike >/dev/null 2>&1 &
sleep 30
SPID=$(pgrep -f -- "--remote-control sbx-bridge-spike" | head -1)
CPID=$(pgrep -P "$(pgrep -P "$SPID" | head -1)" | head -1)
lsof -nP -a -p "$CPID" -i TCP -s TCP:ESTABLISHED
```

Expected: no rows. Re-run with the unmodified profile and no proxy env for the control — expect two or three rows to `160.79.104.10:443`.

- [ ] **Step 2: Check whether the bridge can be made proxy-aware at all**

Claude Code bundles undici's `EnvHttpProxyAgent` and calls `setGlobalDispatcher`, and its HTTP path honors the env vars — so the machinery exists and the bridge simply does not route through it. Two things to try before concluding it cannot:

```bash
# a. Node 24+ honors proxy env for its own fetch/WebSocket when asked explicitly.
NODE_USE_ENV_PROXY=1 HTTPS_PROXY=http://127.0.0.1:${PROXY_PORT} ...same invocation...

# b. Some builds read a separate variable for the control channel. Check first:
strings -a "$(readlink -f "$CLAUDE_BIN")" | grep -oiE "CLAUDE[A-Z_]*PROXY|BRIDGE[A-Z_]*|CONTROL[A-Z_]*URL" | sort -u
```

If (a) produces established connections through the proxy, the whole blocker evaporates — implement the original Task 6 as written and add `NODE_USE_ENV_PROXY=1` to the exports. Verify with Step 1's `lsof` check, not with `sbx-verify.sh`.

- [ ] **Step 3: If the bridge stays unproxyable, choose. These are the real options.**

Record the choice and its reasoning in `NOTES.md`; there is no option here that is simply correct.

| option | what it costs | what it buys |
|---|---|---|
| **A. Accept the LAN exposure** | The router, NAS and every LAN device stay reachable from a prompt-injected agent | Zero risk to the fleet; keep the proxy for the API path anyway, so a domain allow-list stays available later |
| **B. Dedicated uid + pf `user` rule** | A real user account; the vault lives in Brian's iCloud container and another uid cannot read it without ACL work (`chmod +a`) that iCloud may re-write; gui-domain LaunchAgents cannot set `UserName`, so the jobs move to system-domain daemons | The only approach that blocks LAN egress *and* leaves the bridge alone, because it filters at pf rather than in the profile |
| **C. Loopback-only, no remote control** | Loses the entire point of the fleet — these agents exist to be driven from the desktop app | Complete egress control |
| **D. Loopback-only + narrow direct allowance for the bridge** | Not expressible: Seatbelt cannot allow one remote host (`host must be * or localhost`). There is no partial version of this | — |

**Recommendation: A, with B as the follow-up if LAN exposure turns out to matter.** Option A is honest about the trade rather than shipping a confined fleet nobody can reach, and it leaves Task 5's proxy in place doing real work. Option B is the correct long-term answer and is a project, not a step — the vault-access problem needs its own spike before it is worth starting.

- [ ] **Step 4: If A — make the exposure explicit rather than incidental**

Do not leave `(allow network*)` unremarked, or the next reader will assume the LAN is covered because the container fleet's is. Replace the network block's comment in `profiles/agent.sb.template`:

```
;; --- network ---------------------------------------------------------------
;; UNRESTRICTED, DELIBERATELY, and this is the weakest point in the profile.
;;
;; These are native host processes, so pf/claude-agent.pf does NOT apply to
;; them: every rule there is `on $cont_if from $cont_net`, matching only the
;; container bridge. The home LAN -- router admin, NAS, everything on
;; 192.168.1.0/24 -- is reachable from here and from anything that talks an
;; agent into reaching it.
;;
;; It is not fixable in this file. Seatbelt's network grammar accepts only `*`
;; and `localhost` as hosts; every CIDR and per-IP spelling is rejected by the
;; compiler. See NOTES.md, "Seatbelt cannot express a destination policy".
;;
;; The loopback-only design that WOULD fix it breaks --remote-control: the
;; bridge does not use Claude Code's proxy dispatcher, so the fleet ends up
;; confined and unreachable. Measured, see NOTES.md. sbx-proxy.py stays up and
;; carries the API traffic regardless -- it is where a domain allow-list goes
;; when someone wants one.
(allow network*)
(allow system-socket)
```

- [ ] **Step 5: Assert the exposure, so it stays a known quantity**

A test that encodes the *current* truth is worth more than no test — if this ever starts failing, something changed and someone should know.

```bash
echo "--- [11] network reach (documents the accepted exposure)"
check "loopback → proxy"        allow _np 127.0.0.1 "${PROXY_PORT}"
check "loopback → browser CDP"  allow _np 127.0.0.1 "${BROWSER_CDP_PORT}"
check "internet → example.com"  allow _np example.com 443
# KNOWN EXPOSURE, accepted in Task 6 option A. Flipping this to `deny` is the
# fix; do not "fix" the test.
check "LAN → router (EXPOSED)"  allow _np 192.168.1.1 80
```

Add the `_np` helper above it:

```bash
_np() { sb /usr/bin/python3 -c "
import socket,sys
s=socket.socket(); s.settimeout(4)
try: s.connect((sys.argv[1], int(sys.argv[2])))
except Exception: sys.exit(1)
finally: s.close()" "$1" "$2"; }
```

- [ ] **Step 6: Commit the decision**

```bash
git add profiles/agent.sb.template sbx-verify.sh NOTES.md
git commit -m "docs(sbx): record why LAN egress stays open — the bridge is not proxyable

Loopback-only egress works and blocks the LAN, but --remote-control does not
route through Claude Code's proxy dispatcher, so the fleet would be confined and
unreachable. Measured: 3 established connections on full network, 0 through the
proxy. Keeping network* with the exposure documented and asserted, rather than
shipping a fleet nobody can drive."
```

---

### Task 7: Record what was deferred and why

Two findings are deliberately not being fixed. Write them down where the next person will look, so they read as decisions rather than gaps.

**Files:**
- Modify: `NOTES.md`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Append the deferred section to `NOTES.md`**

````markdown
## Deferred, deliberately (2026-08-02 review)

### No compartmentalization between the five agents — DEFERRED, not accepted

Five agents share one rendered profile, one vault with unguarded write access,
one fleet home, one keychain, one npm cache, and one browser container behind a
single unauthenticated CDP port. Compromise one agent and you have all five,
plus every authenticated browser session any of them established. Tasks 2-6 fix
what the fleet can reach; none of them change the fact that it is one blast
radius rather than five.

`sbx-common.sh` already notes the sharing is inherited from the container fleet
rather than chosen here. Options, cheapest first:

1. **Per-agent fleet home** — `~/.claude-sbx/home/agent-N`, `render_profile`
   already takes `N` and currently ignores it, so this is a one-line change to
   `FLEET_HOME` plus a loop in the seeds. Separates each agent's Claude state,
   keychain, npm cache and `~/.agent-browser` cookies. Costs ~5x the fleet home
   on disk, which is small. **This is the one worth doing first.**
2. **Per-agent vault subtree** — the highest-value and highest-friction change.
   Vault write is the injection vector *and* the shared surface: agent 1 can
   plant a note that agent 3 later reads as instructions. Scoping each agent to
   `Vault/agents/N/` plus read-only elsewhere would break the Hermes workflow as
   it currently exists, so it needs a design pass, not a profile edit.
3. **Per-agent browser container** — own CDP port, own profile, so one agent's
   logged-in session is not another's. Costs ~4GB of RAM per agent at the
   current `--memory 4g`; probably why it was not done. A shared browser with
   per-agent contexts (CDP `Target.createBrowserContext`) is the cheaper
   middle path and worth investigating before spending the memory.
4. **Per-agent proxy policy** — once Task 5 lands, a per-agent allow-list is
   just a second listening port with a different policy. Nearly free, and the
   natural place to give one agent calendar access and another none.

### Unauthenticated CDP on loopback — ACCEPTED

`127.0.0.1:9222` has no authentication, so every local process on this Mac can
drive the fleet's browser, not just the agents. This is accepted: Chromium's CDP
has no auth mechanism to add, loopback is what keeps it off the network, and the
container holds nothing worth stealing (the profile is ephemeral -- cookies do
not survive a restart; see "Q2 re-tested"). The exposure is to local processes
running as Brian, which are already outside every boundary this fleet has.

Revisit if the browser profile ever becomes persistent, since that would turn
the container into a credential store and change the calculus.
````

- [ ] **Step 2: Record the two research answers in `NOTES.md`**

Append, so the next person does not re-derive them:

````markdown
### Keychain: NOT required. Claude Code needs a credential store, not this one.

The first measurement was misleading and the correction is the useful part.
Keychain denied → `Failed to authenticate: OAuth session expired and could not
be refreshed`, which reads as "keychain required" and is not. It only showed
there was no usable credential anywhere *else*, because this host's
`~/.claude/.credentials.json` is a husk:

```
~/.claude/.credentials.json   accessToken ""        refreshToken ""        expiresAt 0 (epoch)
keychain item                 accessToken 108 chars refreshToken 108 chars expiresAt valid
```

Seed that file with the real token from the keychain item and it authenticates
with `~/Library/Keychains` **and** `com.apple.SecurityServer` /
`com.apple.securityd.xpc` all denied. So macOS Claude Code prefers the keychain
and falls back to the file; the keychain is a preference, not a requirement.

Task 4 therefore drops the grant entirely rather than relocating it, which
closes the item flagged above under "Keychain access is the widest grant in the
profile." Two things to keep an eye on: the fleet now holds a plaintext refresh
token on disk (0600 inside a 0700 dir — worse at rest than the keychain, far
better in blast radius), and two independent holders of one OAuth grant may
fight if refresh tokens rotate. See Task 4, Step 6.

**Unexplained:** the container fleet's `seed_fleet_claude_home()` copies the
same husk, yet those agents demonstrably worked, and there is no
`CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY` or `apiKeyHelper` anywhere in
that fleet's scripts. Either they authenticate by a path not visible in the
repo, or the seed has been overwriting a working credential with a husk on every
launch. Worth resolving before trusting the same mechanism.

### Seatbelt cannot express a destination policy

For the record, so nobody spends an afternoon on it. Every non-wildcard host
spelling is rejected by the compiler on this machine (Darwin 25.5.0):

```
(deny network-outbound (remote ip "192.168.1.0/24"))       -> port missing in network address
(deny network-outbound (remote ip "192.168.1.1:*"))        -> host must be * or localhost
(deny network-outbound (remote tcp "192.168.1.1:80"))      -> host must be * or localhost
(deny network-outbound (remote ip (regex #"^192\.168\.")))  -> remote expects string argument
```

Only `*` and `localhost` are accepted as hosts. That is why Task 6 restricts
egress to loopback and pushes the policy into `sbx-proxy.py`.

### launchd is NOT reachable from inside the profile

`sbx-common.sh` and `sbx-browser-run.sh` both assert that `launchctl setenv` is
reachable from the agent sandbox, and both are wrong. Tested:

```
launchctl setenv    -> "Not privileged to set domain environment."  (exit 1)
launchctl list      -> denied
launchctl bootstrap -> "Bootstrap failed: 5: Input/output error"; the job never ran
```

The `BROWSER_FINGERPRINT` / `BROWSER_CDP_PORT` argv hardening in
`sbx-browser-run.sh` is therefore defending a door that is already shut. Keep
it -- it costs nothing and does not depend on this holding -- but the comments
should not describe it as a live gap.
````

- [ ] **Step 3: Correct the two overclaiming comments**

In `sbx-common.sh:73-80` and `sbx-browser-run.sh:29-37`, change "`launchctl
setenv` is reachable from inside the agent's Seatbelt profile" to note that it
was tested and is **not** reachable, and that the argv hardening is retained as
defense in depth rather than as a live mitigation.

- [ ] **Step 4: Commit**

```bash
git add NOTES.md sbx-common.sh sbx-browser-run.sh
git commit -m "docs(sbx): record the keychain answer, Seatbelt's network limits, deferred items"
```

---

### Task 8: Update the fleet README

**Files:**
- Modify: `../README.md`

- [ ] **Step 1: Add a sandbox-exec isolation section**

The parent `README.md` documents two host-side boundaries for the *container*
fleet — the separate `~/.claude` and the pf LAN block. Both now have
sandbox-exec equivalents that work differently, and the pf section actively
misleads if read as covering this fleet. Add, after the existing "Isolation"
section:

````markdown
### The sandbox-exec fleet's boundaries

The `sandbox-exec-prototype/` fleet is native macOS processes under Seatbelt,
not containers, so neither host-side boundary above applies to it. It has its
own equivalents:

- **Its own `HOME`** — `~/.claude-sbx/home`, seeded one-way from the host on
  every launch (`seed_fleet_home()`), with the host's `~/.claude`, `~/.npm` and
  `~/.claude.json` explicitly denied in the profile. Session transcripts are
  never copied. Same reasoning as `seed_fleet_claude_home()` above.
- **No keychain at all** — the host login keychain is denied and the fleet uses
  a seeded `~/.claude/.credentials.json` instead. Claude Code needs a credential
  store, not the keychain specifically.
- **LAN egress is NOT blocked — know this.** The pf anchor in
  `pf/claude-agent.pf` filters on the container bridge and does nothing for
  native processes, and Seatbelt cannot express a destination policy. The
  loopback-only design that would fix it breaks `--remote-control`. An egress
  proxy (`sbx-proxy.py`, `127.0.0.1:8888`) carries the API traffic and refuses
  private destinations, but agents can still reach the LAN directly. See
  `sandbox-exec-prototype/NOTES.md`.
````

- [ ] **Step 2: Commit**

```bash
git add ../README.md
git commit -m "docs: document the sandbox-exec fleet's host-side boundaries"
```

---

## Verification checklist

After Task 8, all of this should hold at once:

```bash
cd ~/dev/claude-agent/sandbox-exec-prototype
./sbx-verify.sh              # fail=0, including sections [7]-[11]
                             # NOTE: [11] asserts the LAN is REACHABLE — that is
                             # the accepted exposure from Task 6, not a bug
./sbx-verify-browser.sh      # 20/20, unchanged by this work
./sbx-status.sh              # 5 agents + browser + proxy, all up
```

And by hand, in a live `sbx-agent-1` session:

| probe | expected |
|---|---|
| `! cat ~/.claude/settings.json` | **succeeds** — `~` is now the fleet home, and this is the seeded copy. Tampering with it is repaired within 30s |
| `! cat /Users/brianlow/.claude/settings.json` | `Operation not permitted` — the host's, by absolute path |
| `! ls /Users/brianlow/.claude/projects` | `Operation not permitted` |
| `! cat /Users/brianlow/Library/Keychains/login.keychain-db` | `Operation not permitted` |
| `! curl -sS --max-time 5 http://192.168.1.1/` | **succeeds** — accepted exposure, Task 6 option A |
| `! curl -sS --max-time 10 https://example.com` | succeeds |
| the session appears in the desktop app | proves the bridge still works — the thing Task 6 must not break |
| the session responds at all | proves the seeded credential file works with no keychain |

## What this plan does not fix

Stated plainly so it is not mistaken for coverage:

- **Exfiltration of everything in the allow-list.** `NOTES.md:345` accepts this
  and the acceptance stands. Task 5 narrows it — the proxy is now a chokepoint
  where a domain allow-list *could* live — but this plan does not add one. The
  vault, Bear notes, gcalcli OAuth tokens and the fleet's own state remain
  exfiltratable by a prompt-injected agent over HTTPS to any public host.
- **LAN egress.** Not fixed, and the reason is in Task 6: it cannot be expressed
  in the profile, and the loopback-only design that works breaks
  `--remote-control`. The router, NAS and everything on `192.168.1.0/24` stay
  reachable from a prompt-injected agent. Task 6 option B (dedicated uid + a pf
  `user` rule) is the real fix and is a project of its own.
- **The vault itself.** Write access is unguarded by design (Hermes needs it),
  so a poisoned note remains the primary injection vector, and one agent can
  still plant a note another reads as instructions. See deferred item 2.
- **Anything an agent can do *inside* the sandbox.** `NOTES.md:215` is right
  that the profile controls what code can reach, not what code runs.

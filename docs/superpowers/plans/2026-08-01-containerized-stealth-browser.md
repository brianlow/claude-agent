# Containerized Stealth Browser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move CloakBrowser out of its GUI-privileged Seatbelt profile and into an Apple container, keeping the existing design where launchd owns the browser and `sbx-agent-1` drives it over CDP on loopback.

**Architecture:** The launchd job `com.brianlow.claude-sbx.browser` stops running `sandbox-exec … Chromium.app` and starts running `container run cloakhq/cloakbrowser:0.5.3 cloakserve`. The agent side is untouched: it still talks to `127.0.0.1:9222`. `profiles/07-browser.sb.template` — the only profile on this machine holding WindowServer and LaunchServices — is deleted.

**Tech Stack:** bash, Apple `container` CLI 0.11.0 (macOS 26.5.2), `cloakhq/cloakbrowser` (linux/arm64), `cloakserve` CDP proxy, `agent-browser` 0.27.0, launchd.

**Spec:** `docs/superpowers/specs/2026-08-01-containerized-stealth-browser-design.md`

## Global Constraints

- **Nothing outside `sandbox-exec-prototype/` and `docs/` may be modified.** Not `entrypoint.sh`, `agent-run.sh`, `common.sh`, `Dockerfile`, or `../launchd/`. This ground rule predates this work and is still in force.
- **The agent half is untouched:** `sbx-agent-run.sh`, `profiles/06-production.sb.template`, `pty-run.py`, `fleet-settings.json`.
- **`./verify.sh generated/sbx-agent-1.sb` must report 16/16 at every commit.** It is the regression gate on the agent profile.
- **No Docker.** Apple `container` only. A step that fails under Apple `container` gets a different approach within Apple `container`, not a second runtime.
- **Image is pinned:** `cloakhq/cloakbrowser:0.5.3`. Never `:latest`.
- **CDP is published to `127.0.0.1` only.** Never a routable host address. CDP is unauthenticated; loopback is the entire boundary.
- **No account logins** in the browser profile. It must not become a credential store.
- Browser state lives at `sandbox-exec-prototype/browser-profile/` and is gitignored.
- Shell scripts here use `set -euo pipefail` (except `fleet-common.sh`, which is sourced and deliberately does not).
- **Run commands from `sandbox-exec-prototype/`** unless the path in the command says otherwise. `git` commands run from the repo root; the paths in them are written repo-relative so they work from either.

## File Structure

| file | responsibility | task |
|---|---|---|
| `sandbox-exec-prototype/.gitignore` | keep browser state out of git | 3 |
| `fleet-common.sh` (browser block, lines ~49-100) | image/container/port/seed config + container-aware `browser_state` | 3 |
| `sbx-browser-run.sh` | rewritten: one foreground `container run`, launchd-supervised | 4 |
| `verify-browser.sh` | rewritten: container security assertions, not Seatbelt ones | 2 |
| `verify-detection.sh` | **new**: bot-detection scores over CDP | 5 |
| `profiles/07-browser.sb.template` | **deleted** | 6 |
| `probe-cloakbrowser.sh` | **deleted** | 6 |
| `NOTES.md`, `PLAN.md` | the record | 1, 5, 7 |

---

### Task 1: Phase 0 spike — prove the container serves CDP and answer four open questions

Nothing in this task changes the fleet. It is a hand-run spike whose deliverable is a set of **recorded facts** that later tasks depend on. `NOTES.md` is the repo's authoritative record and this is how it has been used throughout the prototype.

Four questions must come out with an answer, because later tasks encode them:

- **Q1** Does `--publish 127.0.0.1:9222:9222` actually confine the port to loopback?
- **Q2** Does a `cloakserve --data-dir` bind mount persist cookies across a container restart? (The README calls per-seed profile dirs "temporary" — persistence is the spec's stated goal but is *not* documented for `cloakserve`.)
- **Q3** Does `cloakserve --fingerprint=<seed>` pin a stable identity?
- **Q4** Does the free binary in the image run `cloakserve` without a license key?

**Files:**
- Modify: `sandbox-exec-prototype/NOTES.md` (append a new section)

**Interfaces:**
- Produces: the recorded answers to Q1-Q4, plus the exact `container ls -q` output shape, which Task 3 and Task 4 encode.

- [ ] **Step 1: Start the container system and pull the pinned image**

```bash
container system start
container image pull cloakhq/cloakbrowser:0.5.3
container image ls | grep cloakbrowser
```

Expected: the image lists. It is a multi-arch index with a real `linux/arm64` manifest (already verified against the registry), so no `--arch` flag and no Rosetta.

- [ ] **Step 2: Confirm the free binary works with no license key (Q4)**

```bash
container run --rm cloakhq/cloakbrowser:0.5.3 cloaktest 2>&1 | tail -30
```

Expected: the self-test runs and reports detection results. Record whether it warns about a missing `CLOAKBROWSER_LICENSE_KEY`, and whether it attempts a network call to `cloakbrowser.dev`. The image ships the free binary; a license key only swaps in the newer Pro binary at runtime.

- [ ] **Step 3: Start `cloakserve` by hand**

```bash
mkdir -p /tmp/cb-spike-profile
container run --detach --name cb-spike \
  --publish "127.0.0.1:9222:9222" \
  --mount "source=/tmp/cb-spike-profile,target=/profile" \
  --memory 4g --cpus 2 \
  cloakhq/cloakbrowser:0.5.3 \
  cloakserve --data-dir=/profile --fingerprint=41337
sleep 10
container logs cb-spike | tail -20
```

`--memory 4g`: Apple `container` defaults are modest and Chromium is not. The README measures ~190MB idle / ~280MB with 3 tabs, so 4g is generous headroom, not a tuned value.

- [ ] **Step 4: Confirm CDP answers on loopback, and record the container listing format**

```bash
curl -s http://127.0.0.1:9222/json/version | python3 -m json.tool
container ls -q
container ls -a --format json | python3 -m json.tool | head -40
```

Expected: `/json/version` returns a Chrome version document with a `webSocketDebuggerUrl` rewritten to point back through `cloakserve`. `container ls -q` prints `cb-spike` on its own line — **record this**; Task 3 matches on it with `grep -qx`.

- [ ] **Step 5: Answer Q1 — is the port confined to loopback?**

```bash
LANIP="$(ipconfig getifaddr en0 || ipconfig getifaddr en1)"; echo "LAN IP: ${LANIP}"
curl -s --max-time 3 "http://${LANIP}:9222/json/version" ; echo "exit=$?"
sysctl -n net.inet.ip.forwarding
container ls -a --format json | python3 -c 'import sys,json; print([c.get("networks") for c in json.load(sys.stdin)])'
```

Expected and required: the LAN-IP curl **fails** (non-zero exit — connection refused), and `net.inet.ip.forwarding` is `0`. Together these mean nothing outside this Mac can reach 9222: the published socket is loopback-only, and the container's own vmnet address is not routed off-host.

**This is the security gate.** If the LAN-IP curl succeeds, stop and report it before going further — with Docker off the table, the answer is a different Apple `container` networking mode, not a runtime switch.

- [ ] **Step 6: Drive it with `agent-browser` from the host**

```bash
agent-browser connect http://127.0.0.1:9222
agent-browser open https://example.com
agent-browser get title
```

Expected: `Example Domain`. This is the exact call path `sbx-agent-1` uses, minus the sandbox.

Then check what the free tier's **one concurrent session** actually means in practice, since `cloakserve` multiplexes by spawning a browser per seed:

```bash
curl -s http://127.0.0.1:9222/ | python3 -m json.tool      # PIDs, ports, connection counts
curl -s "http://127.0.0.1:9222/json/version?fingerprint=99999" ; echo
container logs cb-spike | tail -20
```

Record whether a second seed spawns a second browser, is refused, or silently degrades. One agent uses one seed, so this is a "know the edge" check rather than a blocker — but a silent degradation is exactly the kind of thing that gets misdiagnosed later.

- [ ] **Step 7: Answer Q2 — does the profile survive a restart?**

```bash
agent-browser eval "document.cookie = 'sbxprobe=1; max-age=86400; path=/'"
agent-browser eval "document.cookie"        # expect: sbxprobe=1
ls -la /tmp/cb-spike-profile

container stop cb-spike && container rm cb-spike
container run --detach --name cb-spike \
  --publish "127.0.0.1:9222:9222" \
  --mount "source=/tmp/cb-spike-profile,target=/profile" \
  --memory 4g --cpus 2 \
  cloakhq/cloakbrowser:0.5.3 \
  cloakserve --data-dir=/profile --fingerprint=41337
sleep 10
agent-browser connect http://127.0.0.1:9222
agent-browser open https://example.com
agent-browser eval "document.cookie"        # persistent? expect: sbxprobe=1
```

Record the answer plainly. **If the cookie is gone**, the spec's "persistent profile" goal is not achievable through `cloakserve --data-dir`, and Task 4 gets an extra step (written there) to try `--user-data-dir=/profile` as a browser passthrough flag instead. Do not silently accept an ephemeral profile — it is a stated goal, and `NOTES.md` must say which way it went and why.

- [ ] **Step 8: Answer Q3 — is the fingerprint seed pinned?**

```bash
agent-browser eval "navigator.hardwareConcurrency + ' / ' + navigator.deviceMemory"
agent-browser eval "(()=>{const c=document.createElement('canvas').getContext('webgl');const d=c.getExtension('WEBGL_debug_renderer_info');return c.getParameter(d.UNMASKED_RENDERER_WEBGL)})()"
```

Run both before and after the Step 7 restart. With `--fingerprint=41337` pinned, the values must be **identical** across restarts. Record both readings. The renderer string also answers the spec's GPU risk: a working WebGL context with a plausible renderer in a genuinely GPU-less VM.

- [ ] **Step 9: Tear the spike down**

```bash
container stop cb-spike && container rm cb-spike
rm -rf /tmp/cb-spike-profile
container ls -a
```

Expected: no `cb-spike`. The spike must leave nothing behind — the fleet's container comes later and under a different name.

- [ ] **Step 10: Record the findings in NOTES.md**

Append a section titled `## Browser in a container — Phase 0 (2026-08-01)` covering, each as a stated answer rather than a narrative: Q1 loopback confinement (with the two commands and their results), Q2 persistence, Q3 seed pinning, Q4 license, the `container ls -q` output shape, and anything that surprised you. Follow the file's existing convention: findings first, and say plainly what is *not* proven.

- [ ] **Step 11: Commit**

```bash
git add sandbox-exec-prototype/NOTES.md
git commit -m "docs(sandbox-exec): phase 0 — cloakserve in an Apple container over CDP"
```

---

### Task 2: Rewrite `verify-browser.sh` for the container world

The current 20 assertions are all `sandbox-exec` probes against profile 07 and become meaningless the moment the browser is a container. This task rewrites them **before** the swap, so the swap has a gate to pass. Run it against a hand-started container (same command as Task 1 Step 3, but with the fleet's real name and paths) — it should pass on the hand-started container, and it will keep passing after Task 4 makes launchd start the same container.

**Files:**
- Modify: `sandbox-exec-prototype/verify-browser.sh` (full rewrite)

**Interfaces:**
- Consumes: `BROWSER_CONTAINER`, `BROWSER_CDP_PORT`, `BROWSER_DATA_DIR` from `fleet-common.sh` (Task 3 defines them; this task writes the file that reads them, so Task 3 must land before this runs green — do Task 3 first if executing strictly in order, or accept that Step 2 here fails until then).

**Note on ordering:** if you are executing tasks in order, **do Task 3 before running this script**. The rewrite is written here because the assertions are the specification of what Task 3 and Task 4 must satisfy.

- [ ] **Step 1: Write the new `verify-browser.sh`**

```bash
#!/usr/bin/env bash
# verify-browser.sh — assert the security properties of the browser CONTAINER.
#
# This file used to assert the security property of a SECOND SEATBELT PROFILE.
# That profile is gone: the browser now runs in an Apple container, so the
# things worth asserting changed shape entirely.
#
# What is being defended, and why each check exists:
#
#   1. CDP is unauthenticated. Chromium's debug port trusts every connection it
#      can see, so the ONLY boundary is who can reach the socket. Loopback
#      confinement is therefore not a nicety — it is the whole security model,
#      and it gets two checks, not one.
#   2. The container must hold nothing of value. The old profile's value was in
#      what it did NOT grant; the container's value is in what is NOT mounted.
#   3. A wedged browser must mean "no browser", never "an unconfined browser".
#      agent-browser falls back to launching /Applications/Google Chrome when
#      no CDP port answers; the AGENT's profile denies that exec, and that
#      denial is what makes the failure mode safe.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/fleet-common.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

echo "=== browser container: ${BROWSER_CONTAINER} (${BROWSER_IMAGE})"
echo
echo "--- the browser must actually be there"
if curl -s --max-time 5 "http://127.0.0.1:${BROWSER_CDP_PORT}/json/version" >/dev/null 2>&1; then
  ok "CDP answers on 127.0.0.1:${BROWSER_CDP_PORT}"
else
  bad "CDP does not answer on 127.0.0.1:${BROWSER_CDP_PORT} — is the job loaded?"
fi

echo
echo "--- CDP must be unreachable from anywhere but this Mac"
# CDP has no auth, so this is the entire boundary. Two independent facts have
# to hold: the published socket is loopback-only, and the container's own
# vmnet address is not routed off-host.
LANIP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
if [ -z "${LANIP}" ]; then
  printf '  \033[33mn/a\033[0m   no LAN address on en0/en1 — cannot test off-host reachability\n'
elif curl -s --max-time 3 "http://${LANIP}:${BROWSER_CDP_PORT}/json/version" >/dev/null 2>&1; then
  bad "CDP is reachable on the LAN address ${LANIP} — UNAUTHENTICATED AND EXPOSED"
else
  ok "CDP not reachable on LAN address ${LANIP}"
fi

if [ "$(sysctl -n net.inet.ip.forwarding 2>/dev/null || echo 1)" = "0" ]; then
  ok "IP forwarding off — container subnet is not routed off-host"
else
  bad "IP forwarding is ON — the container's vmnet address may be reachable from the LAN"
fi

echo
echo "--- the container must hold nothing of value"
MOUNTS="$(container inspect "${BROWSER_CONTAINER}" 2>/dev/null \
  | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: print("PARSE-ERROR"); raise SystemExit
c=d[0] if isinstance(d,list) else d
src=[]
for m in (c.get("configuration",{}).get("mounts") or c.get("mounts") or []):
    s=m.get("source") or (m.get("type") or {}).get("virtiofs",{}).get("source")
    if s: src.append(s)
print("\n".join(src))' || echo "PARSE-ERROR")"

if [ "${MOUNTS}" = "PARSE-ERROR" ]; then
  bad "could not read mounts from container inspect"
else
  UNEXPECTED="$(printf '%s\n' "${MOUNTS}" | grep -v "^${BROWSER_DATA_DIR}$" | grep -v '^$' || true)"
  if [ -n "${UNEXPECTED}" ]; then
    bad "unexpected mounts: ${UNEXPECTED}"
  else
    ok "only mount is the browser profile dir"
  fi
fi

for secret in "${VAULT}" "${BEAR_DIR}" "${HOME}/.ssh" "${HOME}/.claude" "${HOME}/Library/Keychains"; do
  if printf '%s\n' "${MOUNTS}" | grep -qF "${secret}"; then
    bad "SECRET MOUNTED INTO THE BROWSER: ${secret}"
  else
    ok "not mounted: $(basename "${secret}")"
  fi
done

echo
echo "--- the browser must not be able to read the host filesystem"
# Probe a HOST-ONLY path. /etc/passwd would be a false pass: the container has
# its own, so reading it proves nothing. /Users/ does not exist inside the
# image, so seeing this user's home directory listed there would mean a mount
# is exposing the host — the one thing a future "just one more --mount" would
# silently do.
if agent-browser connect "http://127.0.0.1:${BROWSER_CDP_PORT}" >/dev/null 2>&1 \
   && agent-browser open "file:///Users/" >/dev/null 2>&1 \
   && agent-browser get text 2>/dev/null | grep -qF "$(basename "${HOME}")"; then
  bad "browser can see the host filesystem through file:///Users/"
else
  ok "host filesystem not visible through file://"
fi

echo
echo "--- a wedged browser must mean 'no browser', not 'an unconfined browser'"
# agent-browser auto-launches /Applications/Google Chrome when no CDP port
# answers. The AGENT's profile denies that exec — assert it still does, without
# stopping the browser.
AGENT_PROFILE="${GEN_DIR}/sbx-agent-1.sb"
if [ ! -f "${AGENT_PROFILE}" ]; then
  printf '  \033[33mn/a\033[0m   %s not rendered — run ./sbx-start.sh first\n' "${AGENT_PROFILE}"
elif sandbox-exec -f "${AGENT_PROFILE}" "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --version >/dev/null 2>&1; then
  bad "agent profile can exec Google Chrome — the fallback path is open"
else
  ok "agent profile still denies exec of /Applications/Google Chrome"
fi

echo
echo "=== ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
```

- [ ] **Step 2: Run it with no container running — it must fail loudly**

```bash
./verify-browser.sh; echo "exit=$?"
```

Expected: FAIL on "CDP answers", non-zero exit. A verification script that passes when the thing under test is absent is worthless; this is the check that it isn't.

- [ ] **Step 3: Start the real container by hand and run it again**

```bash
mkdir -p browser-profile
container run --detach --name sbx-browser \
  --publish "127.0.0.1:9222:9222" \
  --mount "source=$(pwd)/browser-profile,target=/profile" \
  --memory 4g --cpus 2 \
  cloakhq/cloakbrowser:0.5.3 \
  cloakserve --data-dir=/profile --fingerprint=41337
sleep 10
./verify-browser.sh; echo "exit=$?"
```

Expected: all checks pass, exit 0. If the `container inspect` mount parsing prints `PARSE-ERROR`, fix the parser against the real JSON (`container inspect sbx-browser | python3 -m json.tool`) — the shape is version-specific and the recorded output from Task 1 Step 4 is the reference.

- [ ] **Step 4: Leave the hand-started container up for Task 4, and commit**

```bash
git add sandbox-exec-prototype/verify-browser.sh
git commit -m "test(sandbox-exec): assert the browser container's boundary, not a Seatbelt profile's"
```

---

### Task 3: Point `fleet-common.sh` at the container, and gitignore the profile dir

**Files:**
- Modify: `sandbox-exec-prototype/fleet-common.sh:49-100` (the browser block)
- Modify: `sandbox-exec-prototype/.gitignore`

**Interfaces:**
- Produces: `BROWSER_IMAGE`, `BROWSER_CONTAINER`, `BROWSER_DATA_DIR`, `BROWSER_CDP_PORT`, `BROWSER_FINGERPRINT`, `browser_container_running()`, `browser_state()`. Consumed by Tasks 2, 4, 5.
- Removes: `BROWSER_PROFILE`, `BROWSER_PROFILE_TEMPLATE`, `cloak_bin()`, `render_browser_profile()`, `browser_pid()`.

- [ ] **Step 1: Add the gitignore entry**

Append to `sandbox-exec-prototype/.gitignore`:

```
browser-profile/
```

- [ ] **Step 2: Replace the browser block in `fleet-common.sh`**

Replace everything from the `# --- browser (the second sandbox) ---` comment through the end of `render_browser_profile()` with:

```bash
# --- browser (a container, not a second sandbox) -----------------------------
# The browser USED to run natively under profiles/07-browser.sb.template. It
# could not run in the agent's profile: it needs LaunchServices
# (TransformProcessType abort()s without it) and WindowServer (SIGSEGV in
# -[NSWindow _close] without it) — precisely the grants revisions 04 and 05
# removed to close the `open -a` confused-deputy escape.
#
# Giving those grants to a second profile moved that escape rather than
# deleting it: a Chromium exploit from a hostile page landed in a sandbox that
# could launch unconfined GUI apps. A Linux container has no LaunchServices and
# no WindowServer to grant, so the capability is gone rather than relocated.
#
# What is deliberately unchanged: launchd owns the browser's command line, not
# the agent. A hostile session operator cannot add --allow-file-access, repoint
# the profile dir, load an extension, or add a mount. The agent's only reach is
# CDP, and CDP has no verb that spawns a process.
BROWSER_IMAGE="cloakhq/cloakbrowser:0.5.3"     # pinned; :latest would change the browser under us
BROWSER_CONTAINER="sbx-browser"
BROWSER_DATA_DIR="${SBX_DIR}/browser-profile"  # in-repo and gitignored, so browser state is local to the project

# Bound to loopback on the host side. Chromium's CDP has NO authentication, so
# this port is ambient authority for every local process — not just our agent.
# Loopback is what keeps it off the network; there is no auth to add.
BROWSER_CDP_PORT="${BROWSER_CDP_PORT:-9222}"

# A pinned fingerprint seed. Without one, CloakBrowser generates a random
# identity at every startup — so a launchd restart would make the same cookie
# jar arrive on the same site wearing a different device. Cookies and identity
# have to agree; this is what makes the persistent profile coherent.
BROWSER_FINGERPRINT="${BROWSER_FINGERPRINT:-41337}"

browser_label() { printf '%s.browser' "${LABEL_PREFIX}"; }
browser_plist() { printf '%s/%s.plist' "${PLIST_DIR}" "$(browser_label)"; }

# `container ls -q` prints one container ID per line, and --name sets the ID.
# Matching whole lines keeps this independent of the table format.
browser_container_running() { container ls -q 2>/dev/null | grep -qx "${BROWSER_CONTAINER}"; }
browser_container_present() { container ls -a -q 2>/dev/null | grep -qx "${BROWSER_CONTAINER}"; }

browser_state() {
  if ! browser_container_present; then printf 'absent'; return; fi
  if ! browser_container_running; then printf 'stopped'; return; fi
  # A running container is NOT proof of a working browser, and launchd cannot
  # tell the difference — KeepAlive only sees that the job still exists. The
  # CDP probe is the source of truth, same as it was for the native browser.
  if curl -s --max-time 2 "http://127.0.0.1:${BROWSER_CDP_PORT}/json/version" >/dev/null 2>&1; then
    printf 'running (container, CDP %s ok)' "${BROWSER_CDP_PORT}"
  else
    printf 'running (container up, CDP NOT RESPONDING)'
  fi
}
```

- [ ] **Step 3: Verify no dangling references to the deleted helpers**

```bash
grep -rn "cloak_bin\|render_browser_profile\|BROWSER_PROFILE\|browser_pid" sandbox-exec-prototype/ --include="*.sh"
```

Expected: hits only in `sbx-start.sh`, `sbx-stop.sh`, and `sbx-browser-run.sh` — all rewritten in Task 4. If `verify-browser.sh` appears, Task 2's rewrite was not applied.

- [ ] **Step 4: Check the file still sources cleanly**

```bash
bash -c 'source sandbox-exec-prototype/fleet-common.sh && echo "$BROWSER_IMAGE $BROWSER_CONTAINER $BROWSER_DATA_DIR $BROWSER_CDP_PORT $BROWSER_FINGERPRINT" && browser_state && echo'
```

Expected: the config line, then `running (container, CDP 9222 ok)` from the container Task 2 left up.

- [ ] **Step 5: Confirm the browser profile dir is not committable**

```bash
git status --short sandbox-exec-prototype/browser-profile/ ; git check-ignore -v sandbox-exec-prototype/browser-profile/
```

Expected: no untracked files listed, and `check-ignore` names the `.gitignore` line. Browser state must never be committable.

- [ ] **Step 6: Commit**

```bash
git add sandbox-exec-prototype/fleet-common.sh sandbox-exec-prototype/.gitignore
git commit -m "feat(sandbox-exec): fleet config points at the browser container"
```

---

### Task 4: Rewrite `sbx-browser-run.sh` and swap the launchd job

**Files:**
- Modify: `sandbox-exec-prototype/sbx-browser-run.sh` (full rewrite)
- Modify: `sandbox-exec-prototype/sbx-start.sh:11-27` (the browser bootstrap block)
- Modify: `sandbox-exec-prototype/sbx-stop.sh:37-51` (the browser teardown block)

**Interfaces:**
- Consumes: everything Task 3 produces.
- Produces: a launchd-supervised container under the existing label `com.brianlow.claude-sbx.browser`. `render_browser_plist()` in `fleet-common.sh` needs no change — it already points at `sbx-browser-run.sh`.

- [ ] **Step 1: Stop the hand-started container from Task 2**

```bash
container stop sbx-browser && container rm sbx-browser
./verify-browser.sh; echo "exit=$?"
```

Expected: FAIL, non-zero. This is the red state that Step 5 turns green through launchd instead of by hand.

- [ ] **Step 2: Write the new `sbx-browser-run.sh`**

```bash
#!/usr/bin/env bash
# sbx-browser-run.sh — CloakBrowser in an Apple container, foreground,
# launchd-managed. One `container run`, no pty (unlike the agent, no TUI).
#
# WHY A CONTAINER AND NOT A SANDBOX
#
# This job used to be `sandbox-exec -f profiles/07-browser.sb ... Chromium.app`.
# CloakBrowser cannot run in the AGENT's profile — it abort()s in
# TransformProcessType without LaunchServices and SIGSEGVs in -[NSWindow _close]
# without WindowServer, which are exactly the grants revisions 04 and 05 removed
# to close the `open -a` confused-deputy escape.
#
# Giving those grants to a second Seatbelt profile MOVED that escape instead of
# deleting it. A Linux container has neither service to grant, so the capability
# is gone. That is the entire point of this job's existence in this form.
#
# THE AGENT DOES NOT LAUNCH THIS, and that is a security property rather than a
# packaging accident: launchd owns this command line, so a hostile session
# operator cannot add --allow-file-access, repoint --data-dir, add a --mount, or
# load an extension. The agent's only reach is CDP on loopback, and CDP has no
# verb that spawns a process.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/fleet-common.sh"

mkdir -p "${LOG_DIR}" "${BROWSER_DATA_DIR}"

# The container system may still be coming up (e.g. just after login), and
# launchd will have started this job before anyone ran a container command.
container system status &>/dev/null || container system start

# Clean slot: drop any stale/stopped/running container with this name, so a
# reboot or a crashed job never wedges the name. Same reason ../agent-run.sh
# does it.
container rm -f "${BROWSER_CONTAINER}" &>/dev/null || true

echo "$(date '+%Y-%m-%dT%H:%M:%S') starting browser container"
echo "  image     : ${BROWSER_IMAGE}"
echo "  container : ${BROWSER_CONTAINER}"
echo "  profile   : ${BROWSER_DATA_DIR}"
echo "  cdp       : 127.0.0.1:${BROWSER_CDP_PORT}"
echo "  seed      : ${BROWSER_FINGERPRINT}"

# --publish 127.0.0.1:...  loopback EXPLICITLY. Never a routable address: CDP is
#   unauthenticated, so binding it anywhere reachable hands the browser to the
#   network. verify-browser.sh asserts this from the outside.
# --mount  the only mount. Nothing else may be added here — the container's
#   security value is precisely that it holds nothing worth stealing.
# --memory 4g  Apple container defaults are modest and Chromium is not.
# no -d  foreground, so launchd tracks the process lifetime and KeepAlive works.
# no caffeinate  the agent job already holds the Mac awake; a browser with no
#   agent driving it has no reason to prevent sleep.
exec container run \
  --name "${BROWSER_CONTAINER}" \
  --rm \
  --publish "127.0.0.1:${BROWSER_CDP_PORT}:9222" \
  --mount "source=${BROWSER_DATA_DIR},target=/profile" \
  --memory 4g \
  --cpus 2 \
  "${BROWSER_IMAGE}" \
  cloakserve --data-dir=/profile --fingerprint="${BROWSER_FINGERPRINT}"
```

**If Task 1 Step 7 found that `--data-dir` does not persist cookies across a restart:** change the final line to `cloakserve --data-dir=/profile --fingerprint="${BROWSER_FINGERPRINT}" --user-data-dir=/profile/chrome` (extra flags are forwarded to the browser), re-run the Task 1 Step 7 cookie probe, and record which form works in `NOTES.md`. If neither persists, say so in `NOTES.md` and flag it — the spec chose a persistent profile deliberately and an ephemeral one is a change to the design, not an implementation detail.

- [ ] **Step 3: Update the browser block in `sbx-start.sh`**

Replace the `if [ -n "$(cloak_bin)" ]; then ... fi` block (and the `${BROWSER_DATA_DIR}` in the `mkdir -p` line stays as is) with:

```bash
# Browser first: it's what the agents talk to, and the image takes a few
# seconds to come up. A missing container runtime is not fatal — the agents are
# useful without a browser.
if command -v container >/dev/null 2>&1; then
  render_browser_plist > "$(browser_plist)"
  if is_loaded_label "$(browser_label)"; then
    echo "browser: already loaded — leaving running."
  else
    echo "browser: bootstrapping..."
    launchctl bootstrap "${GUI_DOMAIN}" "$(browser_plist)" \
      || echo "browser: WARNING — bootstrap failed (see ${LOG_DIR}/browser.log)."
  fi
else
  echo "browser: Apple container CLI not found — skipping."
  echo "         to enable: install https://github.com/apple/container"
fi
```

- [ ] **Step 4: Update the browser block in `sbx-stop.sh`**

Replace the browser teardown block with:

```bash
if is_loaded_label "$(browser_label)"; then
  echo "browser: booting out..."
  launchctl bootout "${GUI_DOMAIN}/$(browser_label)" \
    || echo "browser: WARNING — bootout failed."
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    browser_container_present || break
    sleep 1
  done
  # `container run --rm` removes the container when it stops, but bootout kills
  # the CLI process rather than the container — confirm rather than assume, or
  # the next start finds the name taken and the port held.
  if browser_container_present; then
    echo "browser: container still present after bootout — removing"
    container rm -f "${BROWSER_CONTAINER}" >/dev/null 2>&1 || true
  fi
else
  echo "browser: not loaded."
fi
```

- [ ] **Step 5: Reload the job and verify it comes up green**

```bash
./sbx-stop.sh
./sbx-start.sh
sleep 15
./sbx-status.sh
./verify-browser.sh; echo "exit=$?"
```

Expected: `sbx-status.sh` shows `browser  loaded  running (container, CDP 9222 ok)`, and `verify-browser.sh` exits 0. If the job flaps, `tail -50 ~/.claude-sbx/logs/browser.log` — a 30s `ThrottleInterval` restart loop is the signature of a failure in the `container run` line itself.

- [ ] **Step 6: Verify the restart lever and the clean-slot behavior**

```bash
container rm -f sbx-browser
sleep 40
./sbx-status.sh
```

Expected: launchd's `KeepAlive` restarts the job and the container comes back on its own. This is the property that made the native job self-healing and it must survive the substrate change.

- [ ] **Step 7: Confirm the agent profile did not regress**

```bash
./verify.sh generated/sbx-agent-1.sb
```

Expected: **16/16**. Nothing in this task touches the agent profile, which is exactly why it is worth checking.

- [ ] **Step 8: Commit**

```bash
git add sandbox-exec-prototype/sbx-browser-run.sh sandbox-exec-prototype/sbx-start.sh sandbox-exec-prototype/sbx-stop.sh
git commit -m "feat(sandbox-exec): launchd runs the browser as a container"
```

---

### Task 5: `verify-detection.sh` — prove the Linux build still passes

The browser binary changes from macOS Chromium 145 (26 patches) to Linux Chromium 146 (58 patches). More patches on paper is not evidence, and this is the project's headline requirement.

**Files:**
- Create: `sandbox-exec-prototype/verify-detection.sh`
- Modify: `sandbox-exec-prototype/NOTES.md`

**Interfaces:**
- Consumes: `BROWSER_CDP_PORT` from `fleet-common.sh`; a running browser container.

- [ ] **Step 1: Write `verify-detection.sh`**

```bash
#!/usr/bin/env bash
# verify-detection.sh — does the containerized browser still beat bot detection?
#
# The whole point of CloakBrowser is fingerprint realism, and this change swaps
# the binary underneath it (macOS Chromium 145 / 26 patches -> Linux Chromium
# 146 / 58 patches) AND removes the GPU. Both are exactly the kind of change
# that passes every functional check while quietly failing the actual job.
#
# This does not replace real-world testing: synthetic suites measure the
# fingerprint, not whether a retailer serves you a product page.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/fleet-common.sh"

CDP="http://127.0.0.1:${BROWSER_CDP_PORT}"
curl -s --max-time 5 "${CDP}/json/version" >/dev/null 2>&1 || {
  echo "browser not answering on ${CDP} — start it with ./sbx-start.sh" >&2
  exit 1
}

agent-browser connect "${CDP}" >/dev/null

echo "=== environment"
agent-browser open "https://example.com" >/dev/null
echo "  userAgent   : $(agent-browser eval "navigator.userAgent" 2>/dev/null)"
echo "  platform    : $(agent-browser eval "navigator.platform" 2>/dev/null)"
echo "  webdriver   : $(agent-browser eval "navigator.webdriver" 2>/dev/null)"
echo "  cores/mem   : $(agent-browser eval "navigator.hardwareConcurrency + ' / ' + navigator.deviceMemory" 2>/dev/null)"
echo "  screen      : $(agent-browser eval "screen.width + 'x' + screen.height" 2>/dev/null)"

echo
echo "=== WebGL — a MISSING context is itself a fingerprint tell"
# NOTES.md records that CloakBrowser fabricates the renderer string (it claimed
# an M2 Max on an M1 Pro host under SwiftShader). The requirement is a WORKING
# context with a plausible string, NOT hardware acceleration — which is what
# makes a GPU-less VM viable at all. This is where that gets checked for real.
agent-browser eval "(()=>{const g=document.createElement('canvas').getContext('webgl');if(!g)return'NO WEBGL CONTEXT — FAIL';const d=g.getExtension('WEBGL_debug_renderer_info');return g.getParameter(d.UNMASKED_VENDOR_WEBGL)+' | '+g.getParameter(d.UNMASKED_RENDERER_WEBGL)})()"

echo
echo "=== incolumitas bot detection (scores near 1.0 are good)"
agent-browser open "https://bot.incolumitas.com/" >/dev/null
sleep 25   # the suite runs its tests asynchronously after load
agent-browser eval "document.getElementById('detection-tests') ? document.getElementById('detection-tests').innerText.slice(0,1200) : document.body.innerText.slice(0,1200)"

echo
echo "=== sannysoft"
agent-browser open "https://bot.sannysoft.com/" >/dev/null
sleep 8
agent-browser eval "Array.from(document.querySelectorAll('table tr')).slice(0,25).map(r=>r.innerText.replace(/\s+/g,' ')).join('\n')"

echo
echo "Record these in NOTES.md next to the macOS baseline. Red rows in sannysoft"
echo "and a low incolumitas score are the failures worth acting on; cosmetic"
echo "differences from the macOS run are expected — it is a different OS."
```

- [ ] **Step 2: Make it executable and run it**

```bash
chmod +x verify-detection.sh
./verify-detection.sh 2>&1 | tee /tmp/detection-container.txt
```

Expected: `navigator.webdriver` is `false`, WebGL returns a vendor/renderer pair rather than `NO WEBGL CONTEXT — FAIL`, sannysoft rows are green, and the incolumitas scores are near 1.0.

- [ ] **Step 3: If anything fails, try headed mode before concluding**

```bash
# Headed rendering into the image's Xvfb is closer to a real browser than
# headless, and costs nothing but RAM.
# In sbx-browser-run.sh, append --headless=false to the cloakserve line, then:
./sbx-stop.sh && ./sbx-start.sh && sleep 15
./verify-detection.sh 2>&1 | tee /tmp/detection-headed.txt
```

Keep whichever mode scores better and record both results. Do not keep `--headless=false` if it makes no difference — it is not free.

- [ ] **Step 4: Record the results in NOTES.md**

Append the scores to the Task 1 section, next to the macOS baseline the file already carries for the native browser. State plainly whether the containerized browser is better, the same, or worse than the macOS build, and name anything that regressed.

- [ ] **Step 5: Commit**

```bash
git add sandbox-exec-prototype/verify-detection.sh sandbox-exec-prototype/NOTES.md
git commit -m "test(sandbox-exec): bot-detection scores for the containerized browser"
```

---

### Task 6: Delete the second Seatbelt profile

Only now, with the container path green, does the old path come out. This is the task that actually achieves the spec's goal.

**Files:**
- Delete: `sandbox-exec-prototype/profiles/07-browser.sb.template`
- Delete: `sandbox-exec-prototype/probe-cloakbrowser.sh`
- Delete: `~/.claude-sbx/browser/` (runtime state, not in git)

- [ ] **Step 1: Confirm nothing still references them**

```bash
grep -rn "07-browser\|probe-cloakbrowser\|claude-sbx/browser" sandbox-exec-prototype/ docs/ --include="*.sh" --include="*.md" | grep -v "^docs/superpowers/"
```

Expected: hits only in `NOTES.md`/`PLAN.md` prose (handled in Task 7). Any hit in a `.sh` file must be fixed before deleting.

- [ ] **Step 2: Delete the profile and the probe**

```bash
git rm sandbox-exec-prototype/profiles/07-browser.sb.template sandbox-exec-prototype/probe-cloakbrowser.sh
```

- [ ] **Step 3: Confirm no Seatbelt profile grants the GUI services any more**

```bash
grep -rn "windowserver\|launchservicesd" sandbox-exec-prototype/profiles/ sandbox-exec-prototype/generated/ || echo "NONE — goal met"
```

Expected: `NONE — goal met`. This is success criterion #1 from the spec, and it is a one-line check.

- [ ] **Step 4: Remove the abandoned macOS browser state**

```bash
du -sh ~/.claude-sbx/browser
rm -rf ~/.claude-sbx/browser
ls ~/.claude-sbx
```

Expected: ~103M reclaimed; `~/.claude-sbx` keeps `logs/`, `pty-run.py`, `settings.json`, `agent-browser.json` — all still needed by the agent, which cannot read `~/dev`.

- [ ] **Step 5: Full regression run**

```bash
./sbx-status.sh
./verify.sh generated/sbx-agent-1.sb
./verify-browser.sh
```

Expected: agent + browser both running, `verify.sh` **16/16**, `verify-browser.sh` exit 0.

- [ ] **Step 6: Commit**

```bash
git add -A sandbox-exec-prototype/
git commit -m "refactor(sandbox-exec): delete the GUI-privileged browser profile"
```

---

### Task 7: Update the record

`NOTES.md` is the authoritative account for this prototype and several of its sections now describe a browser that no longer exists.

**Files:**
- Modify: `sandbox-exec-prototype/NOTES.md`
- Modify: `sandbox-exec-prototype/PLAN.md`

- [ ] **Step 1: Mark "CloakBrowser — built" superseded**

Add a banner at the top of that section, following the convention the file already uses for the earlier superseded section:

```markdown
> **Superseded 2026-08-01 by "Browser in a container" below.** The split-sandbox
> design was right about the shape — two capability sets, joined over CDP — and
> wrong that the browser half had to be a Seatbelt profile at all. The section's
> own honest note, "the rev-04 escape is moved, not deleted", is what eventually
> retired it: a Linux container has no LaunchServices or WindowServer to grant.
> Kept because the diagnosis (the TransformProcessType abort, the -[NSWindow
> _close] SIGSEGV) is what proved the two sets are irreconcilable in one profile.
```

- [ ] **Step 2: Update the "Still open" list**

In `NOTES.md`, the items "Decide whether the browser should stay logged in" and the CloakBrowser entries are now settled or moot. Mark what this work closed and leave the rest. Do not delete open items that are still open (Full Disk Access, the Keychain grant, `/private/tmp`, Playwright end-to-end, the stale vault docs).

- [ ] **Step 3: Update `PLAN.md`'s "Next session starts here"**

The current text says the split is load-bearing and points at profile 07. Replace the browser paragraph with the container arrangement, keeping the load-bearing property stated explicitly: launchd owns the browser's command line, the agent's only reach is CDP, and the browser holds nothing of value.

- [ ] **Step 4: Update the directory layout in `PLAN.md`**

Remove `07-browser.sb.template` and `probe-cloakbrowser.sh` from the layout block; add `verify-detection.sh` and `browser-profile/`.

- [ ] **Step 5: Commit**

```bash
git add sandbox-exec-prototype/NOTES.md sandbox-exec-prototype/PLAN.md
git commit -m "docs(sandbox-exec): the browser is a container now"
```

---

### Task 8: End-to-end from a live Fleet session

The last exit criterion, and the one no script can assert. `NOTES.md` lists this as open even for the native browser, so this closes a pre-existing gap too.

**Files:** none — this is a human-driven verification whose output is a `NOTES.md` entry.

- [ ] **Step 1: Confirm the fleet is up**

```bash
./sbx-status.sh
```

Expected: `sbx-agent-1` running and `browser  loaded  running (container, CDP 9222 ok)`.

- [ ] **Step 2: From Claude Desktop's Fleet view, open the `sbx-agent-1` session and ask it to research a real product**

Give it a concrete task against a real retailer — a product page with a price, not a synthetic detection suite. The agent should reach the browser via `agent-browser` with no special instructions, since `~/.claude-sbx/agent-browser.json` already points at `9222`.

- [ ] **Step 3: Watch for the failure modes that matter**

- The agent reports the browser is unavailable → check `~/.claude-sbx/logs/browser.log` and `container ls`.
- The agent tries to launch a local Chrome → the agent profile denies it (`Operation not permitted (os error 1)`). That is the safe failure, but it means CDP was unreachable; find out why.
- The page loads but shows a challenge/block → a real detection failure. Record the site and the symptom; this is the signal `verify-detection.sh` cannot produce.

- [ ] **Step 4: Record the outcome in NOTES.md and commit**

```bash
git add sandbox-exec-prototype/NOTES.md
git commit -m "docs(sandbox-exec): live Fleet session drives the browser container"
```

---

## Done when

1. No file under `sandbox-exec-prototype/` grants WindowServer or LaunchServices (Task 6 Step 3).
2. `./verify.sh generated/sbx-agent-1.sb` → 16/16.
3. `./verify-browser.sh` → exit 0, including both loopback-confinement checks.
4. `./verify-detection.sh` → scores recorded in `NOTES.md`, no worse than the macOS baseline.
5. A live Fleet session researched a real product through the container.

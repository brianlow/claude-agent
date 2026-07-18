# launchd Agent Fleet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One idempotent command (`start-agents`) brings up 5 crash-recovering Claude agents supervised by launchd, reachable via the Claude desktop app, with status output — replacing the single foreground bash loop.

**Architecture:** Five per-agent launchd jobs (`com.brianlow.claude-agent.1..5`) with `KeepAlive` restart the agent on any exit. Each job runs `agent-run.sh N`, which clears any stale container (killing the post-reboot wedge) then runs `agent-N` in the foreground under `caffeinate`. A sourced `common.sh` holds all config, the plist template, and the status renderer; `start-agents.sh` / `stop-agents.sh` / `agents-status.sh` are thin drivers.

**Tech Stack:** bash, Apple Container (`container` CLI), launchd (`launchctl`), `jq`, `caffeinate`. macOS on Apple Silicon.

## Global Constraints

- Platform: Apple Silicon macOS 26+ with Apple Container installed. Verified: `container run` has **no** `--restart`/daemon; supervision must be host-side.
- Agent names are fixed: `agent-1`..`agent-5`. launchd labels: `com.brianlow.claude-agent.<N>`. Remote-control session name == container name.
- launchd label domain: `gui/$(id -u)` (uid is `501` on this machine; use `$(id -u)`, never hardcode).
- launchd jobs get a minimal environment: scripts MUST set an explicit `PATH` and use absolute paths in plists (launchd does not expand `~`).
- Container status source of truth: `container list --all --format json` → objects with `.configuration.id` (e.g. `"agent-3"`) and `.status` (`running`|`stopped`); absent from the list == `absent`.
- `common.sh` is **sourced**, not executed: it defines vars/functions and must NOT set `set -euo pipefail` (that would leak into callers). Every executable script sets `set -euo pipefail` itself.
- Plists are **generated** into `./launchd/` (git-ignored), regenerated on every `start-agents`. Not installed in `~/Library/LaunchAgents` (no login auto-start — startup is the manual `start-agents`).
- Logs: `~/.claude-agent/logs/agent-<N>.log`.
- NOTE: 5 agents from the *old* mechanism are currently running. The new `start-agents`/`agent-run.sh` take them over cleanly via `container rm -f agent-N` on each launch (agents are disposable).

---

### Task 1: `common.sh` — shared config, helpers, plist template, status renderer

**Files:**
- Create: `common.sh`
- Test: `test/test-common.sh` (assertion harness)

**Interfaces:**
- Consumes: nothing.
- Produces (sourced by every other script):
  - Vars: `REPO_DIR`, `AGENTS=(1 2 3 4 5)`, `LABEL_PREFIX="com.brianlow.claude-agent"`, `IMAGE="claude-code:latest"`, `LOG_DIR`, `PLIST_DIR`, `GUI_DOMAIN`, `VAULT`, `BEAR_DIR`.
  - `label_for N` → `com.brianlow.claude-agent.N`
  - `plist_for N` → absolute path `${PLIST_DIR}/<label>.plist`
  - `is_loaded N` → exit 0 if launchd job loaded, else 1
  - `container_state N` → prints `running`|`stopped`|`absent`
  - `render_plist N` → prints the plist XML to stdout
  - `print_status` → prints the status table

- [ ] **Step 1: Write `common.sh`**

```bash
#!/usr/bin/env bash
# common.sh — shared config + helpers for the agent fleet.
# SOURCE this file; do not execute it. It deliberately does NOT set
# `set -euo pipefail` so it can't alter a caller's shell options.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS=(1 2 3 4 5)
LABEL_PREFIX="com.brianlow.claude-agent"
IMAGE="claude-code:latest"
LOG_DIR="${HOME}/.claude-agent/logs"
PLIST_DIR="${REPO_DIR}/launchd"
GUI_DOMAIN="gui/$(id -u)"
VAULT="${HOME}/Library/Mobile Documents/iCloud~md~obsidian/Documents/Brian's Vault"
BEAR_DIR="${HOME}/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data"

# launchd jobs inherit a minimal PATH; make binaries resolvable everywhere.
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

label_for() { printf '%s.%s' "${LABEL_PREFIX}" "$1"; }
plist_for() { printf '%s/%s.plist' "${PLIST_DIR}" "$(label_for "$1")"; }

is_loaded() { launchctl print "${GUI_DOMAIN}/$(label_for "$1")" &>/dev/null; }

container_state() {
  local state
  state="$(container list --all --format json 2>/dev/null \
    | jq -r --arg id "agent-$1" '.[] | select(.configuration.id==$id) | .status' 2>/dev/null)"
  printf '%s' "${state:-absent}"
}

render_plist() {
  local n="$1" label log
  label="$(label_for "$n")"
  log="${LOG_DIR}/agent-${n}.log"
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${REPO_DIR}/agent-run.sh</string>
        <string>${n}</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>30</integer>
    <key>WorkingDirectory</key><string>${REPO_DIR}</string>
    <key>StandardOutPath</key><string>${log}</string>
    <key>StandardErrorPath</key><string>${log}</string>
</dict>
</plist>
PLIST
}

print_status() {
  printf '%-9s %-12s %s\n' "AGENT" "LAUNCHD" "CONTAINER"
  local n l
  for n in "${AGENTS[@]}"; do
    if is_loaded "$n"; then l="loaded"; else l="not loaded"; fi
    printf '%-9s %-12s %s\n' "agent-${n}" "$l" "$(container_state "$n")"
  done
}
```

- [ ] **Step 2: Write the assertion harness `test/test-common.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source ./common.sh

fail=0
check() { # check <desc> <actual> <expected>
  if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 — got '$2' want '$3'"; fail=1; fi
}

check "label_for"   "$(label_for 3)"   "com.brianlow.claude-agent.3"
check "plist_for"   "$(plist_for 3)"   "${REPO_DIR}/launchd/com.brianlow.claude-agent.3.plist"
check "agents len"  "${#AGENTS[@]}"    "5"

# render_plist must contain the label, the agent arg, and an absolute program path.
plist="$(render_plist 2)"
grep -q "<string>com.brianlow.claude-agent.2</string>" <<<"$plist" && echo "PASS: plist label" || { echo "FAIL: plist label"; fail=1; }
grep -q "<string>${REPO_DIR}/agent-run.sh</string>"    <<<"$plist" && echo "PASS: plist prog"  || { echo "FAIL: plist prog"; fail=1; }

# container_state returns one of the known tokens for agent-1 (live system).
st="$(container_state 1)"
[[ "$st" =~ ^(running|stopped|absent)$ ]] && echo "PASS: container_state token ($st)" || { echo "FAIL: container_state '$st'"; fail=1; }

exit $fail
```

- [ ] **Step 3: Syntax-check both files**

Run: `bash -n common.sh && bash -n test/test-common.sh`
Expected: no output, exit 0.

- [ ] **Step 4: Run the harness**

Run: `chmod +x test/test-common.sh && ./test/test-common.sh; echo "exit=$?"`
Expected: all lines `PASS: ...` and `exit=0`. (`container_state 1` prints `running` given the live agents.)

- [ ] **Step 5: Commit**

```bash
git add common.sh test/test-common.sh
git commit -m "feat: common.sh shared config, plist template, status helpers

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `agent-run.sh` — per-agent wrapper (launchd target)

**Files:**
- Create: `agent-run.sh`

**Interfaces:**
- Consumes: `common.sh` (`IMAGE`, `VAULT`, `BEAR_DIR`, `PATH`).
- Produces: an executable invoked as `agent-run.sh <N>` that runs `agent-N` in the foreground; on exit launchd restarts it.

- [ ] **Step 1: Write `agent-run.sh`**

```bash
#!/usr/bin/env bash
# agent-run.sh <N> — run one agent (agent-N) in the foreground. Executed by
# launchd (KeepAlive), so any exit triggers a restart. Clears any stale
# container first so a reboot never wedges the slot.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

N="${1:?usage: agent-run.sh <N>}"
NAME="agent-${N}"

# Container system may still be coming up (e.g. just after login). Ensure it.
container system status &>/dev/null || container system start

# Clean slot: drop any stale/stopped/running container with this name.
container rm -f "${NAME}" &>/dev/null || true

# Host-side prep (mirrors the original run-claude.sh).
mkdir -p "${HOME}/.gcalcli"
cp "${HOME}/Library/Application Support/gcalcli/oauth" "${HOME}/.gcalcli/oauth" 2>/dev/null || true
[ -f "${HOME}/.claude.json" ] && cp "${HOME}/.claude.json" "${HOME}/.claude/.claude.json"

# Foreground (no -d) so launchd tracks the process lifetime. --tty gives the
# claude TUI a pty; no --interactive because no stdin is attached under launchd.
# caffeinate -dims prevents display/idle/system/disk sleep while running.
exec caffeinate -dims container run \
  --name "${NAME}" \
  --tty \
  --rm \
  --env COLORTERM=truecolor \
  --env "AGENT_SESSION_NAME=${NAME}" \
  --mount "source=${VAULT},target=/vault" \
  --mount "source=${HOME}/.claude,target=/home/user/.claude" \
  --mount "source=${HOME}/.gcalcli,target=/home/user/.local/share/gcalcli" \
  --mount "source=${BEAR_DIR},target=/bear,readonly" \
  --workdir /vault \
  "${IMAGE}"
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n agent-run.sh && chmod +x agent-run.sh`
Expected: exit 0.

- [ ] **Step 3: Functional check — run one agent by hand for ~40s**

This verifies the `--tty`/no-`--interactive`/remote-control combo actually runs
under a non-terminal-ish invocation (input redirected from /dev/null, as under launchd).

Run:
```bash
./remove-agents.sh 2>/dev/null || true   # clear old agents if the old script exists
( ./agent-run.sh 1 </dev/null >/tmp/agent1.log 2>&1 & echo $! >/tmp/agent1.pid )
sleep 40
container list --all --format json | jq -r '.[] | select(.configuration.id=="agent-1") | .status'
```
Expected: prints `running`. If it prints nothing/`stopped`, inspect `/tmp/agent1.log` — this is the TTY-under-launchd risk from the spec; if the TUI needs a real pty, wrap the `container run` in `script -q /dev/null …` and re-test.

- [ ] **Step 4: Verify remote control is reachable**

Open the Claude desktop app and confirm session `agent-1` appears and responds.
(Manual check — no command. This confirms the detached agent is usable as designed.)

- [ ] **Step 5: Tear down the hand-run agent**

Run: `kill "$(cat /tmp/agent1.pid)" 2>/dev/null || true; container rm -f agent-1 &>/dev/null || true; container_state() { :; }`
Then: `container list --all --format json | jq -r '.[].configuration.id'`
Expected: `agent-1` absent.

- [ ] **Step 6: Commit**

```bash
git add agent-run.sh
git commit -m "feat: agent-run.sh per-agent launchd wrapper

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `start-agents.sh` — the one command (idempotent) + `.gitignore`

**Files:**
- Create: `start-agents.sh`
- Create: `.gitignore`

**Interfaces:**
- Consumes: `common.sh` (`AGENTS`, `PLIST_DIR`, `LOG_DIR`, `GUI_DOMAIN`, `IMAGE`, `render_plist`, `plist_for`, `is_loaded`, `print_status`).
- Produces: `start-agents.sh [--build]` — generates plists, bootstraps only missing jobs, prints status.

- [ ] **Step 1: Write `.gitignore`**

```
# Generated launchd plists (regenerated by start-agents.sh)
launchd/
```

- [ ] **Step 2: Write `start-agents.sh`**

```bash
#!/usr/bin/env bash
# start-agents.sh [--build] — bring up all 5 agents under launchd. Idempotent:
# already-loaded agents are left running; only missing ones are bootstrapped.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

BUILD=false
[[ "${1:-}" == "--build" ]] && BUILD=true

# Ensure the container system is running.
container system status &>/dev/null || { echo "Starting container system..."; container system start; }

# Build the image if requested or missing.
if $BUILD || ! container image list 2>/dev/null | grep -q "^claude-code"; then
  echo "Building image ${IMAGE}..."
  container build --tag "${IMAGE}" --file "${SCRIPT_DIR}/Dockerfile" "${SCRIPT_DIR}"
fi

mkdir -p "${PLIST_DIR}" "${LOG_DIR}"

for n in "${AGENTS[@]}"; do
  render_plist "$n" > "$(plist_for "$n")"
  if is_loaded "$n"; then
    echo "agent-${n}: already loaded — leaving running."
  else
    echo "agent-${n}: bootstrapping..."
    launchctl bootstrap "${GUI_DOMAIN}" "$(plist_for "$n")"
  fi
done

echo
print_status
```

- [ ] **Step 3: Syntax-check**

Run: `bash -n start-agents.sh && chmod +x start-agents.sh`
Expected: exit 0.

- [ ] **Step 4: First run — brings all 5 up**

First clear any leftover old-mechanism agents so the new ones own the slots:
```bash
./remove-agents.sh 2>/dev/null || true
./start-agents.sh
```
Expected: five `bootstrapping...` lines, then a status table. Wait ~30s, then:
Run: `./agents-status.sh 2>/dev/null || source ./common.sh; print_status`
Expected (after Task 5 creates `agents-status.sh`; for now use `print_status`): all rows `loaded` / `running`.

- [ ] **Step 5: Idempotency check — second run is a safe no-op**

Run: `./start-agents.sh`
Expected: five `already loaded — leaving running.` lines, no errors, status table still all `loaded`/`running`. No duplicate jobs, no restarted containers.

- [ ] **Step 6: Commit**

```bash
git add start-agents.sh .gitignore
git commit -m "feat: start-agents.sh idempotent fleet launcher

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `stop-agents.sh` — tear down + status

**Files:**
- Create: `stop-agents.sh`

**Interfaces:**
- Consumes: `common.sh` (`AGENTS`, `GUI_DOMAIN`, `label_for`, `is_loaded`, `print_status`).
- Produces: `stop-agents.sh` — boots out all jobs, removes containers, prints status. Idempotent.

- [ ] **Step 1: Write `stop-agents.sh`**

```bash
#!/usr/bin/env bash
# stop-agents.sh — tear down all 5 agents: bootout the launchd jobs (so
# KeepAlive stops restarting) and remove the containers. Idempotent.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

for n in "${AGENTS[@]}"; do
  if is_loaded "$n"; then
    echo "agent-${n}: booting out..."
    launchctl bootout "${GUI_DOMAIN}/$(label_for "$n")" || true
  else
    echo "agent-${n}: not loaded."
  fi
  container rm -f "agent-${n}" &>/dev/null || true
done

echo
print_status
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n stop-agents.sh && chmod +x stop-agents.sh`
Expected: exit 0.

- [ ] **Step 3: Functional check — tears everything down**

Run: `./stop-agents.sh`
Expected: `booting out...` lines, status table all `not loaded` / `absent`.

- [ ] **Step 4: Idempotency check — second stop is a no-op**

Run: `./stop-agents.sh`
Expected: all `not loaded.` lines, no errors, status all `not loaded`/`absent`.

- [ ] **Step 5: Commit**

```bash
git add stop-agents.sh
git commit -m "feat: stop-agents.sh fleet teardown

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: `agents-status.sh` + README

**Files:**
- Create: `agents-status.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: `common.sh` (`print_status`).
- Produces: `agents-status.sh` — standalone status table.

- [ ] **Step 1: Write `agents-status.sh`**

```bash
#!/usr/bin/env bash
# agents-status.sh — print the launchd + container status of all 5 agents.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
print_status
```

- [ ] **Step 2: Syntax-check + run**

Run: `bash -n agents-status.sh && chmod +x agents-status.sh && ./agents-status.sh`
Expected: a status table with 5 agent rows.

- [ ] **Step 3: Update `README.md`** — add a usage section

Add this section near the top of `README.md` (after the intro line):

```markdown
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
```

- [ ] **Step 4: Commit**

```bash
git add agents-status.sh README.md
git commit -m "feat: agents-status.sh + README fleet usage

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: End-to-end verification (fresh cycle, crash recovery, reboot sim)

**Files:** none (verification only).

**Interfaces:**
- Consumes: all of the above.
- Produces: confidence that start/stop/idempotency/crash-recovery/reboot all work.

- [ ] **Step 1: Clean slate**

Run: `./stop-agents.sh`
Expected: all `not loaded` / `absent`.

- [ ] **Step 2: Start and confirm all up**

Run: `./start-agents.sh && sleep 30 && ./agents-status.sh`
Expected: all 5 `loaded` / `running`.

- [ ] **Step 3: Crash-recovery test — kill one container, confirm launchd restarts it**

Run:
```bash
container rm -f agent-3     # simulate a crash
sleep 45                    # ThrottleInterval is 30s; give KeepAlive room
./agents-status.sh
```
Expected: `agent-3` is back to `loaded` / `running` (launchd restarted it; `agent-run.sh` cleared the slot and relaunched).

- [ ] **Step 4: Reboot-wedge simulation — stopped container must not block start**

Simulate the post-reboot state (job unloaded, a stale STOPPED container left behind), then confirm `start-agents` recovers with no manual removal:
```bash
launchctl bootout "gui/$(id -u)/com.brianlow.claude-agent.4" || true
# Leave a stale stopped container behind under the same name:
container run --name agent-4 --rm=false --detach "${IMAGE:-claude-code:latest}" sleep 5 2>/dev/null || true
sleep 8   # let it exit to STOPPED
container list --all --format json | jq -r '.[] | select(.configuration.id=="agent-4") | .status'   # expect: stopped
./start-agents.sh
sleep 30
./agents-status.sh
```
Expected: `agent-4` ends `loaded` / `running` — `agent-run.sh`'s `container rm -f` cleared the stale stopped container automatically.

> If `container run ... sleep` isn't a valid way to make a stale container with this image, instead just `launchctl bootout` agent-4, confirm a stopped `agent-4` is NOT present, and verify `start-agents` brings it up — the `rm -f` path is already exercised on every launch.

- [ ] **Step 5: Idempotent final start**

Run: `./start-agents.sh`
Expected: all `already loaded — leaving running.`, status all `loaded`/`running`.

- [ ] **Step 6: Leave the fleet running** (this is the desired end state) and record results.

No commit (verification only). If any step revealed a fix, that fix was committed under its own task.

---

## Self-Review

**Spec coverage:**
- One command / idempotent → Tasks 3 (start), 4 (stop); idempotency verified in 3.5, 4.4.
- Crash recovery surviving terminal/logout → launchd `KeepAlive` (Task 1 plist, Task 2 wrapper); verified Task 6.3.
- Reachable remotely via desktop app → Task 2.4 (remote-control check); fixed session names (Global Constraints).
- Status output → `print_status` (Task 1), on every command (Tasks 3–4), standalone (Task 5).
- No post-reboot wedge → `container rm -f` in `agent-run.sh` (Task 2); verified Task 6.4.
- No terminal access / detached → `agent-run.sh` no `--interactive`; verified Task 2.3.
- Manual, no login auto-start → plists in `./launchd/`, not `~/Library/LaunchAgents` (Global Constraints, Task 3).
- Crash-loop policy (30s forever) → `ThrottleInterval=30` (Task 1); documented Task 5.3.
- Keep `run-claude.sh` → noted in README (Task 5.3); not deleted.

**Placeholder scan:** No TBD/TODO; all steps carry real code/commands and expected output.

**Type/name consistency:** `label_for`, `plist_for`, `is_loaded`, `container_state`, `render_plist`, `print_status`, `GUI_DOMAIN`, `AGENTS`, `IMAGE`, `LOG_DIR`, `PLIST_DIR` are defined in Task 1 and used with identical names/signatures in Tasks 2–5. Label `com.brianlow.claude-agent.N` and container name `agent-N` are consistent throughout.

**Known risk carried from spec (verify during Task 2.3):** `claude` TUI under `--tty` without a controlling terminal. Fallback documented inline (wrap in `script -q /dev/null …`).

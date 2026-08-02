# Hermes Agent — basic setup plan

One Hermes container under Apple Container, reachable from Discord and Slack,
using the vault as its memory. Experiment, not a fixture — no fleet, no launchd,
no reset-watcher until it earns them.

**Status: live.** Both platforms connected in one gateway, images route to the
vision aux, and vault reads *and writes* work through the structured tools. The
setup that got it there is below; the non-obvious traps that cost the most time
are in **Gotchas (hard-won)**.

Cheap path to a second agent: DeepSeek V4 Flash on OpenRouter is $0.09/$0.18
per 1M tokens, 1M context, tool calling supported.

Details below were checked against the docs linked at the bottom — the first
draft of this plan was mostly invented CLI, so verify before adding more.

## Use the official image

`nousresearch/hermes-agent:latest`, published for arm64. Install tree at
`/opt/hermes` is read-only, all state lives in one mount at `/opt/data`, and s6
inside the container restarts the gateway if it crashes.

So no `Dockerfile.hermes` and no changes to `build.sh` — this repo's *run*
pattern gets reused, not its build pattern.

## Storage: the vault is the store

Hermes' "memory" is two markdown files — `MEMORY.md` (2,200 chars) and
`USER.md` (1,375 chars) — injected into the system prompt in full every
session. That's a prompt header, not a store, which is why the vault has to be
the real one.

### The map

Three zones. Only two of them have a host path.

**1. Local disk — `hermes/data/` (host) = `/opt/data` (container)**

Machine state. In this repo but **gitignored** — the whole experiment is one
directory rather than a dotfile spread across the laptop. The image sets
`HERMES_HOME=/opt/data`, so anything the docs describe as living in `~/.hermes`
lands here instead.

| Host                              | Container                      | What                            |
| --------------------------------- | ------------------------------ | ------------------------------- |
| `hermes/data/.env`                | `/opt/data/.env`               | secrets (chmod 600)             |
| `hermes/data/config.yaml`         | `/opt/data/config.yaml`        | the config from below           |
| `hermes/data/memories/MEMORY.md`  | `/opt/data/memories/MEMORY.md` | agent notes, 2,200 cap          |
| `hermes/data/memories/USER.md`    | `/opt/data/memories/USER.md`   | user profile, 1,375 cap         |
| `hermes/data/state.db`            | `/opt/data/state.db`           | SQLite sessions + FTS           |
| `hermes/data/SOUL.md`             | `/opt/data/SOUL.md`            | personality; `HERMES_HOME` only |
| `hermes/data/skills/`, `logs/`    | `/opt/data/…`                  | machinery                       |

Gitignored as `hermes/data/` — it holds a live SQLite file, secrets, and
caches, none of which are source. That live SQLite file is also why this zone
stays on local disk and out of iCloud. Nothing here is precious except `.env`
and `config.yaml`; deleting the directory and re-running `setup` rebuilds the
rest.

**2. iCloud — `${VAULT}` (host) = `/vault` (container)**

The store. `${VAULT}` is the same var `common.sh` already defines, so this is
literally the folder Obsidian opens, mounted at the same `/vault` path the
Claude fleet uses.

| Host                      | Container               | What                                |
| ------------------------- | ----------------------- | ----------------------------------- |
| `${VAULT}/.hermes.md`     | `/vault/.hermes.md`     | policy file — **new, you write it** |
| `${VAULT}/CLAUDE.md`      | `/vault/CLAUDE.md`      | already there, also auto-loaded     |
| `${VAULT}/Fleet Reset.md` | `/vault/Fleet Reset.md` | already there, the reset trigger    |
| `${VAULT}/<your notes>`   | `/vault/<your notes>`   | everything the agent knows          |

The auto-loaded context filenames are exactly `SOUL.md`, `.hermes.md`,
`AGENTS.md`, `CLAUDE.md`, `.cursorrules` — there is no `HERMES.md`, which an
earlier draft of this plan assumed. `.hermes.md` is the right slot anyway: it's
Hermes-only (the Claude fleet ignores it) and, being a dotfile, Obsidian hides
it so it never shows up as a note to curate. Note the vault's existing file is
`AGENT.md`, singular, so it is *not* auto-loaded — it just points at
`CLAUDE.md`, which is.

**3. Inside the image — `/opt/hermes`**

The install tree. No host path, read-only, nothing to manage.

Note `MEMORY.md` sits in zone 1 but its *content* points into zone 2 — one line
per thing, naming the vault note that holds it. Same convention as this repo's
own `MEMORY.md`. That's the whole trick: the capped file is an index, the vault
is the store.

Two things make the vault actually primary:

1. **`--workdir /vault`** — context-file discovery is rooted at the working
   directory, so a vault-root `.hermes.md` loads into every session.
2. **A vault-root `.hermes.md`** saying: record findings as notes here, use
   wikilinks, keep `MEMORY.md` to pointers. Without it the agent just fills
   `MEMORY.md` until it hits the cap. The vault's existing `CLAUDE.md` also gets
   auto-loaded, so don't let the two contradict each other — the written
   `.hermes.md` defers to `CLAUDE.md` outright and only adds the Hermes-specific
   parts (pointer-index discipline, hands off `Fleet Reset.md`).

## Setup

```sh
mkdir -p hermes/data && chmod 700 hermes/data

# one-time, needs a tty — the long-running container has none
container run -it --rm \
  --mount "source=$(pwd)/hermes/data,target=/opt/data" \
  nousresearch/hermes-agent setup
```

`hermes model` picks the provider/slug, `hermes gateway setup` walks through
Discord — or skip both and write the two files below by hand.

**`hermes/data/.env`** (read by the image off `/opt/data`; no `--env` plumbing):

```
OPENROUTER_API_KEY=sk-or-...
DISCORD_BOT_TOKEN=...
DISCORD_ALLOWED_USERS=<your-discord-user-id>
OBSIDIAN_VAULT_PATH=/vault
HERMES_WRITE_SAFE_ROOT=          # empty = disabled; REQUIRED for vault writes (see Gotchas)
```

`DISCORD_ALLOWED_USERS` is required — the gateway denies everyone by default.
`OBSIDIAN_VAULT_PATH` otherwise defaults to a path that doesn't exist in the
container. `HERMES_WRITE_SAFE_ROOT` must be present and **empty** — the image
defaults it to `/opt/data`, which blocks every write under `/vault`; do not
"fix" that with `/` (see Gotchas for why that's the worst value).

**`hermes/data/config.yaml`** — note `model:` is a mapping, not a slug string.
Hermes **rewrites this file on first start**: it migrates the schema, stamps the
current `_config_version` (33 as of this writing — ignore the warning text that
says to hand-set 12), backs the old one up as `config.yaml.bak-<ts>`, and drops
any hand-written comments. So write it for correctness, not for posterity; your
settings survive, your prose doesn't. `.env` is left alone.

```yaml
model:
  default: "deepseek/deepseek-v4-flash"
  provider: "openrouter"

auxiliary:
  vision:
    provider: "openrouter"
    model: "google/gemini-2.5-flash"    # V4 Flash is text-only

memory:
  memory_enabled: true

discord:
  require_mention: false   # dedicated server; still gated by DISCORD_ALLOWED_USERS
  auto_thread: true

slack:
  require_mention: false   # dedicated workspace; still gated by SLACK_ALLOWED_USERS
```

`home_channel` / `platforms:` blocks appear *after* you run `/sethome` in a
channel — Hermes stamps those itself. Don't hand-write them, and don't expect
the agent to: it can't edit its own `config.yaml` (see Gotchas).

**Discord app:** enable the **Message Content Intent** under Privileged Gateway
Intents — without it the bot receives message events with empty text, and fails
silently. Also enable **Server Members Intent** (resolving usernames);
**Presence Intent** is optional. Scopes `bot` + `applications.commands`;
permissions View Channels, Send Messages, Embed Links, Attach Files, Read
Message History (permissions integer `117760` minimal / `274878286912`
recommended).

**Slack (optional second platform — runs alongside Discord in one gateway,
confirmed "2 platform(s)").** Socket Mode, so a WebSocket with nothing to
expose, same as Discord. It needs two tokens plus your member ID in `.env`:

```
SLACK_BOT_TOKEN=xoxb-...     # OAuth & Permissions → Install to Workspace
SLACK_APP_TOKEN=xapp-...     # generated by enabling Socket Mode (connections:write)
SLACK_ALLOWED_USERS=U...     # your member ID; gateway denies everyone if unset
```

Create the app **from `hermes/slack-app-manifest.yaml`** (api.slack.com/apps →
Create New App → From a manifest) — one paste sets all 13 bot scopes, the event
subscriptions, and the Socket Mode toggle. Then the manual bits a manifest
can't do: generate the app-level token (Basic Information → App-Level Tokens,
`connections:write`), Install to Workspace for the bot token, copy your member
ID (profile → ⋮ → Copy member ID), and `/invite` the bot to the channel. No
signing secret — Socket Mode doesn't use one. **Images need the `files:read`
scope** or `vision_analyze` can't fetch the attachment; a scope added in the
portal needs a fresh Install to take effect, so verify the *runtime* scopes with
Slack's `api.test` / `files.list` rather than trusting the portal UI.

**Put a spend limit on the OpenRouter key.** Cost is the whole point of the
experiment; use a dedicated key rather than one backed by the account balance.

## Run

```sh
./hermes/hermes-run.sh     # start (idempotent — force-removes a stale hermes-1 first)
./hermes/hermes-stop.sh    # tear down; state survives in hermes/data/
container logs -f hermes-1
```

`hermes-run.sh` sources `common.sh` for `${VAULT}` and wraps:

```sh
container run -d \
  --name hermes-1 \
  --env PYTHONPATH=/opt/data/lazy-packages \
  --env AGENT_BROWSER_EXECUTABLE_PATH=/opt/data/.local/bin/chromium-shim \
  --mount "source=${SCRIPT_DIR}/data,target=/opt/data" \
  --mount "source=${VAULT},target=/vault" \
  --workdir /vault \
  nousresearch/hermes-agent:latest gateway run
```

It also writes two shims into `data/.local/bin/` first (idempotent, so deleting
`hermes/data/` rebuilds them): `uv`, which makes tool installs permanent, and
`chromium-shim`, which lets agent-browser find the browser. Both are explained
in Gotchas — neither is optional, and the failure each prevents is silent.

- `gateway run` is the image's command (bare-metal CLI spells it `hermes gateway`).
- Pull with `container image pull` — Apple Container has no `container images`
  subcommand; the plural form errors with a confusing missing-plugin message.
- No `--tty` (headless daemon), no `--rm` (keep it inspectable after a crash);
  `container rm -f hermes-1` before restarting, like `agent-run.sh` does.
- Discord is an outbound WebSocket — no ports need publishing.
- Doesn't survive reboot. If that gets annoying, it's a ~10-line launchd plist
  cloned from `render_plist()` in `common.sh` — keep it out of `AGENTS` so
  `reset-agents.sh`/`stop-agents.sh` never touch Hermes.

## Worth knowing

`${VAULT}/Fleet Reset.md` recycles the Claude fleet on any mtime change, and
Hermes can see it. Worst case is a 30-second self-healing recycle; one
hands-off line in `.hermes.md` is enough.

`terminal.backend` defaults to `local`, so Hermes runs shell commands inside
its own container. That's the sandbox. `hermes tools` gates which of the 60+
built-in tools are on.

## Gotchas (hard-won)

Every one of these cost real time; none is in the docs.

**Vault writes need `HERMES_WRITE_SAFE_ROOT` empty.** The image defaults it to
`/opt/data`, so the `patch`/`write_file` tools refuse anything under `/vault` —
the whole point of this setup. It's a naive path-*prefix* check, so `/` is a
trap, not a fix: it becomes a `//` prefix that matches *nothing* and denies
`/vault/…` as "outside /". Setting it **empty** disables the guard, and `patch`
then writes both `/opt/data` and `/vault`. The container VM plus the two mounts
are the real boundary, so a disabled guard is fine here. The failure is *silent
and misleading*: when `patch` is denied the model falls back to a raw `terminal`
`echo >>`, which bypasses the guard, succeeds, and is invisible to the verifier
below — so the file changes while a "not modified" warning fires. Verified the
fix by watching a fresh-thread `patch` return `{"success": true}` with no shell
fallback.

**The file-mutation verifier — keep it on, know its blind spot.** Hermes runs a
deterministic post-turn check that compares what the `patch`/`write_file` tools
*actually* did against the model's prose and staples a `⚠️ File-mutation
verifier: N file(s) were NOT modified …` note onto the reply when they diverge.
It quotes the real tool error verbatim, so it is ground truth — and it is
load-bearing, because V4 Flash *will* say "Done ✅" for writes that were denied
(caught three times: a vault write, a config edit, a sethome). But it only
watches the structured file tools: a `terminal` shell write is invisible to it.
Rule of thumb — a `patch` it flags really failed; its silence about a `terminal`
write proves nothing.

**The agent can't edit its own `config.yaml`.** A hardcoded guardrail refuses
any `patch` to `/opt/data/config.yaml` ("Agent cannot modify security-sensitive
configuration") — deliberate, since that file holds the model, provider, secret
redaction, and allowed-users. Sanctioned changes still work through their own
paths (`/sethome` writes the `home_channel` block itself); only the agent
hand-editing the file is blocked. To change config, edit `hermes/data/config.yaml`
on the host and restart.

**A rename needs a container restart.** Renaming the bot in the Discord/Slack
portal does not re-identify a live gateway — the running WebSocket keeps
presenting the old name until the process reconnects (`hermes-stop.sh &&
hermes-run.sh`; state survives). Also note the portal's *application* name and
the *bot username* are different fields — changing the first doesn't rename the
bot. If the portal edit won't stick, `PATCH https://discord.com/api/v10/users/@me`
with the bot token renames it directly.

**`Fleet Reset.md` does NOT restart Hermes — and naively wiring it in would kill
it.** The trigger runs `reset-agents.sh`, which only removes `agent-1..5` (the
`AGENTS` list in `common.sh`); `hermes-1` is deliberately absent. And the whole
recovery model relies on launchd `KeepAlive` relaunching what's removed — Hermes
has no plist, so removing it would stop it for good, not recycle it. Restart
Hermes with `hermes-run.sh`.

**`.env` / `config.yaml` are read only at container start.** Every change above
needs `hermes-stop.sh && hermes-run.sh` to take effect — editing the file alone
does nothing to the running gateway.

**The browser toolset advertises itself but can never launch — and the error you
see is a lie.** Every `browser_*` call died on a 30–60s timeout ("the browser
daemon may still be starting, or Chromium may be missing system libraries").
All three implied causes are wrong. The image bakes in 344MB of working Chromium
(`Chromium 151`, no missing libs, runs fine). The real error only appears if you
run the CLI by hand — `agent-browser open https://example.com` → *"Chrome not
found"*. It's a path-layout mismatch:

```
agent-browser searches for   chromium-<rev>/chrome-linux64/chrome
the image ships              chromium_headless_shell-<rev>/chrome-linux/headless_shell
```

agent-browser *does* read `PLAYWRIGHT_BROWSERS_PATH`, but only recognises the
full-Chrome layout. What makes it genuinely confusing is that
`tools/browser_tool.py::_chromium_installed()` accepts **either** name, so the
capability check returns True and Hermes keeps advertising a toolset that cannot
work — the model then retries forever against a daemon that never started. Fixed
with `AGENT_BROWSER_EXECUTABLE_PATH`, which agent-browser and `_chromium_installed`
both read, so it repairs the launch *and* makes the check honest. It points at
`chromium-shim` rather than the binary because the `-1234` revision changes on
image updates; a hardcoded path would silently re-break on the next
`container image pull`. Headless-shell speaks CDP and drives agent-browser fine.

**`hermes tools post-setup <key>` installs do NOT survive a restart.** The
container is disposable (`container rm -f` on every start) and only `/opt/data`
is a mount, so anything written into `/opt/hermes` is thrown away. Hermes has a
durable target — `HERMES_LAZY_INSTALL_TARGET=/opt/data/lazy-packages`, appended
to `sys.path` by `hermes_bootstrap.py` — but **only lazy runtime imports land
there**. The explicit post-setup hooks call `_pip_install`, which shells out to
`uv pip install` and writes into `/opt/hermes/.venv`. There's no env-var
redirect: uv 0.11.6 has no `UV_TARGET`, and `_pip_install` pins `VIRTUAL_ENV`
from `sys.executable`. The seam is `PATH` — the image puts `/opt/data/.local/bin`
*ahead* of `/usr/local/bin`, and `_pip_install` resolves uv via `shutil.which()`,
so a shim there wins. `hermes-run.sh` writes it on every start.

Two halves are needed, and skipping the second is a silent trap: the package
installs correctly and then fails at runtime with `ModuleNotFoundError`, because
some tools do their work in a **subprocess** — `plugins/web/ddgs/provider.py`
builds the child's env from the inherited `PYTHONPATH` only, so the parent's
in-process `sys.path` never reaches it. Hence `--env PYTHONPATH=/opt/data/lazy-packages`.
Caveat: `--target` can't see the venv's packages, so deps get re-downloaded
(~34MB for ddgs). That's inert weight, not a shadowing risk — the target is
*appended* to `sys.path`, so the venv's copies still win at import.

npm-based hooks (`agent_browser`, `camofox`) still write to
`/opt/hermes/node_modules` and remain ephemeral. Moot for agent-browser, which
is baked into the image along with Chromium.

## Check it works

- [x] `hermes doctor` clean — run it without the vault mount to skip the TCC
      prompt: `container run --rm --mount "source=$(pwd)/hermes/data,target=/opt/data"
      nousresearch/hermes-agent:latest doctor`. Exit 0; the only issues are a
      `~/.local/bin/hermes` symlink and optional API keys (`EXA_API_KEY`,
      `XAI_API_KEY`, …) for tools we're not using. Note its "✓ OpenRouter API"
      passed while the key was still `REPLACE_ME`, so that check does not prove
      the key is valid — the Discord round-trip below is the real test.
- [x] Bot answers messages on both Discord and Slack (with `require_mention:
      false` on both, no @ needed). Deny-by-allowlist is wired (`*_ALLOWED_USERS`)
      but not yet exercised with a second account.
- [x] Image routes to the vision aux — `vision_analyze` → Gemini returned a
      description of a photo. Only after adding the Slack `files:read` scope;
      without it the attachment fetch fails.
- [x] Vault *writes* work through `patch` (blocked until `HERMES_WRITE_SAFE_ROOT`
      was emptied — see Gotchas).
- [x] **A durable fact lands as a topic note, not in `MEMORY.md`** — the test
      that proves the vault is primary. Told it one fact about a shrub; it wrote
      `garden/plants/Potentilla.md` (care, hardiness, a flowering-log table) and
      updated the `garden/Garden.md` hub in three places with wikilinks.
      `MEMORY.md` stayed at 147 chars. The pointer-index discipline in
      `.hermes.md` works as written — no need to make it more explicit.
      Two blemishes: it invents `![[photo.jpg]]` embeds for images that don't
      exist, and links `[[potentilla]]` lowercase against a `Potentilla.md` file
      (fine on case-insensitive macOS, would break elsewhere).
- [x] `web_search` works with no API key — `hermes tools post-setup ddgs` plus
      the two Gotchas below. This is the built-in alternative to the browser
      toolset: plain HTTP, 34MB, no Chromium.
- [ ] Read a note just created on the phone — catches iCloud placeholders that
      the container can't fault in
- [x] Restart the container, sessions survive — auto-resumed across several
      restarts this session (incl. an interrupted turn).
- [ ] Check OpenRouter spend after a day against the estimate

## Not doing yet

- The dashboard and API server (`HERMES_DASHBOARD`, `API_SERVER_ENABLED`) —
  Slack is now done (see Setup)
- `terminal.backend docker` — the outer container is already the boundary
- Community Obsidian-memory skills (`obsidian-hermes-memory`,
  `open-second-brain`). Same goal, but the native path above should get there
  with nothing extra to maintain

## Open questions

- ~~Which vault folders Hermes should author into~~ — **decided: the whole
  vault, same terms as the Claude fleet.** No `hermes/` sandbox folder; it files
  by topic and keeps the `CLAUDE.md` index current. Blast radius is the reason
  to watch the first few notes it writes.
- ~~Does `auxiliary.vision` actually take over for a text-only primary?~~ —
  **yes.** `vision_analyze` routed an image through the Gemini aux and returned
  a description. (Requires the Slack `files:read` scope so the image can be
  fetched first.)
- The $0.0896/$0.1792 per 1M quoted on OpenRouter is a 36%-off promo on V4
  Flash, not the standing rate. Re-check before treating the cost estimate as
  durable.
- Whether a 2,200-char pointer index is enough, or it needs a hub note in the
  vault that `MEMORY.md` points at

## Sources

- [Quickstart](https://hermes-agent.nousresearch.com/docs/getting-started/quickstart)
- [Docker](https://hermes-agent.nousresearch.com/docs/user-guide/docker)
- [Configuration](https://hermes-agent.nousresearch.com/docs/user-guide/configuration)
- [Discord](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/discord)
- [Slack](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/slack)
- [Obsidian skill](https://hermes-agent.nousresearch.com/docs/user-guide/skills/bundled/note-taking/note-taking-obsidian)
- [DeepSeek V4 Flash on OpenRouter](https://openrouter.ai/deepseek/deepseek-v4-flash)

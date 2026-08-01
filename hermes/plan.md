# Hermes Agent — basic setup plan

One Hermes container under Apple Container, reachable from Discord, using the
vault as its memory. Experiment, not a fixture — no fleet, no launchd, no
reset-watcher until it earns them.

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
```

`DISCORD_ALLOWED_USERS` is required — the gateway denies everyone by default.
`OBSIDIAN_VAULT_PATH` otherwise defaults to a path that doesn't exist in the
container.

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
  require_mention: true
  auto_thread: true
```

**Discord app:** enable the **Message Content Intent** under Privileged Gateway
Intents — without it the bot receives message events with empty text, and fails
silently. Also enable **Server Members Intent** (resolving usernames);
**Presence Intent** is optional. Scopes `bot` + `applications.commands`;
permissions View Channels, Send Messages, Embed Links, Attach Files, Read
Message History (permissions integer `117760` minimal / `274878286912`
recommended).

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
  --mount "source=${SCRIPT_DIR}/data,target=/opt/data" \
  --mount "source=${VAULT},target=/vault" \
  --workdir /vault \
  nousresearch/hermes-agent:latest gateway run
```

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
hands-off line in `HERMES.md` is enough.

`terminal.backend` defaults to `local`, so Hermes runs shell commands inside
its own container. That's the sandbox. `hermes tools` gates which of the 60+
built-in tools are on.

## Check it works

- [x] `hermes doctor` clean — run it without the vault mount to skip the TCC
      prompt: `container run --rm --mount "source=$(pwd)/hermes/data,target=/opt/data"
      nousresearch/hermes-agent:latest doctor`. Exit 0; the only issues are a
      `~/.local/bin/hermes` symlink and optional API keys (`EXA_API_KEY`,
      `XAI_API_KEY`, …) for tools we're not using. Note its "✓ OpenRouter API"
      passed while the key was still `REPLACE_ME`, so that check does not prove
      the key is valid — the Discord round-trip below is the real test.
- [ ] Bot answers an @mention from you, ignores a different account
- [ ] Send an image — confirm it routes to the vision aux, doesn't fail silently
- [ ] Tell it a durable fact → lands as a vault note, not buried in `MEMORY.md`.
      This is the test that proves the vault is primary; if it fails, make
      `HERMES.md` more explicit
- [ ] Read a note just created on the phone — catches iCloud placeholders that
      the container can't fault in
- [ ] Restart the container, sessions survive
- [ ] Check OpenRouter spend after a day against the estimate

## Not doing yet

- Slack; the dashboard and API server (`HERMES_DASHBOARD`, `API_SERVER_ENABLED`)
- `terminal.backend docker` — the outer container is already the boundary
- Community Obsidian-memory skills (`obsidian-hermes-memory`,
  `open-second-brain`). Same goal, but the native path above should get there
  with nothing extra to maintain

## Open questions

- ~~Which vault folders Hermes should author into~~ — **decided: the whole
  vault, same terms as the Claude fleet.** No `hermes/` sandbox folder; it files
  by topic and keeps the `CLAUDE.md` index current. Blast radius is the reason
  to watch the first few notes it writes.
- Does `auxiliary.vision` actually take over for a text-only primary? (An
  earlier draft claimed a known upstream bug; that was unsourced. Just test it.)
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
- [Obsidian skill](https://hermes-agent.nousresearch.com/docs/user-guide/skills/bundled/note-taking/note-taking-obsidian)
- [DeepSeek V4 Flash on OpenRouter](https://openrouter.ai/deepseek/deepseek-v4-flash)

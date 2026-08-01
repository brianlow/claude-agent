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

**1. Local disk — `~/.hermes` (host) = `/opt/data` (container)**

Machine state. Not in iCloud, not in the vault, not in this repo. The image
sets `HERMES_HOME=/opt/data`, so anything the docs describe as living in
`~/.hermes` lands here.

| Host                           | Container                      | What                            |
| ------------------------------ | ------------------------------ | ------------------------------- |
| `~/.hermes/.env`               | `/opt/data/.env`               | secrets (chmod 600)             |
| `~/.hermes/config.yaml`        | `/opt/data/config.yaml`        | the config from below           |
| `~/.hermes/memories/MEMORY.md` | `/opt/data/memories/MEMORY.md` | agent notes, 2,200 cap          |
| `~/.hermes/memories/USER.md`   | `/opt/data/memories/USER.md`   | user profile, 1,375 cap         |
| `~/.hermes/state.db`           | `/opt/data/state.db`           | SQLite sessions + FTS           |
| `~/.hermes/SOUL.md`            | `/opt/data/SOUL.md`            | personality; `HERMES_HOME` only |
| `~/.hermes/skills/`, `logs/`   | `/opt/data/…`                  | machinery                       |

A live SQLite file is why this stays off iCloud.

**2. iCloud — `${VAULT}` (host) = `/vault` (container)**

The store. `${VAULT}` is the same var `common.sh` already defines, so this is
literally the folder Obsidian opens, mounted at the same `/vault` path the
Claude fleet uses.

| Host                      | Container               | What                                |
| ------------------------- | ----------------------- | ----------------------------------- |
| `${VAULT}/HERMES.md`      | `/vault/HERMES.md`      | policy file — **new, you write it** |
| `${VAULT}/CLAUDE.md`      | `/vault/CLAUDE.md`      | already there, also auto-loaded     |
| `${VAULT}/Fleet Reset.md` | `/vault/Fleet Reset.md` | already there, the reset trigger    |
| `${VAULT}/<your notes>`   | `/vault/<your notes>`   | everything the agent knows          |

**3. Inside the image — `/opt/hermes`**

The install tree. No host path, read-only, nothing to manage.

Note `MEMORY.md` sits in zone 1 but its *content* points into zone 2 — one line
per thing, naming the vault note that holds it. Same convention as this repo's
own `MEMORY.md`. That's the whole trick: the capped file is an index, the vault
is the store.

Two things make the vault actually primary:

1. **`--workdir /vault`** — context-file discovery is rooted at the working
   directory, so a vault-root `HERMES.md` loads into every session.
2. **A vault-root `HERMES.md`** saying: record findings as notes here, use
   wikilinks, keep `MEMORY.md` to pointers. Without it the agent just fills
   `MEMORY.md` until it hits the cap. The vault's existing `CLAUDE.md` also gets
   auto-loaded, so don't let the two contradict each other.

## Setup

```sh
mkdir -p ~/.hermes && chmod 700 ~/.hermes

# one-time, needs a tty — the long-running container has none
container run -it --rm \
  --mount "source=${HOME}/.hermes,target=/opt/data" \
  nousresearch/hermes-agent setup
```

`hermes model` picks the provider/slug, `hermes gateway setup` walks through
Discord — or skip both and write the two files below by hand.

**`~/.hermes/.env`** (read by the image off `/opt/data`; no `--env` plumbing):

```
OPENROUTER_API_KEY=sk-or-...
DISCORD_BOT_TOKEN=...
DISCORD_ALLOWED_USERS=<your-discord-user-id>
OBSIDIAN_VAULT_PATH=/vault
```

`DISCORD_ALLOWED_USERS` is required — the gateway denies everyone by default.
`OBSIDIAN_VAULT_PATH` otherwise defaults to a path that doesn't exist in the
container.

**`~/.hermes/config.yaml`** — note `model:` is a mapping, not a slug string:

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
Intents — without it the bot can't read messages at all and fails silently.
Scopes `bot` + `applications.commands`; permissions View Channel, Send Messages,
Send Messages in Threads, Read Message History, Add Reactions.

**Put a spend limit on the OpenRouter key.** Cost is the whole point of the
experiment; use a dedicated key rather than one backed by the account balance.

## Run

```sh
container run -d \
  --name hermes-1 \
  --mount "source=${HOME}/.hermes,target=/opt/data" \
  --mount "source=${VAULT},target=/vault" \
  --workdir /vault \
  nousresearch/hermes-agent gateway run
```

- `gateway run` is the image's command (bare-metal CLI spells it `hermes gateway`).
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

- [ ] `hermes doctor` clean
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

- Which vault folders Hermes should author into — needed to write `HERMES.md`
- Does `auxiliary.vision` actually take over for a text-only primary? (An
  earlier draft claimed a known upstream bug; that was unsourced. Just test it.)
- Whether a 2,200-char pointer index is enough, or it needs a hub note in the
  vault that `MEMORY.md` points at

## Sources

- [Quickstart](https://hermes-agent.nousresearch.com/docs/getting-started/quickstart)
- [Docker](https://hermes-agent.nousresearch.com/docs/user-guide/docker)
- [Configuration](https://hermes-agent.nousresearch.com/docs/user-guide/configuration)
- [Discord](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/discord)
- [Obsidian skill](https://hermes-agent.nousresearch.com/docs/user-guide/skills/bundled/note-taking/note-taking-obsidian)
- [DeepSeek V4 Flash on OpenRouter](https://openrouter.ai/deepseek/deepseek-v4-flash)

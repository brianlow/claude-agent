# Hermes

One [Hermes](https://hermes-agent.nousresearch.com) agent (`hermes-1`) in an
Apple Container, reachable from Discord and Slack, using the Obsidian vault as
its memory. Deliberately **not** part of the Claude fleet: no launchd, no
KeepAlive, and `reset-agents.sh` / `stop-agents.sh` never touch it.

## Commands

```sh
./hermes/hermes-run.sh      # start (idempotent — force-removes a stale hermes-1 first)
./hermes/hermes-stop.sh     # tear down; state survives in hermes/data/
container logs -f hermes-1  # watch it
container exec -it hermes-1 hermes doctor      # health check
container exec -it hermes-1 hermes tools       # which of the 60+ tools are on
```

Then just message the bot on Discord (Herme's Server) or Slack (Hermy's Workspace).
No `@` needed (`require_mention: false`), but only user IDs in `*_ALLOWED_USERS` are answered.

Regular tasks:

| Task                  | How                                                                       |
| --------------------- | ------------------------------------------------------------------------- |
| Change model / config | edit `hermes/data/config.yaml`, then stop + run                           |
| Change a secret       | edit `hermes/data/.env`, then stop + run                                  |
| Rename the bot        | rename in the portal, then stop + run (a live gateway keeps the old name) |
| Update the image      | `container image pull nousresearch/hermes-agent:latest`, then stop + run  |
| Start over            | delete `hermes/data/` except `.env` + `config.yaml`, then run             |

Everything is read at container start, so **every change needs a restart.**
It does not survive a reboot either — rerun `hermes-run.sh`.

## Layout

Three zones, two with a host path.

- **`hermes/data/` → `/opt/data`** — machine state (gitignored). The image sets
  `HERMES_HOME=/opt/data`, so anything the docs put in `~/.hermes` lands here:
  `.env`, `config.yaml`, `SOUL.md`, `memories/`, `state.db`, `skills/`, `logs/`.
  Only `.env` and `config.yaml` are precious.
- **`${VAULT}` → `/vault`** — the store. Same Obsidian vault the Claude fleet
  mounts. `--workdir /vault` is what makes `/vault/.hermes.md` (policy, written
  by us) and the vault's own `CLAUDE.md` auto-load into every session.
- **`/opt/hermes`** — the install tree inside the image. Read-only, disposable.

Network: outbound only, and the home LAN is fenced off by the host pf anchor —
see [Isolation](../README.md#isolation). Hermes shares the container subnet with
the Claude fleet and `sbx-browser`, which stays reachable.

The memory design: `memories/MEMORY.md` is capped at 2,200 chars and injected
into every system prompt, so it's an **index, not a store** — one line per
thing, pointing at the vault note that holds it. `.hermes.md` tells the agent to
file findings as topic notes with wikilinks. Verified: told it one fact about a
shrub and it wrote `garden/plants/Potentilla.md` and updated the garden hub,
while `MEMORY.md` stayed at 147 chars.

Model is `deepseek/deepseek-v4-flash` on OpenRouter (cheap, 1M context, text
only), with `google/gemini-2.5-flash` as the vision auxiliary. Put a spend limit
on the OpenRouter key.

## First-time setup

```sh
mkdir -p hermes/data && chmod 700 hermes/data
container run -it --rm \
  --mount "source=$(pwd)/hermes/data,target=/opt/data" \
  nousresearch/hermes-agent setup
```

`hermes/data/.env` needs: `OPENROUTER_API_KEY`, `DISCORD_BOT_TOKEN`,
`DISCORD_ALLOWED_USERS`, `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`,
`SLACK_ALLOWED_USERS`, `OBSIDIAN_VAULT_PATH=/vault`, and
`HERMES_WRITE_SAFE_ROOT=` (present and **empty** — see Gotchas).

**Discord app:** enable the **Message Content Intent** (without it messages
arrive with empty text and fail silently) and Server Members Intent. Scopes
`bot` + `applications.commands`; permissions integer `274878286912`.

**Slack app:** create it from `slack-app-manifest.yaml` (api.slack.com/apps →
From a manifest) — one paste sets all 13 scopes, the events, and Socket Mode.
Then the parts a manifest can't do: generate the app-level token
(`connections:write`), Install to Workspace, copy your member ID, `/invite` the
bot. Both platforms run in one gateway over outbound WebSockets, so no ports.

## Gotchas

Each of these cost real time and none is in the docs.

**Vault writes need `HERMES_WRITE_SAFE_ROOT` empty.** It defaults to
`/opt/data`, so `patch`/`write_file` refuse everything under `/vault`. It's a
naive path-*prefix* check, so `/` is a trap, not a fix — it becomes a `//`
prefix matching nothing. Empty disables the guard; the container VM plus the two
mounts are the real boundary. The failure is silent and misleading: when `patch`
is denied the model falls back to a raw shell `echo >>`, which succeeds and
bypasses the verifier below, so the file changes while a "not modified" warning
fires.

**The file-mutation verifier is ground truth, with one blind spot.** A
deterministic post-turn check compares what the file tools actually did against
the model's prose and staples on `⚠️ File-mutation verifier: N file(s) were NOT
modified…`. It's load-bearing — V4 Flash will happily say "Done ✅" for writes
that were denied. But it only watches the structured file tools: a `terminal`
shell write is invisible to it. A `patch` it flags really failed; its silence
about a shell write proves nothing.

**The agent can't edit its own `config.yaml`.** A hardcoded guardrail refuses
it ("Agent cannot modify security-sensitive configuration") — deliberate, that
file holds the model, provider, and allowed-users. Sanctioned paths still work
(`/sethome` writes its own block). Edit on the host and restart.

**Hermes rewrites `config.yaml` on first start** — migrates the schema, stamps
`_config_version`, backs up the old one, and drops your comments. Write it for
correctness, not posterity. `.env` is left alone.

**`Fleet Reset.md` does not restart Hermes — and wiring it in would kill it.**
The trigger runs `reset-agents.sh`, which only removes `agent-1..5`; recovery
relies on launchd relaunching what it removed, and Hermes has no plist. Removing
it would stop it for good. `.hermes.md` tells the agent hands off that note.

**Two shims in `data/.local/bin/`, both written by `hermes-run.sh` on every
start.** Neither is optional and each prevents a silent failure:

- `uv` — makes `hermes tools post-setup <key>` installs permanent. The
  post-setup hooks `uv pip install` into `/opt/hermes/.venv`, which is thrown
  away with the container; the shim redirects into the persisted
  `HERMES_LAZY_INSTALL_TARGET=/opt/data/lazy-packages`. It wins because the
  image puts `/opt/data/.local/bin` ahead of `/usr/local/bin` on `PATH` and
  `_pip_install` resolves uv via `shutil.which()`. `--env
  PYTHONPATH=/opt/data/lazy-packages` is the required second half — some tools
  do their work in a subprocess that inherits only `PYTHONPATH`, so without it
  the package installs fine and then `ModuleNotFoundError`s at runtime.
- `chromium-shim` — lets `agent-browser` find the Chromium the image already
  bakes in. agent-browser looks for `chromium-<rev>/chrome-linux64/chrome`; the
  image ships `chromium_headless_shell-<rev>/chrome-linux/headless_shell`, so
  every `browser_*` call died on a 30–60s timeout whose error text blames three
  things that are all fine. Worse, `_chromium_installed()` accepts either
  layout, so Hermes advertised a toolset that could never launch.
  `AGENT_BROWSER_EXECUTABLE_PATH` fixes the launch and makes the check honest;
  it points at the shim because the revision changes on image updates.

npm-based hooks (`camofox`) still write to `/opt/hermes/node_modules` and stay
ephemeral. Moot for agent-browser, which is baked in.

## Still open

- Read a note just created on the phone — catches iCloud placeholders the
  container can't fault in.
- Check OpenRouter spend against the estimate. The quoted V4 Flash rate is a
  36%-off promo, not the standing price.
- Whether a 2,200-char pointer index is enough, or `MEMORY.md` should point at a
  hub note in the vault.
- Not doing yet: the dashboard / API server, `terminal.backend docker` (the
  outer container is already the boundary), community Obsidian-memory skills.

## Docs

[Quickstart](https://hermes-agent.nousresearch.com/docs/getting-started/quickstart)
· [Docker](https://hermes-agent.nousresearch.com/docs/user-guide/docker)
· [Configuration](https://hermes-agent.nousresearch.com/docs/user-guide/configuration)
· [Discord](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/discord)
· [Slack](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/slack)

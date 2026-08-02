#!/usr/bin/env bash
# hermes-run.sh — start the Hermes agent (hermes-1) detached.
#
# Deliberately NOT part of the Claude fleet: no launchd, no KeepAlive, and the
# name is absent from ${AGENTS}, so reset-agents.sh / stop-agents.sh never
# touch it. s6 inside the image restarts the gateway if it crashes; nothing
# restarts the container itself, so this doesn't survive a reboot — rerun it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"   # for ${VAULT}

NAME="hermes-1"
HERMES_IMAGE="nousresearch/hermes-agent:latest"
HERMES_DATA="${SCRIPT_DIR}/data"   # gitignored; self-contained, not ~/.hermes

[ -f "${HERMES_DATA}/.env" ] || { echo "missing ${HERMES_DATA}/.env" >&2; exit 1; }
if grep -q '^[A-Z_]*=REPLACE_ME$' "${HERMES_DATA}/.env"; then
  echo "${HERMES_DATA}/.env still has REPLACE_ME placeholders — fill them in first." >&2
  exit 1
fi

container system status &>/dev/null || container system start

# --- Make `hermes tools post-setup <key>` installs permanent -----------------
# The container is disposable (rm -f below), so anything written into the image
# tree at /opt/hermes is lost on every start. Hermes already has a durable
# install dir on our mount — HERMES_LAZY_INSTALL_TARGET=/opt/data/lazy-packages,
# which hermes_bootstrap.py appends to sys.path at startup — but only *lazy*
# runtime imports land there. The explicit `post-setup` hooks call _pip_install,
# which shells out to `uv pip install` and writes into /opt/hermes/.venv.
#
# uv 0.11.6 has no UV_TARGET env var, and _pip_install pins VIRTUAL_ENV from
# sys.executable, so there is no supported env-var redirect. The seam is PATH:
# the image sets PATH=/opt/hermes/bin:/opt/hermes/.venv/bin:/opt/data/.local/bin:
# /usr/local/bin:... and _pip_install resolves uv via shutil.which(). A shim in
# the mount's bin dir therefore wins over /usr/local/bin/uv.
#
# Written here (not by hand in the mount) so it is version-controlled and a
# fresh hermes/data/ rebuilds it. Idempotent.
mkdir -p "${HERMES_DATA}/.local/bin"
cat > "${HERMES_DATA}/.local/bin/uv" <<'SHIM'
#!/bin/sh
# Shim: redirect `uv pip install` into the persisted lazy-install target so
# `hermes tools post-setup <key>` survives container recreation. Every other
# uv invocation passes through untouched.
#
# --target can't see the venv's existing packages, so deps get re-downloaded.
# That is inert weight, not a shadowing risk: hermes_bootstrap APPENDS the
# target to sys.path, so the venv's copies still win at import time.
REAL=/usr/local/bin/uv
TARGET="${HERMES_LAZY_INSTALL_TARGET:-/opt/data/lazy-packages}"
if [ "$1" = "pip" ] && [ "$2" = "install" ]; then
  shift 2
  exec "$REAL" pip install --target "$TARGET" "$@"
fi
exec "$REAL" "$@"
SHIM
chmod +x "${HERMES_DATA}/.local/bin/uv"

# --- Let agent-browser find the Chromium the image already ships -------------
# The official image bakes in 344MB of Chromium, but the bundled agent-browser
# CLI can't discover it, so every browser_* tool call died on a 30-60s timeout.
# Cause is a layout mismatch, not a missing browser:
#
#   agent-browser looks for  chromium-<rev>/chrome-linux64/chrome
#   the image ships          chromium_headless_shell-<rev>/chrome-linux/headless_shell
#
# It searches PLAYWRIGHT_BROWSERS_PATH but only recognises the full-Chrome
# layout. Meanwhile tools/browser_tool.py::_chromium_installed() accepts EITHER
# name, so Hermes advertised the browser toolset as available while the CLI
# beneath it could never launch. AGENT_BROWSER_EXECUTABLE_PATH (read natively by
# both agent-browser and _chromium_installed) fixes both halves at once.
#
# Pointed at a shim rather than the binary because "1234" is a Playwright
# revision that changes when the image updates — a hardcoded path would silently
# re-break on the next `container image pull`. The headless-shell build speaks
# CDP and drives agent-browser fine (verified: `open https://example.com`).
cat > "${HERMES_DATA}/.local/bin/chromium-shim" <<'SHIM'
#!/bin/sh
# Resolve the baked Chromium at runtime; prefer headless-shell, fall back to a
# full Chrome build if a future image ships one.
for d in /opt/hermes/.playwright/chromium_headless_shell-*/chrome-linux/headless_shell \
         /opt/hermes/.playwright/chromium-*/chrome-linux64/chrome; do
  [ -x "$d" ] && exec "$d" "$@"
done
echo "chromium-shim: no Chromium found under /opt/hermes/.playwright" >&2
exit 127
SHIM
chmod +x "${HERMES_DATA}/.local/bin/chromium-shim"

# Clean slot: drop any stale/stopped/running container with this name.
container rm -f "${NAME}" &>/dev/null || true

# Detached, no --rm: keep the container inspectable after a crash.
# Discord is an outbound WebSocket, so no ports need publishing.
# --workdir /vault is what makes the vault's context files (CLAUDE.md,
# .hermes.md) load into every session.
#
# PYTHONPATH is the second half of the shim above. hermes_bootstrap adds
# lazy-packages to sys.path *in-process*, but several tools run their work in a
# subprocess — plugins/web/ddgs/provider.py builds the child's environment from
# the inherited PYTHONPATH only, so the parent's sys.path never reaches it.
# Without this the package installs fine and then fails at runtime with
# ModuleNotFoundError inside the worker.
container run -d \
  --name "${NAME}" \
  --env PYTHONPATH=/opt/data/lazy-packages \
  --env AGENT_BROWSER_EXECUTABLE_PATH=/opt/data/.local/bin/chromium-shim \
  --mount "source=${HERMES_DATA},target=/opt/data" \
  --mount "source=${VAULT},target=/vault" \
  --workdir /vault \
  "${HERMES_IMAGE}" gateway run

echo "started ${NAME}; logs: container logs -f ${NAME}"

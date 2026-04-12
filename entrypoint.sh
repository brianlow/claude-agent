#!/bin/bash
# ~/.claude.json can't be file-mounted (Apple Container requires directories).
# We stash it inside ~/.claude/ on the host and link it into place here.
if [ -f /home/user/.claude/.claude.json ]; then
  ln -sf /home/user/.claude/.claude.json /home/user/.claude.json
fi

# Pre-accept the folder trust prompt for /vault so claude doesn't ask on every run.
# hasTrustDialogAccepted is stored per-project in ~/.claude.json.
if [ -f /home/user/.claude.json ]; then
  trusted=$(jq '.projects["/vault"].hasTrustDialogAccepted // false' /home/user/.claude.json 2>/dev/null)
  if [ "$trusted" != "true" ]; then
    tmp=$(mktemp)
    jq '.projects["/vault"].hasTrustDialogAccepted = true' /home/user/.claude.json > "$tmp" && mv "$tmp" /home/user/.claude.json
  fi
fi

# Register Playwright MCP server (user scope — persists via ~/.claude.json host mount)
if ! claude mcp list 2>/dev/null | grep -q playwright; then
  claude mcp add --scope user playwright -- \
    node /usr/local/lib/node_modules/@playwright/mcp/cli.js \
    --browser chromium --headless
fi

exec claude --dangerously-skip-permissions --permission-mode bypassPermissions --remote-control --remote-control-session-name-prefix agent

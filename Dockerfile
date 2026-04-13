FROM node:22-slim

# Install browsers to a fixed path accessible by all users
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

# Install Playwright MCP and Chromium first — slow, but rarely changes
# Cached independently from Claude Code so updates to claude don't bust this layer
RUN npm install -g @playwright/mcp
RUN npx playwright install --with-deps chromium && chmod -R 755 /ms-playwright \
 && mkdir -p /opt/google/chrome \
 && ln -sf "$(find /ms-playwright -name chrome -type f -path '*/chrome-linux/chrome')" /opt/google/chrome/chrome

# Install Claude Code — updated more frequently, keep near the end
RUN npm install -g @anthropic-ai/claude-code

# Create a non-root user (--dangerously-skip-permissions is blocked for root)
# Give passwordless sudo so they can install packages freely
# curl + jq are used by umami-export.sh; python3/pip + gcalcli for calendar access
RUN apt-get update && apt-get install -y sudo curl jq sqlite3 python3 python3-pip && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash user \
 && echo "user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/user \
 && pip3 install --break-system-packages gcalcli

WORKDIR /vault
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER user
ENTRYPOINT ["/entrypoint.sh"]

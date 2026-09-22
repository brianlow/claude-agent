FROM node:22-slim

# Install browsers to a fixed path accessible by all users
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

# Install Playwright MCP and Chromium first — slow, but rarely changes
# Cached independently from Claude Code so updates to claude don't bust this layer
RUN npm install -g @playwright/mcp
# Install browsers with the playwright @playwright/mcp pins (npx from its package
# dir, --no so it can never silently fetch one), not `npx playwright`'s `latest`.
# Otherwise every build pulls whatever chromium the newest playwright wants, and
# the layout moves under us — 1.63 switched to Chrome for Testing, where the
# binary lives in chrome-linux-arm64/, not chrome-linux/.
#
# RES_OPTIONS=no-aaaa: cdn.playwright.dev has an AAAA record and containers have
# no IPv6 egress. Playwright's downloader forces IPv6 first and allows each
# attempt 5s; that attempt timeout surfaces as a request 'timeout', which its own
# handler reports as a fatal "timed out after 30000ms" before the IPv4 fallback
# lands. Hiding AAAA from glibc keeps the download on IPv4. curl is unaffected,
# which is why apt in this same step downloads 94MB happily.
RUN cd /usr/local/lib/node_modules/@playwright/mcp \
 && RES_OPTIONS=no-aaaa npx --no -- playwright install --with-deps chromium \
 && chmod -R 755 /ms-playwright \
 && mkdir -p /opt/google/chrome \
 && ln -sf "$(find /ms-playwright -name chrome -type f -path '*/chromium-*/chrome-linux*/chrome')" /opt/google/chrome/chrome

# Install Claude Code — updated more frequently, keep near the end
RUN npm install -g @anthropic-ai/claude-code @cometix/ccline agent-browser

# Create a non-root user (--dangerously-skip-permissions is blocked for root)
# Give passwordless sudo so they can install packages freely
# curl + jq are used by umami-export.sh; python3/pip + gcalcli for calendar access
RUN apt-get update && apt-get install -y sudo curl jq sqlite3 python3 python3-pip \
    fonts-liberation fonts-noto-color-emoji fonts-unifont fonts-freefont-ttf \
    fonts-ipafont-gothic fonts-wqy-zenhei fonts-tlwg-loma-otf \
    && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash user \
 && echo "user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/user \
 && pip3 install --break-system-packages gcalcli cloakbrowser

WORKDIR /vault
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER user
# Pre-download CloakBrowser stealth Chromium binary (~200MB) so it's ready at runtime
RUN python3 -c "from cloakbrowser import ensure_binary; ensure_binary()"

ENTRYPOINT ["/entrypoint.sh"]

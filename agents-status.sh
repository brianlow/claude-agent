#!/usr/bin/env bash
# agents-status.sh — print the launchd + container status of all 5 agents.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
print_status

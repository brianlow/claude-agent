#!/usr/bin/env bash
# hermes-stop.sh — tear down the Hermes container. Idempotent.
# State lives in hermes/data/ on the host, so nothing is lost.
set -euo pipefail
container rm -f hermes-1 &>/dev/null || true
echo "hermes-1 stopped"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="claude-code:latest"

echo "Building image '${IMAGE}'..."
container build --tag "${IMAGE}" --file "${SCRIPT_DIR}/Dockerfile" "${SCRIPT_DIR}"
echo "Done."

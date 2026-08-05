#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="claude-code:latest"

# Any image this build pulls gets unpacked once per platform in its index —
# an amd64 rootfs this Mac can't execute still costs GBs in snapshots/.
# Pin the pulls to the only platform we run.
export CONTAINER_DEFAULT_PLATFORM="${CONTAINER_DEFAULT_PLATFORM:-linux/arm64}"

echo "Building image '${IMAGE}'..."
container build --tag "${IMAGE}" --file "${SCRIPT_DIR}/Dockerfile" "${SCRIPT_DIR}"

# This build just orphaned the previous claude-code:latest snapshot (~3.8GB) and
# its layers, with no dangling image record for `container image prune` to find.
# Collect them now, while we know a build just happened.
"${SCRIPT_DIR}/prune-images.sh" --yes

echo "Done."

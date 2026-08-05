#!/usr/bin/env bash
# prune-images.sh — reclaim the snapshots and blobs Apple Container leaks.
#
# Every `./build.sh` mints a new claude-code:latest manifest digest. state.json
# is a flat tag->digest map, so the previous digest is *overwritten* rather than
# left behind as a dangling <none> image. `container image prune` looks for
# dangling images, finds none, and exits happy — while the old snapshot (~3.8GB)
# and its layers sit orphaned forever. 17 builds had accumulated 45GB this way.
#
# So we do the reachability walk ourselves: state.json -> index -> manifest ->
# config + layers. Anything in snapshots/ or content/blobs/ that walk never
# reaches is garbage.
#
# The one thing that must not go wrong: snapshots/ holds dirs no *image*
# references but every *container* mounts — vminit (the guest init fs) and the
# BuildKit builder. Deleting those bricks the whole host. Hence the second
# root set, scraped from each container's runtime-configuration.json.
#
# Dry run by default. --yes to actually delete.
set -euo pipefail

CONTAINER_ROOT="${CONTAINER_ROOT:-${HOME}/Library/Application Support/com.apple.container}"

DELETE=0
for arg in "$@"; do
  case "${arg}" in
    -y|--yes)  DELETE=1 ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "prune-images.sh: unknown argument '${arg}'" >&2; exit 2 ;;
  esac
done

STATE="${CONTAINER_ROOT}/state.json"
BLOBS="${CONTAINER_ROOT}/content/blobs/sha256"
SNAPS="${CONTAINER_ROOT}/snapshots"

[ -d "${CONTAINER_ROOT}" ] || { echo "prune-images.sh: no container store at ${CONTAINER_ROOT}" >&2; exit 1; }
[ -f "${STATE}" ]          || { echo "prune-images.sh: missing ${STATE}" >&2; exit 1; }
command -v jq >/dev/null   || { echo "prune-images.sh: jq is required" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
seen="${tmp}/seen"; : > "${seen}"
pinned="${tmp}/pinned"; : > "${pinned}"

# Walk one digest and everything it references. Depth is 3 (index -> manifest ->
# config/layers), so plain recursion is fine. Layer blobs are gzip, not JSON;
# jq fails on them and the walk simply stops there.
walk() {
  local dig="${1#sha256:}" f kids child
  grep -qx "${dig}" "${seen}" 2>/dev/null && return 0
  echo "${dig}" >> "${seen}"
  f="${BLOBS}/${dig}"
  [ -f "${f}" ] || return 0
  kids="$(jq -r '[(.manifests[]?.digest), .config.digest, (.layers[]?.digest)]
                 | map(select(. != null)) | .[]' "${f}" 2>/dev/null || true)"
  for child in ${kids}; do walk "${child}"; done
}

for root_digest in $(jq -r '.[].digest' "${STATE}"); do walk "${root_digest}"; done

# Refuse to run if the walk found nothing — a corrupt or empty state.json must
# not be read as "everything is garbage".
if [ ! -s "${seen}" ]; then
  echo "prune-images.sh: no images reachable from state.json; refusing to prune" >&2
  exit 1
fi

# Second root set: snapshots mounted by an existing container.
for cfg in "${CONTAINER_ROOT}"/containers/*/runtime-configuration.json; do
  [ -f "${cfg}" ] || continue
  grep -oE 'snapshots\\?/[a-f0-9]{64}' "${cfg}" | grep -oE '[a-f0-9]{64}' >> "${pinned}" || true
done

kb=0
note() { # note <kind> <digest> <kilobytes>
  printf '  %-9s %s  %6s MB\n' "$1" "${2:0:16}" "$(( $3 / 1024 ))"
}

echo "Pruning ${CONTAINER_ROOT}"

for dir in "${SNAPS}"/*/; do
  [ -d "${dir}" ] || continue
  name="$(basename "${dir}")"
  [ "${name}" = "ingest" ] && continue
  grep -qx "${name}" "${seen}"   2>/dev/null && continue
  grep -qx "${name}" "${pinned}" 2>/dev/null && continue
  size="$(du -sk "${dir}" | cut -f1)"
  kb=$(( kb + size ))
  note snapshot "${name}" "${size}"
  [ "${DELETE}" -eq 1 ] && rm -rf "${dir}"
done

if [ -d "${BLOBS}" ]; then
  for f in "${BLOBS}"/*; do
    [ -f "${f}" ] || continue
    name="$(basename "${f}")"
    grep -qx "${name}" "${seen}" 2>/dev/null && continue
    size="$(du -sk "${f}" | cut -f1)"
    kb=$(( kb + size ))
    note blob "${name}" "${size}"
    [ "${DELETE}" -eq 1 ] && rm -f "${f}"
  done
fi

gb="$(awk -v k="${kb}" 'BEGIN{printf "%.2f", k/1048576}')"
if [ "${kb}" -eq 0 ]; then
  echo "  nothing to reclaim"
elif [ "${DELETE}" -eq 1 ]; then
  echo "Reclaimed ${gb} GB."
  echo "Note: a Time Machine local APFS snapshot can pin freed blocks for ~24h," \
       "so df may not move until it rotates."
else
  echo "Would reclaim ${gb} GB. This was a dry run — re-run with --yes to delete."
fi

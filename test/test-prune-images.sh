#!/usr/bin/env bash
# Test of prune-images.sh against a synthetic container data root. Nothing here
# touches the real ~/Library/Application Support/com.apple.container — the
# script takes CONTAINER_ROOT so the whole store can be faked in a tmpdir.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 — got '$2' want '$3'"; fail=1; fi; }
present() { [ -e "$1" ] && echo yes || echo no; }

# 64-hex-char stand-ins for real digests.
d() { printf "$1%.0s" {1..64}; }
IDX="$(d 1)"; MAN="$(d 2)"; CFG="$(d 3)"; LYR="$(d 4)"
STALE="$(d 5)"; PINNED="$(d 6)"; ORPHAN="$(d 7)"

setup() { # setup -> populates a fresh $root
  root="$(mktemp -d)"
  mkdir -p "${root}/content/blobs/sha256" "${root}/snapshots" "${root}/containers/c1"

  cat > "${root}/state.json" <<EOF
{"claude-code:latest":{"size":375,"digest":"sha256:${IDX}","mediaType":"application/vnd.oci.image.index.v1+json"}}
EOF
  cat > "${root}/content/blobs/sha256/${IDX}" <<EOF
{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json",
 "manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:${MAN}","size":1}]}
EOF
  cat > "${root}/content/blobs/sha256/${MAN}" <<EOF
{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json",
 "config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:${CFG}","size":1},
 "layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar+gzip","digest":"sha256:${LYR}","size":1}]}
EOF
  echo '{"os":"linux"}'      > "${root}/content/blobs/sha256/${CFG}"
  printf '\x1f\x8bnot-json'  > "${root}/content/blobs/sha256/${LYR}"   # gzip layer, must not be parsed
  printf '\x1f\x8bnot-json'  > "${root}/content/blobs/sha256/${ORPHAN}"

  # Snapshot dirs are named by manifest digest.
  for s in "${MAN}" "${STALE}" "${PINNED}"; do
    mkdir -p "${root}/snapshots/${s}"
    echo fake > "${root}/snapshots/${s}/snapshot"
  done
  mkdir -p "${root}/snapshots/ingest"

  # A live container pinning PINNED, which no image references. This is the
  # real vminit/builder case: naive digest matching would delete it and brick
  # every container on the host. Slashes are backslash-escaped, as Apple
  # Container actually writes them.
  cat > "${root}/containers/c1/runtime-configuration.json" <<EOF
{"mounts":[{"source":"\\/tmp\\/snapshots\\/${PINNED}\\/snapshot","destination":"\\/"}]}
EOF
}

teardown() { rm -rf "${root}"; }

# --- dry run is the default and must delete nothing ---
setup
out="$(CONTAINER_ROOT="${root}" ./prune-images.sh)"
check "dry-run: stale snapshot survives"  "$(present "${root}/snapshots/${STALE}")" "yes"
check "dry-run: orphan blob survives"     "$(present "${root}/content/blobs/sha256/${ORPHAN}")" "yes"
grep -q "${STALE:0:12}" <<<"${out}" && echo "PASS: dry-run names the stale snapshot" || { echo "FAIL: dry-run names the stale snapshot"; fail=1; }
grep -qi "dry run" <<<"${out}" && echo "PASS: dry-run says so" || { echo "FAIL: dry-run says so"; fail=1; }
teardown

# --- --yes actually deletes, and only the right things ---
setup
CONTAINER_ROOT="${root}" ./prune-images.sh --yes > /dev/null
check "delete: unreferenced snapshot removed"     "$(present "${root}/snapshots/${STALE}")"  "no"
check "delete: reachable snapshot kept"           "$(present "${root}/snapshots/${MAN}")"    "yes"
check "delete: container-pinned snapshot kept"    "$(present "${root}/snapshots/${PINNED}")" "yes"
check "delete: ingest dir untouched"              "$(present "${root}/snapshots/ingest")"    "yes"
check "delete: orphan blob removed"               "$(present "${root}/content/blobs/sha256/${ORPHAN}")" "no"
check "delete: index blob kept"                   "$(present "${root}/content/blobs/sha256/${IDX}")"    "yes"
check "delete: manifest blob kept"                "$(present "${root}/content/blobs/sha256/${MAN}")"    "yes"
check "delete: config blob kept"                  "$(present "${root}/content/blobs/sha256/${CFG}")"    "yes"
check "delete: layer blob kept"                   "$(present "${root}/content/blobs/sha256/${LYR}")"    "yes"
check "delete: state.json untouched"              "$(present "${root}/state.json")"          "yes"
teardown

# --- second run is a no-op (idempotent) ---
setup
CONTAINER_ROOT="${root}" ./prune-images.sh --yes > /dev/null
out="$(CONTAINER_ROOT="${root}" ./prune-images.sh --yes)"
check "idempotent: nothing left to reclaim" "$(grep -c "${STALE:0:12}" <<<"${out}" || true)" "0"
teardown

# --- a state.json listing no images must NOT be read as "delete everything" ---
setup
echo '{}' > "${root}/state.json"
rc=0
CONTAINER_ROOT="${root}" ./prune-images.sh --yes >/dev/null 2>&1 || rc=$?
check "empty state.json refuses to prune"  "$([ "${rc}" -ne 0 ] && echo yes || echo no)" "yes"
check "empty state.json keeps snapshots"   "$(present "${root}/snapshots/${MAN}")"       "yes"
check "empty state.json keeps blobs"       "$(present "${root}/content/blobs/sha256/${LYR}")" "yes"
teardown

# --- a missing root is an error, not a silent success ---
rc=0
CONTAINER_ROOT="/nonexistent/$$" ./prune-images.sh --yes >/dev/null 2>&1 || rc=$?
check "missing root exits nonzero" "$([ "${rc}" -ne 0 ] && echo yes || echo no)" "yes"

exit $fail

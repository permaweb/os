#!/usr/bin/env bash
# build-hb-release.sh — produce `_build/lapee/rel/hb' from the
# HyperBEAM source tree at build-hyperbeam/src-edge/. Runs inside
# the pinned-base lapee-hyperbeam-builder image (Erlang 27.3.4.10
# on Debian bookworm + libtss2-dev).
#
# Preconditions:
#   - `make hb-fetch' has populated build-hyperbeam/src-edge/
#     (or the user manually provisioned it).
#   - `make toolchain' has built the lapee-hyperbeam-builder
#     image.
#
# Output: build-hyperbeam/src-edge/_build/lapee/rel/hb/bin/hb

set -euo pipefail
cd "$(dirname "$0")/.."
LAPEE=$(pwd)

SRC="$LAPEE/build-hyperbeam/src-edge"
IMAGE="${HB_IMAGE:-lapee-hyperbeam-builder:local}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-}"

if [[ ! -f "$SRC/rebar.config" ]]; then
    echo "missing HyperBEAM source at $SRC."                          >&2
    echo "Run: make hb-fetch                  (clone from origin)"   >&2
    echo "or:  HB_SRC=path/to/local make hb-fetch"                   >&2
    exit 1
fi

# Kill any dangling build container.
docker rm -f lapee-hb-edge-build 2>/dev/null || true

# Wipe just the release output so relx isn't tripped by stale
# state. `_build/lapee/lib/' stays for incremental rebuilds.
rm -rf "$SRC/_build/lapee/rel"

# relx copies `config.flat' into the release when it exists; when
# it doesn't, it prints a warning and returns nonzero. The file
# isn't used by the LapEE guest flow (HB_CONFIG is set in the
# init script), so we drop an empty placeholder to keep relx
# quiet without changing release semantics.
touch "$SRC/config.flat"

docker run $DOCKER_PLATFORM --rm --name lapee-hb-edge-build \
    -v "$SRC":/src \
    -w /src \
    "$IMAGE" \
    bash -c '
        set -e
        rebar3 as lapee release
    '

echo ""
ls -lh "$SRC/_build/lapee/rel/hb/bin/hb"
echo ""
echo "HB release ready for: ./scripts/build-initramfs-hb.sh"

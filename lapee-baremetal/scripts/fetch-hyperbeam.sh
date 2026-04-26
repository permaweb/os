#!/usr/bin/env bash
# fetch-hyperbeam.sh — provision the HyperBEAM source tree at
# build-hyperbeam/src-edge/ for the LapEE release build.
#
# Two modes:
#
#   1. Local checkout (HB_SRC=path):
#      Rsyncs an existing HyperBEAM checkout into build-hyperbeam/
#      src-edge/. Useful when iterating on HB itself in a sibling
#      worktree. `_build/' is excluded so each side keeps its own
#      release artefacts.
#
#   2. Remote clone (default):
#      git clones HB_REPO at HB_COMMIT into build-hyperbeam/src-edge/.
#      First run: full clone. Subsequent runs: fetch + checkout +
#      reset, so changing HB_COMMIT just re-points the worktree.
#
# Idempotent. Safe to re-run.

set -euo pipefail
cd "$(dirname "$0")/.."
LAPEE=$(pwd)

HB_REPO=${HB_REPO:-https://github.com/permaweb/HyperBEAM.git}
HB_COMMIT=${HB_COMMIT:-edge}
HB_SRC_DIR=${HB_SRC_DIR:-build-hyperbeam/src-edge}
HB_SRC=${HB_SRC:-}

mkdir -p "$(dirname "$HB_SRC_DIR")"

if [[ -n "$HB_SRC" ]]; then
    if [[ ! -f "$HB_SRC/rebar.config" ]]; then
        echo "HB_SRC=$HB_SRC does not look like a HyperBEAM checkout"  >&2
        echo "(no rebar.config at the top level)"                      >&2
        exit 1
    fi
    echo ">> rsyncing $HB_SRC -> $HB_SRC_DIR"
    # Reject any HB_SRC tree that itself has a `lapee-baremetal/'
    # subtree. That subtree is the migration source — round-tripping
    # it through the HB build container risks leaking operator
    # secrets (`secureboot/*.key', `wifi.conf' with the PSK in
    # plaintext) into a directory that gets mounted at /src and
    # potentially redistributed in build artefacts. The HB checkout
    # consumed by `rebar3 as lapee release' should be plain HB.
    rsync -a \
        --exclude='_build/' --exclude='.git/' \
        --exclude='logs/' --exclude='metrics/' \
        --exclude='priv/crates/' \
        --exclude='priv/html/' \
        --exclude='priv/static/' \
        --exclude='rebar3.crashdump' \
        --exclude='native/lib/secp256k1/build/' \
        --exclude='*.o' --exclude='*.so' --exclude='*.dylib' \
        --exclude='*.cargo/' \
        --exclude='lapee-baremetal/' \
        "$HB_SRC/" "$HB_SRC_DIR/"
    # Initialise the secp256k1 submodule against the source so
    # the build container sees a populated tree (the rebar3
    # in-container submodule fetch has no access to the host's
    # .git).
    if [[ ! -f "$HB_SRC_DIR/native/lib/secp256k1/CMakeLists.txt" \
          && -d "$HB_SRC/native/lib/secp256k1/.git" ]]; then
        echo ">> copying secp256k1 submodule contents"
        rsync -a --exclude='build/' --exclude='.git/' \
            "$HB_SRC/native/lib/secp256k1/" \
            "$HB_SRC_DIR/native/lib/secp256k1/"
    fi
    echo ">> HB source ready at $HB_SRC_DIR (rsync from $HB_SRC)"
    exit 0
fi

# Remote clone path.
if [[ -d "$HB_SRC_DIR/.git" ]]; then
    echo ">> updating existing clone at $HB_SRC_DIR (commit=$HB_COMMIT)"
    git -C "$HB_SRC_DIR" fetch --depth=50 origin
    git -C "$HB_SRC_DIR" checkout -q --detach "$HB_COMMIT"
    git -C "$HB_SRC_DIR" submodule update --init --depth=10 \
        native/lib/secp256k1 2>/dev/null || true
else
    echo ">> cloning $HB_REPO -> $HB_SRC_DIR (commit=$HB_COMMIT)"
    git clone --filter=blob:none "$HB_REPO" "$HB_SRC_DIR"
    git -C "$HB_SRC_DIR" checkout -q --detach "$HB_COMMIT"
    git -C "$HB_SRC_DIR" submodule update --init --depth=10 \
        native/lib/secp256k1
fi
echo ">> HB source ready at $HB_SRC_DIR ($(git -C "$HB_SRC_DIR" rev-parse --short HEAD))"

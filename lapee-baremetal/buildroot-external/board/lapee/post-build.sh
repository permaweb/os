#!/bin/sh
# post-build.sh — runs after Buildroot has installed the rootfs
# overlay + target packages, before image-creation.
#
# Responsibilities:
#   1. Compile lapee_splash.erl using host-erlang and stage the
#      resulting .beam into /usr/local/lib/lapee-splash/.
#   2. Sanity-check that everything we expect on the target is
#      present (HyperBEAM, libtss2, busybox, init).
#
# $1 = TARGET_DIR

set -eu

TARGET_DIR=$1
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LAPEE_EXT=${BR2_EXTERNAL_LAPEE_PATH:-}
if [ -z "$LAPEE_EXT" ] || [ ! -f "$LAPEE_EXT/board/lapee/files/lapee_splash.erl" ]; then
    LAPEE_EXT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
fi
HOST_ROOT=${HOST_DIR:-$(dirname "$TARGET_DIR")/host}
HOST_ERLC=$HOST_ROOT/bin/erlc

# 1. Splash daemon: compile from this BR2_EXTERNAL tree's source
#    using host-erlang, install into the target rootfs.
if [ -x "$HOST_ERLC" ]; then
    SPLASH_SRC=$LAPEE_EXT/board/lapee/files/lapee_splash.erl
    SPLASH_DST=$TARGET_DIR/usr/local/lib/lapee-splash
    echo ">> compiling lapee_splash from $SPLASH_SRC with $HOST_ERLC"
    if [ ! -f "$SPLASH_SRC" ]; then
        echo "!! splash source not found: $SPLASH_SRC" >&2
        exit 1
    fi
    mkdir -p "$SPLASH_DST"
    (cd "$(dirname "$SPLASH_SRC")" && "$HOST_ERLC" -o "$SPLASH_DST" lapee_splash.erl)
    echo ">> lapee_splash.beam installed at $SPLASH_DST"
else
    echo "!! host-erlang not found at $HOST_ERLC; splash not built" >&2
    exit 1
fi

# 2. Sanity checks.
for f in /init /etc/lapee/lapee-enforced.flat \
         /usr/lib/hyperbeam/bin/hb \
         /usr/local/lib/lapee-splash/lapee_splash.beam \
         /lib/firmware/regulatory.db; do
    if [ ! -e "$TARGET_DIR$f" ]; then
        echo "!! post-build: missing $TARGET_DIR$f" >&2
        exit 1
    fi
done

echo ">> post-build sanity checks passed"

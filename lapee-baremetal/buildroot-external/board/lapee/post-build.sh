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
LAPEE_EXT=$BR2_EXTERNAL_LAPEE_PATH
HOST_ERLC=$HOST_DIR/bin/erlc

# 1. Splash daemon: compile from this BR2_EXTERNAL tree's source
#    using host-erlang, install into the target rootfs.
if [ -x "$HOST_ERLC" ]; then
    SPLASH_SRC=$LAPEE_EXT/board/lapee/files/lapee_splash.erl
    SPLASH_DST=$TARGET_DIR/usr/local/lib/lapee-splash
    mkdir -p "$SPLASH_DST"
    "$HOST_ERLC" -o "$SPLASH_DST" "$SPLASH_SRC"
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

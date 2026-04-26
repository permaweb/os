#!/usr/bin/env bash
# build-initramfs-hb.sh — assemble a LapEE guest initramfs
# containing the full HyperBEAM release (lapee profile + dev_tpm2
# NIF) + enforced config + slim init + BEAM boot splash.
#
# Requires:
#   - build-hyperbeam/src-edge/_build/lapee/rel/hb (the HB
#     release; produced by `make hb-release').
#   - config/lapee-enforced.flat (committed in this repo).
#   - the lapee-hyperbeam-builder image (built by `make
#     toolchain') — we run library / firmware harvesting + BEAM
#     load-check inside it.
#
# Output: work/initramfs-hb.cpio.{gz,zst}.

set -euo pipefail
cd "$(dirname "$0")/.."
LAPEE=$(pwd)

HB_REL="$LAPEE/build-hyperbeam/src-edge/_build/lapee/rel/hb"
ENFORCED_CFG="$LAPEE/config/lapee-enforced.flat"
IMAGE="${HB_IMAGE:-lapee-hyperbeam-builder:local}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-}"

if [[ ! -d "$HB_REL" ]]; then
    echo "missing HB release at $HB_REL; run: make hb-release"   >&2
    exit 1
fi
if [[ ! -f "$ENFORCED_CFG" ]]; then
    echo "missing enforced config at $ENFORCED_CFG"              >&2
    exit 1
fi

docker rm -f lapee-hb-mini 2>/dev/null || true
docker run -d $DOCKER_PLATFORM --name lapee-hb-mini \
    "$IMAGE" sleep infinity >/dev/null

# Install busybox + iproute2 + WiFi userspace inside the builder.
# Firmware blobs for Intel AX210 + MediaTek MT7922 ship in
# Debian's `firmware-iwlwifi` and `firmware-misc-nonfree' packages
# (in non-free-firmware); we only copy the few MB we actually
# need into the initramfs further down.
docker exec -i lapee-hb-mini bash <<'SH_APT'
set -e
# Add non-free-firmware to whichever sources file Debian's
# erlang base ships. The image uses .sources (deb822) format in
# bookworm; there's also a legacy sources.list. Touch both to
# add `non-free-firmware' to each `Components:' / suite line.
# Doing it in-place avoids a second source file with a different
# Signed-By, which apt-get refuses ("Conflicting values set for
# option Signed-By").
if compgen -G '/etc/apt/sources.list.d/*.sources' > /dev/null 2>&1; then
    for f in /etc/apt/sources.list.d/*.sources; do
        # Components line: append non-free-firmware if missing.
        sed -i -E '/^Components:/{ /non-free-firmware/!s/$/ contrib non-free-firmware/ }' "$f"
    done
fi
if [ -s /etc/apt/sources.list ]; then
    # Legacy lines like `deb URL suite main' — append components
    # at end of line.
    sed -i -E '/^deb /{ /non-free-firmware/!s/$/ contrib non-free-firmware/ }' \
        /etc/apt/sources.list
fi
apt-get update -qq 2>&1 | tail -3
apt-get install -y -qq --no-install-recommends \
    busybox-static \
    iproute2 \
    wpasupplicant \
    iw \
    firmware-iwlwifi \
    firmware-misc-nonfree \
    zstd 2>&1 | tail -3
SH_APT

# Copy HB release + enforced config + init script + DHCP hook.
docker cp "$HB_REL" lapee-hb-mini:/opt/hb
docker cp "$ENFORCED_CFG" lapee-hb-mini:/opt/lapee-enforced.flat
docker cp "$LAPEE/initramfs-hb/init"            lapee-hb-mini:/init-hb
docker exec lapee-hb-mini mkdir -p /ramfs-src
docker cp "$LAPEE/initramfs-hb/lapee-dhcp-hook" lapee-hb-mini:/ramfs-src/lapee-dhcp-hook

# Compile lapee_splash.erl on the build HOST (Mac/Linux dev box)
# rather than in the slim runtime container — the runtime release
# strips the `compiler' app's .beam files, so erlc inside the
# container would crash with `compile:compile/2 undef'. BEAM
# bytecode is platform-independent, so a Mac-compiled .beam runs
# fine in the Linux guest's Linux-built BEAM VM.
echo "--- compiling lapee_splash.erl on build host ---"
HOST_ERLC=$(command -v erlc || true)
if [[ -z "$HOST_ERLC" ]]; then
    echo "!! host erlc not found; install Erlang/OTP and re-run" >&2
    exit 1
fi
SPLASH_BUILD="$LAPEE/work/splash-build"
mkdir -p "$SPLASH_BUILD"
"$HOST_ERLC" -o "$SPLASH_BUILD" "$LAPEE/initramfs-hb/lapee_splash.erl"
ls -la "$SPLASH_BUILD/lapee_splash.beam"
docker cp "$SPLASH_BUILD/lapee_splash.beam" \
    lapee-hb-mini:/ramfs-src/lapee_splash.beam

# Confirm HB's bundled erts can actually load the splash .beam.
# Catches host-vs-release OTP-major-version skew before the guest
# would crash at boot with `error_loading'.
docker exec lapee-hb-mini bash -c '
    HB_ERL=$(ls -d /opt/hb/erts-*/bin/erl 2>/dev/null | head -1)
    HB_BOOT=$(ls -d /opt/hb/releases/*/start_clean.boot 2>/dev/null | head -1)
    HB_BOOT=${HB_BOOT%.boot}
    if [ -n "$HB_ERL" ] && [ -x "$HB_ERL" ] && [ -n "$HB_BOOT" ]; then
        if ! "$HB_ERL" -boot "$HB_BOOT" -pa /ramfs-src -noshell \
            -eval "
                case code:load_file(lapee_splash) of
                    {module, _} -> halt(0);
                    E -> io:format(standard_error,
                                    \"load failed: ~p~n\", [E]),
                         halt(1)
                end."; then
            echo "!! splash .beam not loadable by HB erts ($HB_ERL)" >&2
            echo "!! host erlc is OTP-major-incompatible w/ HB release" >&2
            exit 1
        fi
        echo "--- splash .beam load-check passed ---"
    else
        echo "(skipping load-check: HB erts not found in container)" >&2
    fi
'

docker exec -i lapee-hb-mini bash <<'SH'
set -e
mkdir -p /ramfs/bin /ramfs/sbin /ramfs/etc/lapee \
    /ramfs/lib/x86_64-linux-gnu /ramfs/lib64 \
    /ramfs/usr/bin /ramfs/usr/sbin /ramfs/usr/local/bin /ramfs/usr/local/lib \
    /ramfs/usr/lib/ssl /ramfs/usr/lib/hyperbeam \
    /ramfs/proc /ramfs/sys /ramfs/dev /ramfs/tmp /ramfs/run /ramfs/out /ramfs/mnt

# busybox.
cp /usr/bin/busybox /ramfs/bin/busybox
cd /ramfs/bin
for cmd in sh mount umount ls cat cp mv rm mkdir ln chmod chown echo grep \
           sed awk find hostname ifconfig dmesg ps head tail wc tar gzip \
           sleep stat uname date touch test mknod reboot poweroff vi env \
           printf sync tee base64 udhcpc stty; do
    ln -sf busybox $cmd
done
cd /

# iproute2.
cp /usr/sbin/ip /ramfs/sbin/ip

# WiFi userspace. wpa_supplicant does WPA2/WPA3 auth and drives
# the kernel drivers via nl80211. iw is a thin debugging tool
# (scan, station info) useful when association fails.
#
# Credentials are NOT on the kernel cmdline. Init parses a
# strictly-validated /EFI/boot/wifi.conf off the ESP (unmeasured
# by design); the parser caps size + charset so wpa_supplicant.
# conf injection is not possible.
for bin in /usr/sbin/wpa_supplicant /sbin/wpa_supplicant; do
    [ -x "$bin" ] && cp "$bin" /ramfs/sbin/wpa_supplicant && break
done
for bin in /usr/sbin/iw /sbin/iw; do
    [ -x "$bin" ] && cp "$bin" /ramfs/sbin/iw && break
done

# WiFi firmware. Debian ships firmware as raw .ucode files in
# bookworm — no decompression needed (unlike the Ubuntu zstd
# variant). We copy only the few cards we know to ship.
mkdir -p /ramfs/lib/firmware/mediatek
FW_SRC=/lib/firmware
[ -d "$FW_SRC" ] || FW_SRC=/usr/lib/firmware

cp_fw() {
    # cp_fw <pattern> <dest>
    #   Copy first matching firmware file (or .zst variant
    #   decompressed) into dest.
    local pat="$1" dst="$2"
    if [ -f "$pat" ]; then
        cp "$pat" "$dst/"
    elif [ -f "${pat}.zst" ]; then
        zstd -d -q "${pat}.zst" -o "$dst/$(basename "$pat")" 2>/dev/null || true
    fi
}

if [ -d "$FW_SRC" ]; then
    # Intel AX210 (Framework 13 Intel variant).
    cp_fw "$FW_SRC/iwlwifi-ty-a0-gf-a0-73.ucode" /ramfs/lib/firmware
    cp_fw "$FW_SRC/iwlwifi-ty-a0-gf-a0.pnvm"     /ramfs/lib/firmware
    # Intel AX211 (Raptor Lake P refresh).
    cp_fw "$FW_SRC/iwlwifi-ma-b0-gf-a0-89.ucode" /ramfs/lib/firmware
    cp_fw "$FW_SRC/iwlwifi-ma-b0-gf-a0.pnvm"     /ramfs/lib/firmware
    # Regulatory DB (iwlwifi refuses to associate without it on
    # channels above the world-regdom 2.4 GHz set).
    for plain in "$FW_SRC/regulatory.db" "$FW_SRC/regulatory.db.p7s"; do
        [ -f "$plain" ] && cp "$plain" /ramfs/lib/firmware/
    done
    # MediaTek MT7922 (Framework 13 AMD variant).
    cp_fw "$FW_SRC/mediatek/WIFI_MT7922_patch_mcu_1_1_hdr.bin" \
        /ramfs/lib/firmware/mediatek
    cp_fw "$FW_SRC/mediatek/WIFI_RAM_CODE_MT7922_1.bin" \
        /ramfs/lib/firmware/mediatek
fi
echo "--- firmware shipped ---"
ls -la /ramfs/lib/firmware/ /ramfs/lib/firmware/mediatek/ 2>/dev/null
du -sh /ramfs/lib/firmware/ 2>/dev/null

# Shared libraries needed by HB (OTP + libtss2 + libcrypto +
# libssl + libnl + dbus etc.).
LIB=/ramfs/lib/x86_64-linux-gnu
for lib in libc.so.6 libc_malloc_debug.so.0 \
           libcrypto.so.3 libssl.so.3 \
           libtss2-esys.so.0 libtss2-mu.so.0 libtss2-tctildr.so.0 \
           libtss2-rc.so.0 libtss2-sys.so.1 libtss2-tcti-swtpm.so.0 \
           libpthread.so.0 libdl.so.2 libm.so.6 libz.so.1 libresolv.so.2 \
           libtinfo.so.6 libncursesw.so.6 \
           libstdc++.so.6 libgcc_s.so.1 libgmp.so.10 \
           libmnl.so.0 libbsd.so.0 libmd.so.0 libcap.so.2 \
           libnl-3.so.200 libnl-genl-3.so.200 libnl-route-3.so.200 \
           libdbus-1.so.3 libpcsclite.so.1 \
           libgcrypt.so.20 libgpg-error.so.0 liblzma.so.5 libzstd.so.1 \
           liblz4.so.1 libsystemd.so.0; do
    if [ -e /lib/x86_64-linux-gnu/$lib ]; then
        cp -L /lib/x86_64-linux-gnu/$lib $LIB/
    fi
    if [ ! -e $LIB/$lib ] && [ -e /usr/lib/x86_64-linux-gnu/$lib ]; then
        cp -L /usr/lib/x86_64-linux-gnu/$lib $LIB/
    fi
done
cp -L /usr/lib/x86_64-linux-gnu/libtss2-tcti-device.so.0 $LIB/ 2>/dev/null || true
cp -L /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 $LIB/
ln -sf /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 \
       /ramfs/lib64/ld-linux-x86-64.so.2

# DHCP hook + BEAM splash.
cp /ramfs-src/lapee-dhcp-hook /ramfs/usr/local/bin/lapee-dhcp-hook
chmod +x                       /ramfs/usr/local/bin/lapee-dhcp-hook
mkdir -p /ramfs/usr/local/lib/lapee-splash
cp /ramfs-src/lapee_splash.beam /ramfs/usr/local/lib/lapee-splash/

# HyperBEAM release.
cp -r /opt/hb/. /ramfs/usr/lib/hyperbeam/
chmod +x /ramfs/usr/lib/hyperbeam/bin/hb 2>/dev/null || true

# --- slim the release for the guest initramfs --------------------
# Three categories removed:
#   (a) verifier-side artefacts: priv/tpm-interpret/ is the static
#       JSON DB + root CAs consumed by dev_tpm_interpret on the
#       VERIFIER. The guest PRODUCES envelopes; it never
#       interprets them.
#   (b) static UI: priv/html / priv/static — LapEE serves
#       /~tpm2@2.0a/attestation, not a browser UI.
#   (c) build-time tools that don't belong in a runtime release
#       (erlc, dialyzer, typer, ct_run).
HB=/ramfs/usr/lib/hyperbeam
rm -rf $HB/bin/priv
rm -rf $HB/lib/hb-0.0.1/priv/html
rm -rf $HB/lib/hb-0.0.1/priv/static
rm -rf $HB/lib/hb-0.0.1/priv/tpm-interpret
# DO NOT delete dev_snp*/dev_hyperbuddy* .beam files even though
# the LapEE-enforced config doesn't preload them. The OTP release
# boot script (releases/0.0.1/hb.boot) statically names every
# module in every listed application; on VM startup, erlexec's
# embedded boot loads every such module BEFORE any user config is
# read. A missing .beam ⇒ load_failed ⇒ "Runtime terminating
# during boot" ⇒ kernel panic.
# .erl sources across all libs (compiled .beam is the runtime
# artefact; sources are debug-only).
find $HB/lib -type d -name src -exec rm -rf {} + 2>/dev/null || true
# Trim docs/examples/include-dev from every shipped lib.
for d in $HB/lib/*; do
    rm -rf "$d/doc" "$d/examples" "$d/man" "$d/c_src"
done
# Build-time tools.
for tool in ct_run dialyzer typer erlc; do
    find $HB/erts-* -name "$tool" -delete 2>/dev/null || true
done
# Strip BEAM + every shipped .so aggressively.
find $HB/erts-*/bin/beam.smp \
     $HB/lib -name '*.so' -type f 2>/dev/null \
    | xargs -r strip --strip-all 2>/dev/null || true
echo "--- post-slim HB size ---"
du -sh $HB /ramfs/usr/lib 2>/dev/null || true
echo "--- top 10 libs by size after slim ---"
du -sh $HB/lib/*/ 2>/dev/null | sort -hr | head -10

# LapEE-specific sys.config overlay. The OTP os_mon app
# (disksup, memsup, cpu_sup, os_sup) expects a host-ish file
# system; under the thin initramfs its probes crash fast enough
# to trip the supervisor's max-restart-intensity and bring the
# whole VM down. Disable them.
cat > /ramfs/usr/lib/hyperbeam/releases/0.0.1/sys.config <<'CFG'
[
    {prometheus, [
        {cowboy_instrumenter, [
            {duration_buckets,
                [0.001, 0.01, 0.1, 0.25, 0.5, 0.75, 1, 2, 4, 10, 30, 60]}
        ]}
    ]},
    {os_mon, [
        {start_disksup, false},
        {start_memsup,  false},
        {start_cpu_sup, false},
        {start_os_sup,  false}
    ]}
].
CFG

# Enforced LapEE config.
cp /opt/lapee-enforced.flat /ramfs/etc/lapee/lapee-enforced.flat

# LapEE-specific HB config.json. Loaded at boot via HB_CONFIG.
# Disables the hyperbuddy index-page render and narrows
# preloaded_devices to the ~30 the LapEE appliance uses.
cat > /ramfs/etc/lapee/lapee.json <<'JSON'
{
    "render_index_page": false,
    "preloaded_devices": [
        {"name": "apply@1.0",        "module": "dev_apply"},
        {"name": "arweave@2.9",      "module": "dev_arweave"},
        {"name": "auth-hook@1.0",    "module": "dev_auth_hook"},
        {"name": "b32-name@1.0",     "module": "dev_b32_name"},
        {"name": "blacklist@1.0",    "module": "dev_blacklist"},
        {"name": "cache@1.0",        "module": "dev_cache"},
        {"name": "compute@1.0",      "module": "dev_cu"},
        {"name": "cookie@1.0",       "module": "dev_codec_cookie"},
        {"name": "cron@1.0",         "module": "dev_cron"},
        {"name": "faff@1.0",         "module": "dev_faff"},
        {"name": "flat@1.0",         "module": "dev_codec_flat"},
        {"name": "gzip@1.0",         "module": "dev_gzip"},
        {"name": "hook@1.0",         "module": "dev_hook"},
        {"name": "httpsig@1.0",      "module": "dev_codec_httpsig"},
        {"name": "http-auth@1.0",    "module": "dev_codec_http_auth"},
        {"name": "json@1.0",         "module": "dev_codec_json"},
        {"name": "local-name@1.0",   "module": "dev_local_name"},
        {"name": "location@1.0",     "module": "dev_location"},
        {"name": "lookup@1.0",       "module": "dev_lookup"},
        {"name": "lua@5.3a",         "module": "dev_lua"},
        {"name": "manifest@1.0",     "module": "dev_manifest"},
        {"name": "message@1.0",      "module": "dev_message"},
        {"name": "meta@1.0",         "module": "dev_meta"},
        {"name": "p4@1.0",           "module": "dev_p4"},
        {"name": "relay@1.0",        "module": "dev_relay"},
        {"name": "router@1.0",       "module": "dev_router"},
        {"name": "scheduler@1.0",    "module": "dev_scheduler"},
        {"name": "simple-pay@1.0",   "module": "dev_simple_pay"},
        {"name": "stack@1.0",        "module": "dev_stack"},
        {"name": "structured@1.0",   "module": "dev_codec_structured"},
        {"name": "tpm2@2.0a",        "module": "dev_tpm2"}
    ]
}
JSON

# init.
cp /init-hb /ramfs/init
chmod +x /ramfs/init

du -sh /ramfs
SH

rm -rf /tmp/lapee-hb-ramfs && mkdir /tmp/lapee-hb-ramfs
docker cp lapee-hb-mini:/ramfs /tmp/lapee-hb-ramfs
docker rm -f lapee-hb-mini >/dev/null

# Kernel CONFIG_RD_ZSTD=y in our fragment, so we ship the .zst
# variant as the primary artefact (smaller, faster init), with a
# .gz fallback for backwards-compat with any legacy consumer.
cd /tmp/lapee-hb-ramfs/ramfs
mkdir -p "$LAPEE/work"
if command -v zstd >/dev/null 2>&1; then
    find . | cpio -o -H newc 2>/dev/null \
        | zstd -19 -T0 --ultra -q > "$LAPEE/work/initramfs-hb.cpio.zst"
    find . | cpio -o -H newc 2>/dev/null \
        | gzip -9 > "$LAPEE/work/initramfs-hb.cpio.gz"
    ls -lh "$LAPEE/work/initramfs-hb.cpio.zst" \
           "$LAPEE/work/initramfs-hb.cpio.gz"
else
    echo "zstd not installed on host; falling back to gzip -9" >&2
    find . | cpio -o -H newc 2>/dev/null \
        | gzip -9 > "$LAPEE/work/initramfs-hb.cpio.gz"
    ls -lh "$LAPEE/work/initramfs-hb.cpio.gz"
fi

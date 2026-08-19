#!/usr/bin/env bash
# Verify the mutually exclusive ordinary and Docker Buildroot outputs. With
# --boot, also boot the exact signed Docker disk on an x86_64 Linux KVM host.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CALLER_DIR=$PWD
BUILD_IMAGE=${BUILD_IMAGE:-lapee-build:local}
ORDINARY_VOLUME=${ORDINARY_VOLUME:-lapee-buildroot}
DOCKER_VOLUME=${DOCKER_VOLUME:-lapee-buildroot-docker}
ORDINARY_UKI=${ORDINARY_UKI:-$ROOT/build/images/lapee-runtime-no-tme.signed.efi}
ORDINARY_DISK=${ORDINARY_DISK:-$ROOT/build/images/lapee-runtime-no-tme-signed.img}
DOCKER_UKI=${DOCKER_UKI:-$ROOT/build/images/lapee-runtime-no-tme-docker.signed.efi}
DOCKER_DISK=${DOCKER_DISK:-$ROOT/build/images/lapee-runtime-no-tme-docker-signed.img}
BOOT=0
CHECK_KVM_HOST=0

usage() {
    cat <<'EOF'
Usage: scripts/verify-docker-profile.sh [options]

Options:
  --ordinary-volume NAME  Ordinary Buildroot volume.
  --docker-volume NAME    Docker Buildroot volume.
  --ordinary-uki PATH     Ordinary signed UKI.
  --ordinary-disk PATH    Ordinary signed disk image.
  --docker-uki PATH       Docker signed UKI.
  --docker-disk PATH      Docker signed disk image.
  --check-kvm-host        Check the mandatory x86_64 Linux KVM host.
  --boot                  Check the host and boot the exact Docker disk.
EOF
}

while (($#)); do
    case "$1" in
        --ordinary-volume) ORDINARY_VOLUME=${2:?}; shift 2 ;;
        --docker-volume) DOCKER_VOLUME=${2:?}; shift 2 ;;
        --ordinary-uki) ORDINARY_UKI=${2:?}; shift 2 ;;
        --ordinary-disk) ORDINARY_DISK=${2:?}; shift 2 ;;
        --docker-uki) DOCKER_UKI=${2:?}; shift 2 ;;
        --docker-disk) DOCKER_DISK=${2:?}; shift 2 ;;
        --check-kvm-host) CHECK_KVM_HOST=1; shift ;;
        --boot) CHECK_KVM_HOST=1; BOOT=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

absolute_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$CALLER_DIR" "$1" ;;
    esac
}
ORDINARY_UKI=$(absolute_path "$ORDINARY_UKI")
ORDINARY_DISK=$(absolute_path "$ORDINARY_DISK")
DOCKER_UKI=$(absolute_path "$DOCKER_UKI")
DOCKER_DISK=$(absolute_path "$DOCKER_DISK")

file_size() {
    stat -c %s "$1" 2>/dev/null || stat -f %z "$1"
}

check_kvm_host() {
    if [[ "$(uname -s)" != Linux ]]; then
        echo "Docker profile boot verification requires Linux x86_64 KVM; TCG is not accepted" >&2
        exit 1
    fi
    case "$(uname -m)" in
        x86_64|amd64) ;;
        *) echo "Docker profile boot verification requires x86_64 KVM; TCG is not accepted" >&2; exit 1 ;;
    esac
    [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] || {
        echo "Docker profile boot verification requires readable and writable /dev/kvm" >&2
        exit 1
    }
    for command in qemu-system-x86_64 swtpm curl; do
        command -v "$command" >/dev/null 2>&1 || {
            echo "Docker profile boot verification is missing $command" >&2
            exit 1
        }
    done
    echo ">> x86_64 Linux KVM host ready"
}

verify_volume() {
    local volume=$1 profile=$2
    docker volume inspect "$volume" >/dev/null
    docker run --rm \
        -v "$volume:/build:ro" \
        -e EXPECT_DOCKER="$profile" \
        "$BUILD_IMAGE" bash -euo pipefail -c '
            cfg=/build/out/.config
            target=/build/out/target
            kernel=$(find /build/out/build -maxdepth 2 -type f \
                -path "*/linux-*/.config" | LC_ALL=C sort | tail -n 1)
            test -s "$cfg" && test -s "$kernel"
            packages="CGROUPFS_V2_MOUNT CONTAINERD DOCKER_CLI DOCKER_ENGINE IPTABLES LIBSECCOMP RUNC TINI"
            paths="usr/bin/docker usr/bin/dockerd usr/bin/docker-proxy usr/bin/containerd usr/bin/containerd-shim-runc-v2 usr/bin/ctr usr/bin/runc usr/bin/tini usr/libexec/docker/docker-init"
            store=$target/usr/lib/hyperbeam/_build/preloaded-store/data.mdb
            if [[ "$EXPECT_DOCKER" == 1 ]]; then
                for package in $packages; do
                    grep -Eq "^BR2_PACKAGE_${package}=y$" "$cfg"
                done
                for path in $paths; do test -e "$target/$path"; done
                test -x "$target/etc/lapee/capabilities/runtime"
                grep -aFq "docker@1.0" "$store"
                for option in BLK_CGROUP BLK_DEV_THROTTLING BPF_SYSCALL \
                        BRIDGE BRIDGE_NETFILTER CFS_BANDWIDTH CGROUPS \
                        CGROUP_BPF CGROUP_CPUACCT CGROUP_DEVICE \
                        CGROUP_FREEZER CGROUP_PIDS CGROUP_SCHED CPUSETS \
                        FAIR_GROUP_SCHED IPC_NS IP_NF_FILTER \
                        IP_NF_IPTABLES IP_NF_IPTABLES_LEGACY IP_NF_NAT \
                        MEMCG NAMESPACES NETFILTER NETFILTER_XTABLES \
                        NETFILTER_XTABLES_LEGACY NET_NS \
                        NF_CONNTRACK NF_NAT OVERLAY_FS PID_NS SECCOMP \
                        SECCOMP_FILTER UTS_NS VETH; do
                    grep -Eq "^CONFIG_${option}=[ym]$" "$kernel"
                done
                ! grep -Eq "^CONFIG_KVM(_INTEL|_AMD)?=[ym]$" "$kernel"
            else
                for package in $packages; do
                    ! grep -Eq "^BR2_PACKAGE_${package}=y$" "$cfg"
                done
                ! grep -Eq \
                    "^BR2_PACKAGE_(CONTAINERD|DOCKER[^=]*|RUNC|TINI)=y$" \
                    "$cfg"
                for path in $paths; do test ! -e "$target/$path"; done
                ! find "$target" \( -iname "*docker*" -o -name containerd -o \
                    -name "containerd-shim*" -o -name runc -o -name tini \) \
                    -print -quit | grep -q .
                test ! -e "$target/etc/lapee/capabilities/runtime"
                ! grep -iq docker "$target/init"
                ! grep -aFq "docker@1.0" "$store"
            fi
            ! grep -E "^BR2_PACKAGE_QEMU[^=]*=y$" "$cfg" | \
                grep -Fvxq "BR2_PACKAGE_QEMU_ARCH_SUPPORTS_TARGET=y"
            test ! -e "$target/usr/bin/qemu-system-x86_64"
            test ! -e "$target/usr/bin/qemu-img"
            test ! -e "$target/usr/share/qemu"
            test ! -e "$target/usr/share/permawebos/tool-environments"
            ! find "$target" \( -iname "*qemu*" -o -iname "*.qcow2" -o \
                -iname "*toolbox*" -o -name "docker-image.tar" -o \
                -iname "*ouroboros*" \) -print -quit | grep -q .
            ! grep -aEq \
                "ouroboros(@1[.]0|-space@1[.]0)|lib_ouroboros" "$store"
        '
    echo ">> verified Buildroot volume $volume (Docker=$profile)"
}

dump_cmdline() {
    local uki=$1 output=$2
    if command -v objcopy >/dev/null 2>&1; then
        objcopy --dump-section ".cmdline=$output" "$uki" "$output.objcopy"
        rm -f "$output.objcopy"
        return
    fi
    local rel_uki rel_output
    case "$uki" in "$ROOT"/*) rel_uki=${uki#$ROOT/} ;; *) echo "UKI must be under $ROOT" >&2; exit 1 ;; esac
    case "$output" in "$ROOT"/*) rel_output=${output#$ROOT/} ;; *) echo "temporary output must be under $ROOT" >&2; exit 1 ;; esac
    docker run --rm -v "$ROOT:/work" "$BUILD_IMAGE" bash -euo pipefail -c '
        tool=$(command -v x86_64-w64-mingw32-objcopy || command -v objcopy)
        "$tool" --dump-section ".cmdline=/work/'"$rel_output"'" \
            "/work/'"$rel_uki"'" "/work/'"$rel_output"'.objcopy"
        rm -f "/work/'"$rel_output"'.objcopy"
    '
}

verify_production_disk() {
    local disk=$1 uki=$2
    docker run --rm \
        -v "$disk:/disk:ro" \
        -v "$uki:/signed-uki:ro" \
        "$BUILD_IMAGE" bash -euo pipefail -c '
            start_lba=$(parted --script --machine /disk unit s print \
                | awk -F: "/^1:/ {gsub(\"s\", \"\", \$2); print \$2}")
            test -n "$start_lba"
            offset=$((start_lba * 512))
            mcopy -i "/disk@@$offset" ::/EFI/Boot/BootX64.efi /tmp/BootX64.efi
            cmp /signed-uki /tmp/BootX64.efi
            if mdir -i "/disk@@$offset" ::/EFI/Boot/docker-image.tar \
                    >/dev/null 2>&1; then
                echo "production disk contains a fixture image" >&2
                exit 1
            fi
        '
    echo ">> verified production disk embeds the exact signed Docker UKI and no image"
}

verify_volume "$ORDINARY_VOLUME" 0
verify_volume "$DOCKER_VOLUME" 1

for artifact in "$ORDINARY_UKI" "$ORDINARY_DISK" "$DOCKER_UKI" "$DOCKER_DISK"; do
    [[ -f "$artifact" ]] || { echo "missing artifact: $artifact" >&2; exit 1; }
done
verify_production_disk "$ORDINARY_DISK" "$ORDINARY_UKI"
verify_production_disk "$DOCKER_DISK" "$DOCKER_UKI"

work=$(mktemp -d "$ROOT/build/docker-profile-verify.XXXXXX")
trap 'rm -rf "$work"' EXIT
dump_cmdline "$ORDINARY_UKI" "$work/ordinary.cmdline"
dump_cmdline "$DOCKER_UKI" "$work/docker.cmdline"
if grep -Fq 'lapee.docker=enabled' "$work/ordinary.cmdline"; then
    echo "ordinary signed UKI contains the Docker activation marker" >&2
    exit 1
fi
if [[ "$(grep -Fo 'lapee.docker=enabled' "$work/docker.cmdline" | wc -l | tr -d ' ')" != 1 ]]; then
    echo "Docker signed UKI must contain exactly one activation marker" >&2
    exit 1
fi

docker_bytes=$(file_size "$DOCKER_UKI")
disk_bytes=$(file_size "$DOCKER_DISK")
if ((docker_bytes >= 300 * 1024 * 1024)); then
    echo "Docker signed UKI exceeds 300 MiB: $docker_bytes bytes" >&2
    exit 1
fi
printf 'Docker signed UKI: %s bytes (%.3f MiB)\n' \
    "$docker_bytes" "$(awk -v bytes="$docker_bytes" 'BEGIN { print bytes / 1048576 }')"
printf 'Docker signed disk: %s bytes (%.3f MiB)\n' \
    "$disk_bytes" "$(awk -v bytes="$disk_bytes" 'BEGIN { print bytes / 1048576 }')"

if ((CHECK_KVM_HOST)); then
    check_kvm_host
fi
if ((BOOT)); then
    QEMU_ACCEL=kvm QEMU_CPU=host \
        LAPEE_BUILD_DIR="${LAPEE_BUILD_DIR:-$ROOT/build/qemu-docker-kvm}" \
        OUTDIR="${OUTDIR:-$ROOT/build/qemu-docker-kvm/results}" \
        "$ROOT/scripts/boot-usb-image.sh" --img "$DOCKER_DISK" \
            --timeout "${DOCKER_VERIFY_TIMEOUT:-1800}" \
            --host-port "${DOCKER_VERIFY_HOST_PORT:-29734}"
fi

echo ">> Docker profile verification passed"

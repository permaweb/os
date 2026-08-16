#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

RUN_CASES=()

usage() {
    cat <<'EOF'
usage: scripts/smoke.sh --list
       scripts/smoke.sh full|linux|android|mixed|provisioner|remote-snp|CASE...

Suites:
  full        local complete PermawebOS smoke suite
  linux       Linux LapEE/SNP-local QEMU suite
  android     Android AndEE suite for the active adb device/emulator
  mixed       cross-architecture AndEE + QEMU suite
  provisioner Secure Boot provisioner QEMU suite
  remote-snp  remote SNP zone suite; requires TARGET=ssh://...
EOF
}

suite_cases() {
    case "$1" in
        full)
            printf '%s\n' linux android mixed provisioner
            ;;
        linux)
            printf '%s\n' \
                linux-config \
                linux-qemu-zone \
                linux-qemu-zone-nonvolatile \
                linux-qemu-operator-config
            ;;
        android)
            printf '%s\n' \
                android-check \
                android-config \
                android-build \
                android-smoke \
                android-andock-device \
                android-scenarios
            ;;
        mixed)
            printf '%s\n' mixed-andee-qemu-ring
            ;;
        provisioner)
            printf '%s\n' provisioner-qemu-nonvolatile
            ;;
        remote-snp)
            printf '%s\n' linux-qemu-zone-remote-snp
            ;;
        *)
            return 1
            ;;
    esac
}

list_cases() {
    cat <<'EOF'
Suites:
  full
  linux
  android
  mixed
  provisioner
  remote-snp

Cases:
  linux-config
  linux-qemu-zone
  linux-qemu-zone-nonvolatile
  linux-qemu-operator-config
  linux-qemu-zone-remote-snp
  provisioner-qemu-nonvolatile
  android-check
  android-config
  android-build
  android-smoke
  android-andock-device
  android-next-boot-config
  android-zone-storage
  android-host-zone-storage
  android-scenarios
  mixed-andee-qemu-ring
EOF
}

case_seen() {
    local candidate=$1 existing
    for existing in "${RUN_CASES[@]:-}"; do
        [[ "$existing" = "$candidate" ]] && return 0
    done
    return 1
}

add_target() {
    local target=$1 expanded
    if expanded=$(suite_cases "$target"); then
        local item
        for item in $expanded; do
            add_target "$item"
        done
    else
        case_seen "$target" || RUN_CASES+=("$target")
    fi
}

run_case() {
    local name=$1
    echo ""
    echo "=== smoke: $name ==="
    case "$name" in
        linux-config)
            ./scripts/check-lapee-config-invariants.py
            ;;
        linux-qemu-zone)
            make qemu-zone
            ;;
        linux-qemu-zone-nonvolatile)
            make qemu-zone-nonvolatile
            ;;
        linux-qemu-operator-config)
            make qemu-operator-config
            ;;
        linux-qemu-zone-remote-snp)
            make qemu-zone-remote-snp
            ;;
        provisioner-qemu-nonvolatile)
            make qemu-provisioner-nonvolatile
            ;;
        android-check)
            make -C arch/android android-check
            ;;
        android-config)
            make -C arch/android verify-config-invariants
            ;;
        android-build)
            make -C arch/android android-build
            ;;
        android-smoke)
            arch/android/scripts/andee-smoke.sh
            ;;
        android-andock-device)
            arch/android/scripts/andock-device-route-smoke.sh
            ;;
        android-next-boot-config)
            arch/android/scripts/andee-next-boot-config-test.sh
            ;;
        android-zone-storage)
            arch/android/scripts/andee-android-zone-storage-smoke.sh
            ;;
        android-host-zone-storage)
            arch/android/scripts/andee-zone-storage-scenario.sh
            ;;
        android-scenarios)
            arch/android/scripts/andee-scenarios.sh
            ;;
        mixed-andee-qemu-ring)
            ./scripts/andee-qemu-ring-smoke.sh
            ;;
        *)
            echo "unknown smoke case or suite: $name" >&2
            usage >&2
            return 2
            ;;
    esac
    echo "=== smoke: $name PASSED ==="
}

if [[ "${1:-}" = "--list" ]]; then
    list_cases
    exit 0
fi

if [[ $# -eq 0 ]]; then
    usage >&2
    exit 2
fi

for target in "$@"; do
    add_target "$target"
done

for name in "${RUN_CASES[@]}"; do
    run_case "$name"
done

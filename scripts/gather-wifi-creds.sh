#!/usr/bin/env bash
# Prompt locally for WiFi credentials and write the ESP wifi.conf file.
#
# The file format is intentionally the same strict two-line format that
# init accepts from /EFI/boot/wifi.conf:
#   SSID
#   WPA2-PSK
#
# The PSK is never echoed. On macOS, when stdin is not a terminal, this
# falls back to GUI prompts so `make runtime-write' can still gather the
# secret without putting it in chat, shell history, or Make arguments.

set -euo pipefail
cd "$(dirname "$0")/.."

OUT="wifi.conf"
MODE="prompt"

usage() {
    cat <<'EOF'
Usage: scripts/gather-wifi-creds.sh [--if-missing] [--force] [--output PATH]

Writes PATH, default wifi.conf, with exactly two lines:
  SSID
  WPA2-PSK

Options:
  --if-missing  Reuse an existing valid file; prompt only if absent/invalid.
  --force       Prompt and replace even if the file already exists.
  --output      Override the output path.
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

while (($# > 0)); do
    case "$1" in
        --if-missing) MODE="if_missing"; shift ;;
        --force)      MODE="force"; shift ;;
        --output)     OUT="$2"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *)            die "unknown argument: $1" ;;
    esac
done

validate_creds() {
    local ssid="$1"
    local psk="$2"

    [[ "$ssid" != *$'\n'* && "$ssid" != *$'\r'* ]] || \
        { echo "error: SSID must be a single line" >&2; return 1; }
    [[ "$psk" != *$'\n'* && "$psk" != *$'\r'* ]] || \
        { echo "error: PSK must be a single line" >&2; return 1; }

    (( ${#ssid} >= 1 && ${#ssid} <= 32 )) || \
        { echo "error: SSID length must be 1..32 bytes" >&2; return 1; }
    case "$ssid" in
        *[!a-zA-Z0-9_\ .-]*)
            echo "error: SSID may contain only letters, digits, underscore, space, dot, and dash" >&2
            return 1
            ;;
    esac

    (( ${#psk} >= 8 && ${#psk} <= 63 )) || \
        { echo "error: PSK length must be 8..63 bytes" >&2; return 1; }
    if ! LC_ALL=C grep -q '^[ -~]\{8,63\}$' <<<"$psk"; then
        echo "error: PSK must contain only printable ASCII characters" >&2
        return 1
    fi
    case "$psk" in
        *\"*|*\\*|*\$*|*\`*)
            echo 'error: PSK may not contain ", \, $, or `' >&2
            return 1
            ;;
    esac
}

read_existing() {
    local file="$1"
    local ssid psk third

    [[ -f "$file" ]] || return 1
    IFS= read -r ssid < "$file" || return 1
    psk="$(sed -n '2p' "$file" | tr -d '\r')"
    third="$(sed -n '3p' "$file" | tr -d '\r')"
    ssid="$(printf '%s' "$ssid" | tr -d '\r')"
    [[ -z "$third" ]] || return 1
    validate_creds "$ssid" "$psk" >/dev/null 2>&1
}

prompt_macos() {
    local prompt="$1"
    local hidden="${2:-0}"

    if [[ "$hidden" = "1" ]]; then
        osascript -e "text returned of (display dialog \"$prompt\" default answer \"\" buttons {\"Cancel\", \"OK\"} default button \"OK\" with hidden answer)"
    else
        osascript -e "text returned of (display dialog \"$prompt\" default answer \"\" buttons {\"Cancel\", \"OK\"} default button \"OK\")"
    fi
}

prompt_creds() {
    local ssid psk

    if [[ -t 0 ]]; then
        printf 'WiFi SSID: ' >&2
        IFS= read -r ssid
        printf 'WiFi PSK (hidden): ' >&2
        IFS= read -r -s psk
        printf '\n' >&2
    elif [[ -p /dev/stdin ]]; then
        IFS= read -r ssid || die "missing SSID on stdin"
        IFS= read -r psk || die "missing PSK on stdin"
    elif [[ "$(uname -s)" = "Darwin" ]] && command -v osascript >/dev/null 2>&1; then
        ssid="$(prompt_macos 'LapEE WiFi SSID')"
        psk="$(prompt_macos 'LapEE WiFi password' 1)"
    else
        die "stdin is not a terminal; run this target interactively or create wifi.conf manually"
    fi

    validate_creds "$ssid" "$psk" || exit 1

    local dir tmp
    dir="$(dirname "$OUT")"
    mkdir -p "$dir"
    tmp="$(mktemp "${dir}/.wifi.conf.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    chmod 600 "$tmp"
    printf '%s\n%s\n' "$ssid" "$psk" > "$tmp"
    mv "$tmp" "$OUT"
    chmod 600 "$OUT"
    trap - EXIT

    echo ">> wrote $OUT (ssid len=${#ssid}, PSK len=${#psk}; values not printed)"
}

if [[ "$MODE" = "if_missing" && -f "$OUT" ]]; then
    if read_existing "$OUT"; then
        echo ">> using existing $OUT (values not printed)"
        exit 0
    fi
    echo ">> existing $OUT is absent or invalid; gathering new credentials" >&2
fi

prompt_creds

#!/usr/bin/env bash
# Render local ANSI/text previews from lapee_splash:render/1.

set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
    cat <<'EOF'
Usage: scripts/render-splash-previews.sh

Environment overrides:
  OUTDIR=build/splash-previews/<label> Output directory
  DIMS="160x50 128x48"                 Terminal sizes to render
  LAYOUTS="qr max deck sigil blue orbit matrix plaque classic"
                                       Splash layouts to render
  STATES="ready hb-wait"               Splash phases to render
  IP=10.0.2.15                         IP shown in status/url text
  FRAME=96                             Animation frame used for previews
  YAW=1.15                             Laptop yaw in radians
  LID=1.85                             Laptop lid angle in radians
  HB_WAIT_SECONDS=17                   Elapsed seconds for hb-wait previews

Writes:
  <layout>-<state>-<cols>x<rows>.ansi  Raw ANSI frame
  <layout>-<state>-<cols>x<rows>.txt   Plain text frame
EOF
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    "")
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

SRC="buildroot-external/board/lapee/files/lapee_splash.erl"
if [ ! -f "$SRC" ]; then
    echo "error: missing $SRC" >&2
    exit 1
fi

command -v erlc >/dev/null 2>&1 || {
    echo "error: erlc not found in PATH" >&2
    exit 1
}
command -v erl >/dev/null 2>&1 || {
    echo "error: erl not found in PATH" >&2
    exit 1
}

timestamp="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${OUTDIR:-build/splash-previews/$timestamp}"
DIMS="${DIMS:-160x50}"
LAYOUTS="${LAYOUTS:-qr max deck sigil blue orbit matrix plaque classic}"
STATES="${STATES:-ready hb-wait}"
IP="${IP:-10.0.2.15}"
FRAME="${FRAME:-96}"
YAW="${YAW:-1.15}"
LID="${LID:-1.85}"
HB_WAIT_SECONDS="${HB_WAIT_SECONDS:-17}"

mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/lapee-splash-preview.XXXXXX")"
cleanup() {
    rm -rf "$tmpdir"
}
trap cleanup EXIT

erlc +export_all -o "$tmpdir" "$SRC"

render_one() {
    local layout="$1"
    local state="$2"
    local dims="$3"

    case "$dims" in
        *x*) ;;
        *)
            echo "error: invalid dimension '$dims' (expected COLSxROWS)" >&2
            exit 2
            ;;
    esac
    local cols="${dims%x*}"
    local rows="${dims#*x}"

    case "$cols:$rows" in
        *[!0-9:]*|":"|:*|*:)
            echo "error: invalid dimension '$dims' (expected COLSxROWS)" >&2
            exit 2
            ;;
    esac
    case "$layout:$state" in
        *[!A-Za-z0-9_:-]*|:*|*:)
            echo "error: invalid layout/state '$layout/$state'" >&2
            exit 2
            ;;
    esac

    local stem="${layout}-${state}-${cols}x${rows}"
    local ansi="$OUTDIR/$stem.ansi"
    local text="$OUTDIR/$stem.txt"

    PREVIEW_LAYOUT="$layout" \
    PREVIEW_STATE="$state" \
    PREVIEW_COLS="$cols" \
    PREVIEW_ROWS="$rows" \
    PREVIEW_IP="$IP" \
    PREVIEW_FRAME="$FRAME" \
    PREVIEW_YAW="$YAW" \
    PREVIEW_LID="$LID" \
    PREVIEW_HB_WAIT_SECONDS="$HB_WAIT_SECONDS" \
    PREVIEW_OUT="$ansi" \
    erl -noshell -pa "$tmpdir" -eval '
        Int = fun(Name) ->
            list_to_integer(os:getenv(Name))
        end,
        Float = fun(Name) ->
            Str = os:getenv(Name),
            try list_to_float(Str)
            catch _:_ -> float(list_to_integer(Str))
            end
        end,
        Atom = fun
            ("hb-wait") -> '\''hb-wait'\'';
            ("net-up") -> '\''net-up'\'';
            ("ready") -> ready;
            ("boot") -> boot;
            (Other) -> list_to_atom(Other)
        end,
        Layout = Atom(os:getenv("PREVIEW_LAYOUT")),
        Phase = Atom(os:getenv("PREVIEW_STATE")),
        HbWaitSecs = Int("PREVIEW_HB_WAIT_SECONDS"),
        HbT0 = case Phase of
            '\''hb-wait'\'' ->
                erlang:monotonic_time(millisecond) - HbWaitSecs * 1000;
            _ ->
                undefined
        end,
        State = #{
            cols => Int("PREVIEW_COLS"),
            rows => Int("PREVIEW_ROWS"),
            layout => Layout,
            frame => Int("PREVIEW_FRAME"),
            yaw => Float("PREVIEW_YAW"),
            lid => Float("PREVIEW_LID"),
            phase => Phase,
            status => undefined,
            ip => os:getenv("PREVIEW_IP"),
            hb_wait_t0 => HbT0
        },
        ok = file:write_file(os:getenv("PREVIEW_OUT"),
                             iolist_to_binary(lapee_splash:render(State))),
        halt(0).
    ' >/dev/null

    perl -pe 's/\e\]P[0-9A-Fa-f][0-9A-Fa-f]{6}//g; s/\e\[[0-9;?]*[[:alpha:]]//g; s/\r//g' "$ansi" > "$text"
    printf '%s\n' "$ansi"
    printf '%s\n' "$text"
}

for dims in $DIMS; do
    for layout in $LAYOUTS; do
        for state in $STATES; do
            render_one "$layout" "$state" "$dims"
        done
    done
done

echo "Rendered splash previews under $OUTDIR"

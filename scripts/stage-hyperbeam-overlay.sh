#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 /path/to/hyperbeam-checkout" >&2
    exit 2
fi

repo=$1
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
overlay=${LAPEE_HB_OVERLAY_DIR:-$root_dir/hyperbeam-overlay}

if [ ! -f "$repo/rebar.config" ]; then
    echo "not a HyperBEAM checkout: $repo" >&2
    exit 2
fi
if [ ! -f "$overlay/rebar.lapee.fragment" ]; then
    echo "missing LapEE HyperBEAM overlay: $overlay" >&2
    exit 2
fi

echo ">> staging LapEE HyperBEAM overlay from $overlay"

mkdir -p "$repo/src" "$repo/native" "$repo/priv"

find "$overlay/src" -type f | while IFS= read -r src; do
    rel=${src#"$overlay/src/"}
    rm -f "$repo/src/$rel"
done
# Remove overlay-owned files whose names changed across LapEE iterations.
rm -f "$repo/src/dev_system_probe.erl"
rm -rf "$repo/native/lapee_tpm_nif" \
       "$repo/priv/tpm-interpret"

cp -R "$overlay/src/." "$repo/src/"
cp -R "$overlay/native/." "$repo/native/"
cp -R "$overlay/priv/." "$repo/priv/"

python3 - "$repo/rebar.config" "$overlay/rebar.lapee.fragment" <<'PY'
import pathlib
import re
import sys

config_path = pathlib.Path(sys.argv[1])
fragment_path = pathlib.Path(sys.argv[2])
text = config_path.read_text()
fragment = fragment_path.read_text().strip()

begin = "%% BEGIN LAPEE OVERLAY PROFILE"
end = "%% END LAPEE OVERLAY PROFILE"

text = re.sub(
    r"\n\s*,?\s*%% BEGIN LAPEE OVERLAY PROFILE\n.*?\n\s*%% END LAPEE OVERLAY PROFILE",
    "",
    text,
    flags=re.S,
)

profiles = text.find("{profiles, [")
if profiles < 0:
    raise SystemExit("rebar.config has no {profiles, [...]} term")

list_start = text.find("[", profiles)
if list_start < 0:
    raise SystemExit("could not find profiles list start")

depth = 0
in_string = False
in_atom = False
escape = False
comment = False

for i in range(list_start, len(text)):
    ch = text[i]
    if comment:
        if ch == "\n":
            comment = False
        continue
    if in_string:
        if escape:
            escape = False
        elif ch == "\\":
            escape = True
        elif ch == '"':
            in_string = False
        continue
    if in_atom:
        if escape:
            escape = False
        elif ch == "\\":
            escape = True
        elif ch == "'":
            in_atom = False
        continue
    if ch == "%":
        comment = True
        continue
    if ch == '"':
        in_string = True
        continue
    if ch == "'":
        in_atom = True
        continue
    if ch == "[":
        depth += 1
    elif ch == "]":
        depth -= 1
        if depth == 0:
            insertion = f",\n    {begin}\n    {fragment}\n    {end}\n"
            text = text[:i] + insertion + text[i:]
            config_path.write_text(text)
            break
else:
    raise SystemExit("could not find profiles list end")
PY

echo ">> LapEE HyperBEAM overlay staged"

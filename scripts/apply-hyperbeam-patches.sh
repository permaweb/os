#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 /path/to/hyperbeam-checkout" >&2
    exit 2
fi

repo=$1
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
patch_dir="$root_dir/buildroot-external/package/hyperbeam"

if [ ! -f "$repo/rebar.config" ]; then
    echo "not a HyperBEAM checkout: $repo" >&2
    exit 2
fi

for patch in "$patch_dir"/[0-9][0-9][0-9][0-9]-*.patch; do
    [ -e "$patch" ] || continue
    name=$(basename "$patch")
    if git -C "$repo" apply --unidiff-zero --check "$patch" >/dev/null 2>&1; then
        echo ">> applying HyperBEAM patch: $name"
        git -C "$repo" apply --unidiff-zero "$patch"
    elif git -C "$repo" apply --unidiff-zero --reverse --check "$patch" >/dev/null 2>&1; then
        echo ">> HyperBEAM patch already applied: $name"
    else
        echo "could not apply HyperBEAM patch: $name" >&2
        exit 1
    fi
done

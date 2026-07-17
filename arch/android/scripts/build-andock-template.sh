#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

UBUNTU_IMAGE='ubuntu@sha256:c4a8d5503dfb2a3eb8ab5f807da5bc69a85730fb49b5cfca2330194ebcc41c7b'
UBUNTU_SNAPSHOT=20260714T000000Z
NODE_VERSION=22.23.1
NODE_SHA256=0294e8b915ab75f92c7513d2fcb830ae06e10684e6c603e99a87dbf8835389c1
PERMAGIT_VERSION=0.11.3
PERMAGIT_RELEASE_TX=3ZMqhXLCDdFePXjdikVutXzqU2zoDx4Ma4APd-F-j_E
PERMAGIT_SHA256=6cc1763c3af3072e102ef0d09aaba29fe8c6dd996329d1050c0491dec73d7854
PERMAGIT_PACKAGE_LOCK_SHA256=968ddaffdc52c3931d278a08a7ede83b3ef0566ef1ebf3b47ed1d34a0d44847c
PROVISION_REVISION=andock-ubuntu-ext4-1
SOURCE_DATE_EPOCH=1735689600
IMAGE_UUID=4b7e4af2-25cd-4ae5-a14d-8f8628b88f5d

OUTPUT="${1:-$BUILD_DIR/andock-template/andock-ubuntu-arm64.ext4}"
OUTPUT_PARENT="$(dirname "$OUTPUT")"
mkdir -p "$OUTPUT_PARENT"
OUTPUT_DIR="$(cd "$OUTPUT_PARENT" && pwd)"
OUTPUT_BASENAME="$(basename "$OUTPUT")"
DOWNLOADS="$BUILD_DIR/downloads"
PACKAGE_LOCK="$ROOT/execution/andock-ubuntu-packages.lock"
PROVISIONER="$ROOT/execution/andock-provision-base.sh"
INNER_BUILDER="$ROOT/scripts/andock-build-template-inner.sh"
INVENTORY="$ROOT/scripts/andock-metadata-inventory.py"
XATTR_REPLAYER="$ROOT/scripts/andock-replay-xattrs.py"
SPARSE_CONVERTER="$ROOT/scripts/andock-android-sparse.py"
NODE_ARCHIVE="$DOWNLOADS/node-v$NODE_VERSION-linux-arm64.tar.xz"
PERMAGIT_ARCHIVE="$DOWNLOADS/permagit-$PERMAGIT_VERSION.tar.gz"

if [[ ! "$OUTPUT_BASENAME" =~ ^[a-zA-Z0-9._-]+\.ext4$ ]]; then
    printf 'unsafe output basename: %s\n' "$OUTPUT_BASENAME" >&2
    exit 1
fi
for tool in curl docker python3 shasum stat; do
    require_tool "$tool"
done

sha256_file() {
    shasum -a 256 "$1" | awk '{print $1}'
}

mkdir -p "$DOWNLOADS"
if [[ ! -f "$NODE_ARCHIVE" ]] || \
        [[ "$(sha256_file "$NODE_ARCHIVE")" != "$NODE_SHA256" ]]; then
    curl --fail --location --retry 3 --output "$NODE_ARCHIVE" \
        "https://nodejs.org/download/release/v$NODE_VERSION/node-v$NODE_VERSION-linux-arm64.tar.xz"
fi
if [[ ! -f "$PERMAGIT_ARCHIVE" ]] || \
        [[ "$(sha256_file "$PERMAGIT_ARCHIVE")" != "$PERMAGIT_SHA256" ]]; then
    curl --fail --location --retry 3 --output "$PERMAGIT_ARCHIVE" \
        "https://arweave.net/$PERMAGIT_RELEASE_TX"
fi
printf '%s  %s\n' "$NODE_SHA256" "$NODE_ARCHIVE" | shasum -a 256 -c -
printf '%s  %s\n' "$PERMAGIT_SHA256" "$PERMAGIT_ARCHIVE" | shasum -a 256 -c -

PACKAGE_LOCK_SHA256="$(sha256_file "$PACKAGE_LOCK")"
PROVISIONER_SHA256="$(sha256_file "$PROVISIONER")"
TEMPLATE_BUILDER_SHA256="$(sha256_file "$INNER_BUILDER")"
INVENTORY_SCRIPT_SHA256="$(sha256_file "$INVENTORY")"
XATTR_REPLAYER_SHA256="$(sha256_file "$XATTR_REPLAYER")"
SPARSE_CONVERTER_SHA256="$(sha256_file "$SPARSE_CONVERTER")"
TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
CONTAINER="andock-template-$TOKEN"

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker create \
    --platform linux/arm64 --privileged --name "$CONTAINER" \
    --mount "type=bind,src=$OUTPUT_DIR,dst=/output" \
    "$UBUNTU_IMAGE" sleep infinity >/dev/null
docker start "$CONTAINER" >/dev/null
docker cp "$PACKAGE_LOCK" "$CONTAINER:/tmp/andock-packages.lock"
docker cp "$PROVISIONER" "$CONTAINER:/tmp/andock-provision-base"
docker cp "$INNER_BUILDER" "$CONTAINER:/tmp/andock-build-template-inner"
docker cp "$INVENTORY" "$CONTAINER:/tmp/andock-metadata-inventory.py"
docker cp "$XATTR_REPLAYER" "$CONTAINER:/tmp/andock-replay-xattrs.py"
docker cp "$SPARSE_CONVERTER" "$CONTAINER:/tmp/andock-android-sparse.py"
docker cp "$NODE_ARCHIVE" "$CONTAINER:/tmp/node.tar.xz"
docker cp "$PERMAGIT_ARCHIVE" "$CONTAINER:/tmp/permagit.tar.gz"

docker exec \
    --env ANDEE_UBUNTU_SNAPSHOT="$UBUNTU_SNAPSHOT" \
    --env ANDEE_NODE_ARCHIVE=/tmp/node.tar.xz \
    --env ANDEE_PERMAGIT_ARCHIVE=/tmp/permagit.tar.gz \
    --env ANDEE_PERMAGIT_PACKAGE_LOCK_SHA256="$PERMAGIT_PACKAGE_LOCK_SHA256" \
    --env ANDEE_PACKAGE_LOCK=/tmp/andock-packages.lock \
    "$CONTAINER" bash /tmp/andock-provision-base

docker exec \
    --env ANDEE_OUTPUT_BASENAME="$OUTPUT_BASENAME" \
    --env ANDEE_SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    --env ANDEE_IMAGE_UUID="$IMAGE_UUID" \
    --env ANDEE_UBUNTU_IMAGE="$UBUNTU_IMAGE" \
    --env ANDEE_UBUNTU_SNAPSHOT="$UBUNTU_SNAPSHOT" \
    --env ANDEE_NODE_VERSION="$NODE_VERSION" \
    --env ANDEE_NODE_SHA256="$NODE_SHA256" \
    --env ANDEE_PERMAGIT_VERSION="$PERMAGIT_VERSION" \
    --env ANDEE_PERMAGIT_SHA256="$PERMAGIT_SHA256" \
    --env ANDEE_PROVISION_REVISION="$PROVISION_REVISION" \
    --env ANDEE_PACKAGE_LOCK_SHA256="$PACKAGE_LOCK_SHA256" \
    --env ANDEE_PROVISIONER_SHA256="$PROVISIONER_SHA256" \
    --env ANDEE_TEMPLATE_BUILDER_SHA256="$TEMPLATE_BUILDER_SHA256" \
    --env ANDEE_INVENTORY_SCRIPT_SHA256="$INVENTORY_SCRIPT_SHA256" \
    --env ANDEE_XATTR_REPLAYER_SHA256="$XATTR_REPLAYER_SHA256" \
    --env ANDEE_SPARSE_CONVERTER_SHA256="$SPARSE_CONVERTER_SHA256" \
    "$CONTAINER" bash /tmp/andock-build-template-inner

if [[ "$(stat -f %z "$OUTPUT")" != 8589934592 ]]; then
    printf 'unexpected output size: %s\n' "$(stat -f %z "$OUTPUT")" >&2
    exit 1
fi
HOST_BLOCKS="$(stat -f %b "$OUTPUT")"
printf 'template=%s\n' "$OUTPUT"
printf 'template-sha256=%s\n' "$(sha256_file "$OUTPUT")"
printf 'template-logical-bytes=%s\n' "$(stat -f %z "$OUTPUT")"
printf 'template-allocated-bytes-on-host=%s\n' "$((HOST_BLOCKS * 512))"
printf 'android-sparse-image=%s\n' "$OUTPUT.simg"
printf 'android-sparse-image-sha256=%s\n' \
    "$(sha256_file "$OUTPUT.simg")"
printf 'android-sparse-image-bytes=%s\n' \
    "$(stat -f %z "$OUTPUT.simg")"

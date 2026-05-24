#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

KEYSTORE="$ROOT/android/handee-release.local.keystore"

require_tool keytool

if [ -f "$KEYSTORE" ]; then
    echo "release keystore exists: $KEYSTORE"
    exit 0
fi

keytool -genkeypair \
    -keystore "$KEYSTORE" \
    -storepass handee-local \
    -keypass handee-local \
    -alias handee-local \
    -keyalg EC \
    -groupname secp256r1 \
    -validity 3650 \
    -dname "CN=HandEE Local Release,O=Permaweb,C=US"

echo "created local release keystore: $KEYSTORE"

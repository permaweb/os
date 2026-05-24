#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

KEYSTORE="$ROOT/android/andee-release.local.keystore"

require_tool keytool

if [ -f "$KEYSTORE" ]; then
    echo "release keystore exists: $KEYSTORE"
    exit 0
fi

keytool -genkeypair \
    -keystore "$KEYSTORE" \
    -storepass andee-local \
    -keypass andee-local \
    -alias andee-local \
    -keyalg EC \
    -groupname secp256r1 \
    -validity 3650 \
    -dname "CN=AndEE Local Release,O=Permaweb,C=US"

echo "created local release keystore: $KEYSTORE"

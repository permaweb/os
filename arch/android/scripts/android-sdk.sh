#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

yes | sdkmanager --licenses >/dev/null || true
sdkmanager \
    "platform-tools" \
    "platforms;android-36" \
    "build-tools;37.0.0" \
    "emulator" \
    "system-images;android-36.1;google_apis;arm64-v8a"

if ! emulator -list-avds | grep -qx "${AVD_NAME:-handee-api-36-arm64}"; then
    echo "creating AVD ${AVD_NAME:-handee-api-36-arm64}"
    avdmanager create avd \
        --force \
        --name "${AVD_NAME:-handee-api-36-arm64}" \
        --package "system-images;android-36.1;google_apis;arm64-v8a" \
        --device "pixel_9"
fi

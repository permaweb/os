#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

require_tool java
require_tool sdkmanager
require_tool adb
require_tool emulator

java -version
sdkmanager --list_installed | sed -n '1,80p'
emulator -list-avds || true

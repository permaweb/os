#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

cd "$ROOT/android"
gradle wrapper --gradle-version 9.5.1 --distribution-type bin

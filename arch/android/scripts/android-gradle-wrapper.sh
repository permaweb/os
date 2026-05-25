#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

cd "$ROOT/android"
gradle wrapper \
    --gradle-version 9.5.1 \
    --distribution-type bin \
    --gradle-distribution-sha256-sum \
        bafc141b619ad6350fd975fc903156dd5c151998cc8b058e8c1044ab5f7b031f

#!/usr/bin/env bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
arch=$(uname -m)
output="${KAKI_NATIVE_OUTPUT_DIR:-$project_root/dist/native-$arch}"
bash "$project_root/scripts/build-macos-native.sh"
/usr/bin/open -a "$output/Kaki Tools.app"

#!/usr/bin/env bash
set -euo pipefail

# Build the tiny native event bridge with system frameworks only. It has no
# npm/native-addon ABI dependency, so one executable works for each Electron
# patch update on this Mac. Architecture follows the host (arm64 / x86_64).
project_root=$(cd "$(dirname "$0")/.." && pwd)
source_file="$project_root/native/kaki-fast-paste.m"
output_dir="$project_root/native/bin"
output_file="$output_dir/kaki-fast-paste"
arch=$(uname -m)

mkdir -p "$output_dir"
/usr/bin/clang -O2 -Wall -Wextra -Werror -fobjc-arc -arch "$arch" \
  -framework AppKit -framework ApplicationServices -framework Carbon \
  "$source_file" -o "$output_file"
/bin/chmod 755 "$output_file"

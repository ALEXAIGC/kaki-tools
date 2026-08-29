#!/usr/bin/env bash
set -euo pipefail

# Build the tiny native event bridge with system frameworks only. It has no
# npm/native-addon ABI dependency, so one arm64 executable works for each
# Electron patch update on this Mac.
project_root=$(cd "$(dirname "$0")/.." && pwd)
source_file="$project_root/native/kaki-fast-paste.m"
output_dir="$project_root/native/bin"
output_file="$output_dir/kaki-fast-paste"

mkdir -p "$output_dir"
/usr/bin/clang -O2 -Wall -Wextra -Werror -fobjc-arc -arch arm64 \
  -framework AppKit -framework ApplicationServices -framework Carbon \
  "$source_file" -o "$output_file"
/bin/chmod 755 "$output_file"

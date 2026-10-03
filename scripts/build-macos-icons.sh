#!/usr/bin/env bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
stage=$(mktemp -d "${TMPDIR:-/tmp}/kaki-native-icons.XXXXXX")
trap 'rm -rf "$stage"' EXIT
output="${KAKI_ICON_PREVIEW_DIR:-$project_root/dist/native-icons}"
mkdir -p "$output"
xcrun --sdk macosx swiftc -swift-version 5 -O -module-cache-path "$stage/cache" -framework AppKit \
  "$project_root/macos/Sources/NativeBrand.swift" "$project_root/scripts/render-native-icons.swift" -o "$stage/render-icons"
"$stage/render-icons" "$stage"
/usr/bin/iconutil -c icns "$stage/Kaki Tools.iconset" -o "$project_root/macos/Resources/icon.icns"
cp "$stage"/*-preview.png "$stage"/menu-icon-*.png "$output/"
echo "原生图标已生成，预览：$output"

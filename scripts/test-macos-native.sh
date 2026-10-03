#!/usr/bin/env bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
stage=$(mktemp -d "${TMPDIR:-/tmp}/kaki-native-tests.XXXXXX")
trap 'rm -rf "$stage"' EXIT
sources=()
for file in "$project_root"/macos/Sources/*.swift; do
  case "$file" in */Main.swift) ;; *) sources+=("$file") ;; esac
done
xcrun --sdk macosx swiftc -swift-version 5 -warnings-as-errors -target "$(uname -m)-apple-macosx13.0" -module-cache-path "$stage/cache" \
  -framework AppKit -framework SwiftUI -framework Carbon -framework ApplicationServices -framework ImageIO -framework CryptoKit -framework ServiceManagement \
  -framework AVKit \
  "${sources[@]}" "$project_root"/macos/Tests/*.swift -o "$stage/tests"
"$stage/tests"

#!/usr/bin/env bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
arch=$(uname -m)
output="${KAKI_NATIVE_OUTPUT_DIR:-$project_root/dist/native-$arch}"
# Pin the local certificate by its public fingerprint; never silently fall back to ad-hoc.
identity="${KAKI_NATIVE_IDENTITY:-}"
if [ -z "$identity" ]; then
  pin="$project_root/macos/Signing/local-certificate.sha1"
  [ -f "$pin" ] || { echo '缺少固定签名配置。请先准备签名身份，或显式设置 KAKI_NATIVE_IDENTITY。' >&2; exit 1; }
  identity=$(tr -d '[:space:]' < "$pin")
  [[ "$identity" =~ ^[A-Fa-f0-9]{40}$ ]] || { echo '固定签名指纹格式无效。' >&2; exit 1; }
fi
if [ "$identity" != '-' ]; then
  /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -F -- "$identity" >/dev/null || {
    echo '所需签名身份不可用。请恢复原证书及私钥；构建不会改用临时签名。' >&2; exit 1;
  }
fi
mkdir -p "$output"
stage=$(mktemp -d "$output/.native-stage.XXXXXX")
module_cache=$(mktemp -d "${TMPDIR:-/tmp}/kaki-swift-cache.XXXXXX")
trap 'rm -rf "$stage" "$module_cache"' EXIT
app="$stage/Kaki Tools.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun --sdk macosx swiftc -swift-version 5 -O -whole-module-optimization \
  -target "$arch-apple-macosx13.0" -module-cache-path "$module_cache" \
  -framework AppKit -framework SwiftUI -framework Carbon -framework ApplicationServices \
  -framework ImageIO -framework CryptoKit -framework ServiceManagement \
  -framework AVKit \
  "$project_root"/macos/Sources/*.swift -o "$app/Contents/MacOS/Kaki Tools"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.openclaw.kakitools</string>
<key>CFBundleExecutable</key><string>Kaki Tools</string>
<key>CFBundleName</key><string>Kaki Tools</string>
<key>CFBundleDisplayName</key><string>Kaki Tools</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.4.5</string>
<key>CFBundleVersion</key><string>10405</string>
<key>CFBundleIconFile</key><string>icon.icns</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>KakiNativeBuild</key><true/>
</dict></plist>
PLIST
cp "$project_root/macos/Resources/icon.icns" "$app/Contents/Resources/icon.icns"
cp "$project_root/macos/Resources/kaki-logo.png" "$app/Contents/Resources/kaki-logo.png"
/usr/bin/codesign --force --sign "$identity" --options runtime --timestamp=none "$app"
/usr/bin/codesign --verify --deep --strict "$app"
if [ "$identity" != '-' ]; then
  signature=$(/usr/bin/codesign -d --verbose=4 "$app" 2>&1)
  if printf '%s\n' "$signature" | /usr/bin/grep -q 'Signature=adhoc'; then
    echo '构建意外生成临时签名，已停止。' >&2; exit 1
  fi
fi
if [ -d "$output/Kaki Tools.app" ]; then
  marker=$(/usr/libexec/PlistBuddy -c 'Print :KakiNativeBuild' "$output/Kaki Tools.app/Contents/Info.plist" 2>/dev/null || true)
  [ "$marker" = 'true' ] || { echo '输出目录包含非本脚本生成的应用，已停止。' >&2; exit 1; }
  rm -rf "$output/Kaki Tools.app"
fi
mv "$app" "$output/Kaki Tools.app"
echo "原生应用已生成：$output/Kaki Tools.app"
du -sh "$output/Kaki Tools.app"

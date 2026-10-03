#!/usr/bin/env bash
set -euo pipefail

# 构建 Deskflow 的 deskflow-core，并准备打包所需的两个产物：
#   1. components/bin/deskflow-core         —— 开发用二进制(链接 Homebrew Qt，本机可直接跑)
#   2. components/deskflow/                 —— 自包含 Qt 框架+插件包(供独立组件打包)
#
# 源码目录默认是 ~/Downloads/deskflow_repo，可用 DESKFLOW_REPO 覆盖。
# 仅当二进制缺失或传了 --rebuild 时才重新编译(编译约数分钟)。

project_root=$(cd "$(dirname "$0")/.." && pwd)
repo="${DESKFLOW_REPO:-$HOME/Downloads/deskflow_repo}"
build_dir="$repo/build"
built="$build_dir/bin/deskflow-core"
dev_bin="$project_root/components/bin/deskflow-core"
bundle_dir="$project_root/components/deskflow"
arch=$(uname -m)                       # arm64 / x86_64
prefix=$(brew --prefix)                # /opt/homebrew (Apple Silicon) or /usr/local (Intel)

[ -d "$repo" ] || { echo "Deskflow 源码目录不存在：$repo(可用 DESKFLOW_REPO 指定)" >&2; exit 1; }

# Older AppleClang (14) does not implement C++20's "down with typename"; deskflow
# omits `typename` in PriorityQueue.h. Patch it idempotently for local builds.
pq="$repo/src/lib/base/PriorityQueue.h"
if [ -f "$pq" ] && ! grep -q "typename Container::value_type" "$pq"; then
  echo "==> 应用 PriorityQueue.h 的 C++20 兼容补丁(旧 AppleClang)..."
  /usr/bin/sed -i '' \
    -e 's/using value_type = Container::value_type;/using value_type = typename Container::value_type;/' \
    -e 's/using size_type = Container::size_type;/using size_type = typename Container::size_type;/' \
    -e 's/using iterator = Container::iterator;/using iterator = typename Container::iterator;/' \
    -e 's/using const_iterator = Container::const_iterator;/using const_iterator = typename Container::const_iterator;/' \
    "$pq"
fi

if [ ! -f "$built" ] || [ "${1:-}" = "--rebuild" ]; then
  echo "==> 配置并编译 deskflow-core($arch)..."
  cmake -S "$repo" -B "$build_dir" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_INSTALLER=OFF \
    -DBUILD_OSX_BUNDLE=OFF \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_PREFIX_PATH="$prefix/opt/qt;$prefix/opt/openssl@3" \
    -DOPENSSL_ROOT_DIR="$prefix/opt/openssl@3"
  cmake --build "$build_dir" --target deskflow-core
fi

# 1) 开发用二进制
mkdir -p "$(dirname "$dev_bin")"
cp "$built" "$dev_bin"
chmod 755 "$dev_bin"
echo "==> 开发二进制: $dev_bin"

# 2) 自包含打包包：放进一个最小 .app 让 macdeployqt 部署 Qt 框架+插件并修正 rpath
stage=$(mktemp -d "${TMPDIR:-/tmp}/kaki-desktop-qt.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/deskflow-core.app/Contents/MacOS"
cp "$built" "$stage/deskflow-core.app/Contents/MacOS/deskflow-core"
cat > "$stage/deskflow-core.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>deskflow-core</string>
  <key>CFBundleIdentifier</key><string>com.openclaw.kakitools.deskflow-core</string>
  <key>CFBundleName</key><string>deskflow-core</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST

echo "==> macdeployqt 部署 Qt 框架与插件..."
macdeployqt "$stage/deskflow-core.app" -always-overwrite -no-strip -no-codesign -verbose=1

rm -rf "$bundle_dir"
mkdir -p "$bundle_dir"
cp "$stage/deskflow-core.app/Contents/MacOS/deskflow-core" "$bundle_dir/deskflow-core"
cp -R "$stage/deskflow-core.app/Contents/Frameworks" "$bundle_dir/Frameworks"
cp -R "$stage/deskflow-core.app/Contents/PlugIns" "$bundle_dir/PlugIns"
cp "$stage/deskflow-core.app/Contents/Resources/qt.conf" "$bundle_dir/qt.conf"
chmod 755 "$bundle_dir/deskflow-core"

# 只保留 deskflow-core 真正需要的插件:cocoa 平台插件(必需)与原生 style。
# macdeployqt 额外带上的 imageformats/iconengines/platforminputcontexts/tls 等
# 引用了 QtPdf/QtSvg/QtVirtualKeyboard/OpenSSL 这些未部署或非必需组件,既无用
# 又会触发 electron-builder 的 `codesign --verify --deep --strict` 校验失败。
rm -rf "$bundle_dir/PlugIns/iconengines" \
       "$bundle_dir/PlugIns/imageformats" \
       "$bundle_dir/PlugIns/networkinformation" \
       "$bundle_dir/PlugIns/platforminputcontexts" \
       "$bundle_dir/PlugIns/tls"

echo "==> 打包包已生成: $bundle_dir"
du -sh "$bundle_dir"

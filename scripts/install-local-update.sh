#!/usr/bin/env bash
set -euo pipefail

# 本机安全更新：先验证构建产物，再复制到临时目录并二次验证；任何签名检查失败都不会覆盖已安装应用。
app_name='Kaki Tools.app'
project_root=$(cd "$(dirname "$0")/.." && pwd)
# electron-builder 输出目录带架构后缀：arm64 → mac-arm64，x86_64 → mac-x64。
arch=$(uname -m)
case "$arch" in
  arm64) dist_dir="mac-arm64" ;;
  x86_64) dist_dir="mac-x64" ;;
  *) dist_dir="mac" ;;
esac
source_app="$project_root/dist/$dist_dir/$app_name"
installed_app="/Applications/$app_name"
stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/kaki-tools-update.XXXXXX")
stage_app="$stage_dir/$app_name"
backup_dir="$HOME/Library/Application Support/Kaki Tools/updates"
timestamp=$(date '+%Y%m%d-%H%M%S')
backup_app="$backup_dir/Kaki Tools-$timestamp.app"

cleanup() {
  if [ -d "$stage_dir" ]; then /usr/bin/find "$stage_dir" -depth -delete 2>/dev/null || true; fi
}
trap cleanup EXIT

[ -d "$source_app" ] || { echo "找不到构建产物：$source_app" >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$source_app"
/usr/bin/ditto --rsrc --extattr "$source_app" "$stage_app"
/usr/bin/codesign --verify --deep --strict "$stage_app"

if [ -d "$installed_app" ]; then
  /usr/bin/codesign --verify --deep --strict "$installed_app"
fi

running_pid=$({ /bin/ps -axo pid=,command= | /usr/bin/awk '/\/Applications\/Kaki Tools\.app\/Contents\/MacOS\/Kaki Tools$/ {print $1; exit}'; } || true)
if [ -n "$running_pid" ]; then
  /bin/kill -TERM "$running_pid"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    /bin/ps -p "$running_pid" >/dev/null 2>&1 || break
    /bin/sleep 0.2
  done
  if /bin/ps -p "$running_pid" >/dev/null 2>&1; then
    # 旧版可能卡在 Electron 的隐藏窗口退出路径；进程目标已精确确认，才使用兜底结束。
    echo 'Kaki Tools 未正常退出，正在结束失效实例。' >&2
    /bin/kill -KILL "$running_pid"
    /bin/sleep 0.5
    if /bin/ps -p "$running_pid" >/dev/null 2>&1; then
      echo 'Kaki Tools 进程仍未结束，已取消更新。' >&2
      exit 1
    fi
  fi
fi

mkdir -p "$backup_dir"
if [ -d "$installed_app" ]; then
  mv "$installed_app" "$backup_app"
fi

if ! mv "$stage_app" "$installed_app" || ! /usr/bin/codesign --verify --deep --strict "$installed_app"; then
  if [ -d "$backup_app" ] && [ ! -e "$installed_app" ]; then mv "$backup_app" "$installed_app"; fi
  echo '安装失败，已保留或恢复上一版本。' >&2
  exit 1
fi

echo "Kaki Tools 更新完成：$installed_app"
echo "上一版本备份：$backup_app"
/usr/bin/open -a "$installed_app"

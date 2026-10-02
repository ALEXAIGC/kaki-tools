#!/usr/bin/env bash
set -euo pipefail

# 本机更新：验证产物和临时副本，保留旧版；替换尚未完成时由退出 trap 恢复。
app_name='Kaki Tools.app'
project_root=$(cd "$(dirname "$0")/.." && pwd)
case "$(uname -m)" in
  arm64) dist_dir='mac-arm64' ;;
  x86_64) dist_dir='mac-x64' ;;
  *) dist_dir='mac' ;;
esac
source_app="$project_root/dist/$dist_dir/$app_name"
installed_app="/Applications/$app_name"
user_data_dir="$HOME/Library/Application Support/Kaki Tools"
backup_dir="$user_data_dir/updates"
stage_base="${TMPDIR:-/tmp}"
codesign_command='/usr/bin/codesign'
ditto_command='/usr/bin/ditto'
ps_command='/bin/ps'
kill_command='/bin/kill'
sleep_command='/bin/sleep'
open_command='/usr/bin/open'
move_command='/bin/mv'

# 隔离测试必须显式提供全部替代工具和目录，不能落回真实应用或进程命令。
if [ "${KAKI_UPDATE_TEST_MODE:-0}" = '1' ]; then
  test_root="${KAKI_UPDATE_TEST_ROOT:?}"
  [ -d "$test_root" ] && [ "$test_root" != '/' ] || { echo '无效测试根目录。' >&2; exit 1; }
  test_root=$(cd "$test_root" && pwd -P)
  source_app="${KAKI_UPDATE_SOURCE_APP:?}"
  installed_app="${KAKI_UPDATE_INSTALLED_APP:?}"
  backup_dir="${KAKI_UPDATE_BACKUP_DIR:?}"
  user_data_dir="${KAKI_UPDATE_USER_DATA_DIR:?}"
  stage_base="${KAKI_UPDATE_STAGE_BASE:?}"
  codesign_command="${KAKI_UPDATE_CODESIGN:?}"
  ditto_command="${KAKI_UPDATE_DITTO:?}"
  ps_command="${KAKI_UPDATE_PS:?}"
  kill_command="${KAKI_UPDATE_KILL:?}"
  sleep_command="${KAKI_UPDATE_SLEEP:?}"
  open_command="${KAKI_UPDATE_OPEN:?}"
  move_command="${KAKI_UPDATE_MV:?}"
  for candidate in "$source_app" "$installed_app" "$backup_dir" "$user_data_dir" "$stage_base" \
    "$codesign_command" "$ditto_command" "$ps_command" "$kill_command" "$sleep_command" "$open_command" "$move_command"; do
    case "$candidate" in "$test_root"/*) ;; *) echo '测试覆盖路径必须位于测试根目录。' >&2; exit 1 ;; esac
    case "$candidate" in */../*|*/./*|*/..|*/.) echo '测试路径不能跳出测试根目录。' >&2; exit 1 ;; esac
    [ ! -L "$candidate" ] || { echo '测试路径不能使用符号链接。' >&2; exit 1; }
    probe="$candidate"
    [ -d "$probe" ] || probe=$(dirname "$probe")
    while [ ! -d "$probe" ]; do probe=$(dirname "$probe"); done
    physical_parent=$(cd "$probe" && pwd -P)
    case "$physical_parent" in "$test_root"|"$test_root"/*) ;; *) echo '测试路径不能经符号链接跳出测试根目录。' >&2; exit 1 ;; esac
  done
fi

stage_dir=''
backup_root=''
backup_app=''
replacement_started=0
committed=0
had_installed=0
had_running=0
prior_app_stopped=0
old_available=0

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  set +e
  if [ "$committed" != '1' ] && [ -n "$backup_root" ]; then
    # 新目录可能是部分复制或验签失败的包；先隔离，恢复时绝不嵌套覆盖。
    if [ "$replacement_started" = '1' ] && [ -e "$installed_app" ]; then
      if ! "$move_command" "$installed_app" "$backup_root/failed-$app_name"; then
        echo "无法隔离安装失败的应用；上一版本保留于：$backup_app" >&2
        status=1
      fi
    fi
    if [ -e "$backup_app" ] && [ ! -e "$installed_app" ]; then
      old_available=0
      if "$move_command" "$backup_app" "$installed_app" && "$codesign_command" --verify --deep --strict "$installed_app"; then
        old_available=1
        echo "安装未完成，已恢复上一版本：$installed_app" >&2
      else
        echo "恢复上一版本失败，请检查：$installed_app 和 $backup_app" >&2
        status=1
      fi
    fi
  fi
  if [ "$committed" != '1' ] && [ "$prior_app_stopped" = '1' ] && [ "$old_available" = '1' ] && [ -d "$installed_app" ]; then
    "$open_command" -a "$installed_app" || echo '旧版已恢复，但未能自动重新打开。' >&2
  fi
  if [ -n "$stage_dir" ] && [ -d "$stage_dir" ]; then /usr/bin/find "$stage_dir" -depth -delete 2>/dev/null || true; fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[ -d "$source_app" ] || { echo "找不到构建产物：$source_app" >&2; exit 1; }
"$codesign_command" --verify --deep --strict "$source_app"
stage_dir=$(mktemp -d "$stage_base/kaki-tools-update.XXXXXX")
stage_app="$stage_dir/$app_name"
"$ditto_command" --rsrc --extattr "$source_app" "$stage_app"
"$codesign_command" --verify --deep --strict "$stage_app"
if [ -d "$installed_app" ]; then
  had_installed=1
  "$codesign_command" --verify --deep --strict "$installed_app"
  old_available=1
fi

# 只匹配本应用主二进制；同样支持 macOS AppTranslocation 路径，不包含 Helper。
main_process_pattern='/\/Kaki Tools\.app\/Contents\/MacOS\/Kaki Tools$/ { if ($1 ~ /^[0-9]+$/) print $1 }'
running_pids=$("$ps_command" -ww -axo pid=,command= | /usr/bin/awk "$main_process_pattern")
for running_pid in $running_pids; do
  running_identity=$("$ps_command" -ww -p "$running_pid" -o lstart=,command= 2>/dev/null || true)
  if ! printf '%s\n' "$running_identity" | /usr/bin/awk '/\/Kaki Tools\.app\/Contents\/MacOS\/Kaki Tools$/ { found=1 } END { exit !found }'; then continue; fi
  same_process_alive() {
    local current
    current=$("$ps_command" -ww -p "$running_pid" -o lstart=,command= 2>/dev/null || true)
    [ -n "$current" ] && [ "$current" = "$running_identity" ]
  }
  if ! same_process_alive; then continue; fi
  had_running=1
  if ! "$kill_command" -TERM "$running_pid" && same_process_alive; then
    echo '无法请求 Kaki Tools 退出，已取消更新。' >&2; exit 1
  fi
  for _ in $(seq 1 25); do
    same_process_alive || break
    "$sleep_command" 0.2
  done
  if same_process_alive; then
    echo 'Kaki Tools 未正常退出，正在结束已确认的旧实例。' >&2
    if ! "$kill_command" -KILL "$running_pid" && same_process_alive; then exit 1; fi
    "$sleep_command" 0.5
    if same_process_alive; then echo 'Kaki Tools 进程仍未结束，已取消更新。' >&2; exit 1; fi
  fi
done
prior_app_stopped="$had_running"

mkdir -p "$backup_dir"
backup_root=$(mktemp -d "$backup_dir/update-$(date '+%Y%m%d-%H%M%S').XXXXXX")
backup_app="$backup_root/$app_name"
# 首次运行新版会裁剪历史；先保留业务数据，避免备份递归包含 updates 或缓存。
mkdir -p "$backup_root/user-data"
for entry in history.json history.backup.json settings.json images deskflow; do
  if [ -e "$user_data_dir/$entry" ]; then
    if ! "$ditto_command" --rsrc --extattr "$user_data_dir/$entry" "$backup_root/user-data/$entry"; then
      echo "用户数据备份失败，已取消更新：$entry" >&2
      exit 1
    fi
  fi
done
if [ "$had_installed" = '1' ]; then "$move_command" "$installed_app" "$backup_app"; fi
replacement_started=1
old_available=0
"$move_command" "$stage_app" "$installed_app"
"$codesign_command" --verify --deep --strict "$installed_app"
committed=1

echo "Kaki Tools 更新完成：$installed_app"
echo "升级前用户数据备份：$backup_root/user-data"
if [ "$had_installed" = '1' ]; then echo "上一版本备份：$backup_app"; fi
"$open_command" -a "$installed_app"

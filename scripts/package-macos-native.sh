#!/usr/bin/env bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
arch=$(uname -m)
app_input="${1:-$project_root/dist/native-$arch/Kaki Tools.app}"
output="${2:-$project_root/dist/native-$arch}"
fail() { echo "$*" >&2; exit 1; }
for tool in hdiutil codesign ditto python3 shasum; do command -v "$tool" >/dev/null || fail "缺少打包工具：$tool"; done
[ -d "$app_input" ] || fail "原生应用不存在：$app_input。请先运行 scripts/build-macos-native.sh。"
app_input=$(cd "$(dirname "$app_input")" && pwd)/$(basename "$app_input")
verify_native() {
  local app="$1" info="$1/Contents/Info.plist" executable marker identifier
  marker=$(/usr/libexec/PlistBuddy -c 'Print :KakiNativeBuild' "$info" 2>/dev/null || true)
  identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info" 2>/dev/null || true)
  executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info" 2>/dev/null || true)
  [ "$marker" = true ] && [ "$identifier" = com.openclaw.kakitools ] && [ "$executable" = 'Kaki Tools' ] || fail '输入不是本项目的原生 Kaki Tools 应用。'
  [ -x "$app/Contents/MacOS/$executable" ] || fail '原生主程序缺失。'
  /usr/bin/file "$app/Contents/MacOS/$executable" | /usr/bin/grep -q 'Mach-O' || fail '主程序不是 Mach-O。'
  /usr/bin/lipo "$app/Contents/MacOS/$executable" -verify_arch "$arch"
  local forbidden
  forbidden=$(/usr/bin/find "$app/Contents" \( -name '*.asar' -o -name 'Electron Framework.framework' -o -name 'Qt*.framework' -o -name 'DeskflowRuntime.bundle' -o -name 'deskflow-core' \) -print)
  [ -z "$forbidden" ] || fail "原生主包包含不应内置的运行时：$forbidden"
  /usr/bin/otool -L "$app/Contents/MacOS/$executable" | /usr/bin/grep -Eiq 'Electron|Qt(Core|Gui|Widgets|Network)' && fail '主程序链接到 Electron 或 Qt。'
  /usr/bin/codesign --verify --deep --strict "$app"
}
verify_native "$app_input"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_input/Contents/Info.plist")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || fail '应用版本格式无效。'
mkdir -p "$output"
output=$(cd "$output" && pwd)
stage=$(mktemp -d "$output/.native-dmg.XXXXXX")
mount_point=$(mktemp -d "${TMPDIR:-/tmp}/kaki-dmg-check.XXXXXX")
mount_device=''
cleanup() {
  local result=$?
  trap - EXIT INT TERM
  if [ -z "$mount_device" ]; then
    mount_device=$(/usr/bin/hdiutil info -plist 2>/dev/null | python3 -c 'import pathlib,plistlib,sys; p=pathlib.Path(sys.argv[1]).resolve(); d=plistlib.loads(sys.stdin.buffer.read()); print(next((e.get("dev-entry", "") for i in d.get("images", []) for e in i.get("system-entities", []) if e.get("mount-point") and pathlib.Path(e["mount-point"]).resolve()==p), ""))' "$mount_point" 2>/dev/null || true)
  fi
  if [ -z "$mount_device" ]; then
    local mount_state
    mount_state=$(python3 -c 'import os,sys; print("mounted" if os.path.ismount(os.path.realpath(sys.argv[1])) else "unmounted")' "$mount_point" 2>/dev/null || printf 'unknown')
    if [ "$mount_state" != unmounted ]; then
      echo "无法确定验证磁盘设备：$mount_point。挂载和临时文件已保留。" >&2
      exit 1
    fi
  fi
  if [ -n "$mount_device" ]; then
    if ! /usr/bin/hdiutil detach "$mount_device"; then
      if ! /usr/bin/hdiutil detach -force "$mount_device"; then
        echo "无法卸载验证磁盘：$mount_device（$mount_point）。临时文件已保留。" >&2
        exit 1
      fi
    fi
  fi
  rm -rf "$stage"
  rmdir "$mount_point" 2>/dev/null || true
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cat > "$stage/app-manifest.py" <<'PYTHON'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]); manifest={}
for path in sorted(root.rglob('*')):
    relative=str(path.relative_to(root))
    if path.is_symlink():
        manifest[relative]={'symlink':str(path.readlink())}
    elif path.is_file():
        digest=hashlib.sha256()
        with path.open('rb') as stream:
            for block in iter(lambda:stream.read(1024*1024),b''): digest.update(block)
        manifest[relative]={'sha256':digest.hexdigest(),'executable':bool(path.stat().st_mode & 0o111)}
print(json.dumps(manifest,sort_keys=True,indent=2))
PYTHON
python3 "$stage/app-manifest.py" "$app_input" > "$stage/source-manifest.json"
mkdir "$stage/payload"
/usr/bin/ditto "$app_input" "$stage/payload/Kaki Tools.app"
ln -s /Applications "$stage/payload/Applications"
[ ! -f "$project_root/macos/README.md" ] || cp "$project_root/macos/README.md" "$stage/payload/README.md"
[ ! -f "$project_root/LICENSE" ] || cp "$project_root/LICENSE" "$stage/payload/LICENSE"
verify_native "$stage/payload/Kaki Tools.app"
python3 "$stage/app-manifest.py" "$stage/payload/Kaki Tools.app" > "$stage/staged-manifest.json"
cmp "$stage/source-manifest.json" "$stage/staged-manifest.json"
image="$stage/Kaki-Tools-$version-$arch.dmg"
/usr/bin/hdiutil create -quiet -srcfolder "$stage/payload" -volname 'Kaki Tools' -format UDZO -fs HFS+ "$image"
/usr/bin/hdiutil verify "$image"
/usr/bin/hdiutil checksum -type SHA256 "$image"
/usr/bin/hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mount_point" -plist "$image" > "$stage/attach.plist"
mount_device=$(python3 - "$stage/attach.plist" "$mount_point" <<'PY'
import pathlib,plistlib,sys
with open(sys.argv[1], 'rb') as source: info=plistlib.load(source)
for entry in info.get('system-entities', []):
    if entry.get('mount-point') and pathlib.Path(entry['mount-point']).resolve() == pathlib.Path(sys.argv[2]).resolve():
        print(entry['dev-entry']); break
else: raise SystemExit('Unable to locate the verification mount device')
PY
)
/usr/bin/hdiutil info -plist | python3 -c 'import pathlib,plistlib,sys; p=pathlib.Path(sys.argv[1]).resolve(); d=plistlib.loads(sys.stdin.buffer.read()); image=next((i for i in d.get("images", []) if any(e.get("mount-point") and pathlib.Path(e["mount-point"]).resolve()==p for e in i.get("system-entities", []))), None); sys.exit(0 if image is not None and image.get("writeable") is False else "Verification disk is not mounted read-only")' "$mount_point"
verify_native "$mount_point/Kaki Tools.app"
python3 "$stage/app-manifest.py" "$mount_point/Kaki Tools.app" > "$stage/mounted-manifest.json"
cmp "$stage/source-manifest.json" "$stage/mounted-manifest.json"
[ "$(readlink "$mount_point/Applications")" = /Applications ] || fail 'DMG 的 Applications 链接无效。'
/usr/bin/hdiutil detach "$mount_device"
mount_device=''
final="$output/$(basename "$image")"
(cd "$stage" && shasum -a 256 "$(basename "$image")") > "$image.sha256"
mv -f "$image" "$final"
mv -f "$image.sha256" "$final.sha256"
echo "原生 DMG 已生成并验证：$final"
echo "应用文件内容、链接与执行位清单 SHA-256：$(shasum -a 256 "$stage/source-manifest.json" | cut -d ' ' -f 1)"
/usr/bin/du -sh "$app_input" "$final"

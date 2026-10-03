#!/usr/bin/env bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
arch=$(uname -m)
runtime="${1:-$project_root/components/deskflow}"
output="${2:-$project_root/dist/components-$arch}"
identity="${KAKI_DESKFLOW_IDENTITY:--}"
fail() { echo "$*" >&2; exit 1; }
for tool in codesign ditto otool lipo python3 shasum; do command -v "$tool" >/dev/null || fail "缺少打包工具：$tool"; done
for entry in deskflow-core qt.conf Frameworks PlugIns; do [ -e "$runtime/$entry" ] || fail "Deskflow 运行时缺少：$entry"; done
[ -x "$runtime/deskflow-core" ] || fail 'Deskflow 主程序不可执行。'
/usr/bin/lipo "$runtime/deskflow-core" -verify_arch "$arch"
mkdir -p "$output"
output=$(cd "$output" && pwd)
final_bundle="$output/DeskflowRuntime.bundle"
final_archive="$output/DeskflowRuntime-$arch.zip"
if [ -e "$final_bundle" ]; then
  id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$final_bundle/Contents/Info.plist" 2>/dev/null || true)
  [ "$id" = com.openclaw.kakitools.deskflow-runtime ] || fail '输出位置已有其他组件，已停止。'
fi
stage=$(mktemp -d "$output/.deskflow-package.XXXXXX")
publication_started=0
publication_complete=0
cleanup() {
  local result=$?
  trap - EXIT INT TERM
  if [ "$publication_started" = 1 ] && [ "$publication_complete" != 1 ]; then
    local name target backup
    for name in DeskflowRuntime.bundle "DeskflowRuntime-$arch.zip" "DeskflowRuntime-$arch.zip.sha256"; do
      target="$output/$name"
      backup="$stage/previous/$name"
      if [ -e "$backup" ] || [ -L "$backup" ]; then
        if ! rm -rf "$target" || ! mv "$backup" "$target"; then
          echo "无法恢复原组件产物：$backup。临时文件已保留。" >&2
          exit 1
        fi
      elif [ ! -e "$stage/$name" ]; then
        if ! rm -rf "$target"; then
          echo "无法撤回未完成组件产物：$target。临时文件已保留。" >&2
          exit 1
        fi
      fi
    done
  fi
  rm -rf "$stage"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
bundle="$stage/DeskflowRuntime.bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
/usr/bin/ditto "$runtime/deskflow-core" "$bundle/Contents/MacOS/deskflow-core"
/usr/bin/ditto "$runtime/Frameworks" "$bundle/Contents/Frameworks"
/usr/bin/ditto "$runtime/PlugIns" "$bundle/Contents/PlugIns"
/usr/bin/ditto "$runtime/qt.conf" "$bundle/Contents/Resources/qt.conf"
chmod 755 "$bundle/Contents/MacOS/deskflow-core"
if [ -f "$runtime/dependency-source.json" ]; then cp "$runtime/dependency-source.json" "$bundle/Contents/Resources/dependency-source.json"; fi
if [ -d "$runtime/Licenses" ]; then /usr/bin/ditto "$runtime/Licenses" "$bundle/Contents/Resources/Licenses"; fi
if [ -n "${DESKFLOW_LICENSE_DIR:-}" ]; then
  [ -d "$DESKFLOW_LICENSE_DIR" ] || fail 'DESKFLOW_LICENSE_DIR 不是目录。'
  /usr/bin/ditto "$DESKFLOW_LICENSE_DIR" "$bundle/Contents/Resources/Licenses"
fi
for license in "$runtime"/LICENSE* "$runtime"/COPYING*; do
  [ -f "$license" ] || continue
  mkdir -p "$bundle/Contents/Resources/Licenses"
  cp "$license" "$bundle/Contents/Resources/Licenses/$(basename "$license")"
done
cat > "$bundle/Contents/Resources/Runtime-Provenance.txt" <<'NOTICE'
DeskflowRuntime is an optional Kaki Tools component, not part of the native app.
It contains the existing Deskflow/Qt runtime closure copied without changing dependency paths.
Deskflow source and license information: https://github.com/deskflow/deskflow
Qt source and license information: https://www.qt.io/licensing/
Other dependency names and available provenance are included in dependency-source.json.
Original framework resources and copyright metadata are retained.
Additional original license assets can be supplied with DESKFLOW_LICENSE_DIR.
NOTICE
cat > "$stage/verify-runtime.py" <<'PY'
import json,pathlib,re,subprocess,sys
root=pathlib.Path(sys.argv[1]).resolve(); arch=sys.argv[2]
exe=root/'Contents/MacOS/deskflow-core'; magics={b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca',b'\xca\xfe\xba\xbf',b'\xbf\xba\xfe\xca'}
def command(*args): return subprocess.check_output(args,text=True)
def inside(path):
    try: path.resolve(strict=True).relative_to(root); return True
    except (ValueError,FileNotFoundError): return False
def rpaths(path): return re.findall(r'\bcmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset',command('/usr/bin/otool','-l',str(path)))
def expand(value,loader):
    if value.startswith('@executable_path'): return pathlib.Path(str(exe.parent)+value[len('@executable_path'):])
    if value.startswith('@loader_path'): return pathlib.Path(str(loader.parent)+value[len('@loader_path'):])
    return pathlib.Path(value)
files=[]
for path in root.rglob('*'):
    if path.is_symlink():
        if not inside(path): raise SystemExit(f'Broken or external symlink: {path}')
        continue
    if not path.is_file(): continue
    with path.open('rb') as stream: magic=stream.read(4)
    if magic in magics: files.append(path)
if not files: raise SystemExit('No Mach-O runtime objects')
report=[]; minimums=[]; records={}
for path in sorted(files):
    subprocess.run(['/usr/bin/lipo',str(path),'-verify_arch',arch],check=True)
    load=command('/usr/bin/otool','-l',str(path))
    minimums+=re.findall(r'\bminos ([\d.]+)',load)
    minimums+=re.findall(r'cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([\d.]+)',load)
    paths=rpaths(path)
    install_names=[line.strip() for line in command('/usr/bin/otool','-D',str(path)).splitlines()[1:]]
    dependencies=[line.strip().split(' (compatibility version',1)[0] for line in command('/usr/bin/otool','-L',str(path)).splitlines()[1:]
                  if line.strip().split(' (compatibility version',1)[0] not in install_names]
    records[path.resolve()]={'file':str(path.relative_to(root)),'install_names':install_names,'rpaths':paths,'dependencies':dependencies}
    report.append(records[path.resolve()])
# dyld searches the current loader's rpaths and the loading ancestors' rpath stack,
# not merely the main executable's paths. Traverse that actual dependency graph.
visited=set(); contexts=set()
def walk(path,inherited=()):
    path=path.resolve(); record=records[path]
    own=tuple(str(expand(value,path).resolve()) for value in record['rpaths'])
    stack=tuple(dict.fromkeys(own+inherited))
    context=(path,stack)
    if context in contexts: return
    contexts.add(context); visited.add(path)
    for value in record['dependencies']:
        if value.startswith('/System/Library/') or value.startswith('/usr/lib/'): continue
        if value.startswith('@rpath/'):
            candidates=[pathlib.Path(base)/value[len('@rpath/'):] for base in stack]
            target=next((candidate.resolve() for candidate in candidates if inside(candidate)),None)
            if target is None: raise SystemExit(f'Unresolved dependency {value} in {path}')
        elif value.startswith('@executable_path') or value.startswith('@loader_path'):
            target=expand(value,path)
            if not inside(target): raise SystemExit(f'Missing internal dependency {value} in {path}')
            target=target.resolve()
        else: raise SystemExit(f'Nonportable dependency {value} in {path}')
        if target not in records: raise SystemExit(f'Dependency is not a packaged Mach-O object: {target}')
        walk(target,stack)
walk(exe)
for path in files:
    if 'PlugIns' in path.parts: walk(path)
# Also verify optional frameworks/libraries retained in the source runtime.
for path in files:
    if path.resolve() not in visited: walk(path)
minimum=max(minimums,key=lambda value:tuple(map(int,value.split('.')))) if minimums else '14.0'
print(json.dumps({'architecture':arch,'minimum_macos':minimum,'objects':report},indent=2))
PY
python3 "$stage/verify-runtime.py" "$bundle" "$arch" > "$stage/runtime-closure.json"
minimum=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["minimum_macos"])' "$stage/runtime-closure.json")
cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.openclaw.kakitools.deskflow-runtime</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleExecutable</key><string>deskflow-core</string>
<key>CFBundleName</key><string>DeskflowRuntime</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>LSMinimumSystemVersion</key><string>$minimum</string>
</dict></plist>
PLIST
cp "$stage/runtime-closure.json" "$bundle/Contents/Resources/runtime-closure.json"
# Sign leaf code first, then framework containers, then the outer BNDL. Never use
# --deep for signing: explicitly visit every object and verify the complete seal.
while IFS= read -r object; do
  /usr/bin/codesign --force --sign "$identity" --timestamp=none "$bundle/$object"
done < <(python3 -c 'import json,sys; print("\n".join(x["file"] for x in json.load(open(sys.argv[1]))["objects"]))' "$stage/runtime-closure.json")
while IFS= read -r -d '' framework; do
  /usr/bin/codesign --force --sign "$identity" --timestamp=none "$framework"
done < <(/usr/bin/find "$bundle/Contents/Frameworks" -type d -name '*.framework' -print0)
/usr/bin/codesign --force --sign "$identity" --timestamp=none "$bundle"
/usr/bin/codesign --verify --deep --strict "$bundle"
python3 "$stage/verify-runtime.py" "$bundle" "$arch" > "$stage/runtime-after-sign.json"
cmp "$stage/runtime-closure.json" "$stage/runtime-after-sign.json"
archive="$stage/DeskflowRuntime-$arch.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$bundle" "$archive"
mkdir "$stage/zip-check"
/usr/bin/ditto -x -k "$archive" "$stage/zip-check"
/usr/bin/codesign --verify --deep --strict "$stage/zip-check/DeskflowRuntime.bundle"
python3 "$stage/verify-runtime.py" "$stage/zip-check/DeskflowRuntime.bundle" "$arch" > "$stage/runtime-after-zip.json"
cmp "$stage/runtime-closure.json" "$stage/runtime-after-zip.json"
(cd "$stage" && shasum -a 256 "$(basename "$archive")") > "$archive.sha256"
mkdir "$stage/previous"
publication_started=1
for name in DeskflowRuntime.bundle "DeskflowRuntime-$arch.zip" "DeskflowRuntime-$arch.zip.sha256"; do
  if [ -e "$output/$name" ] || [ -L "$output/$name" ]; then mv "$output/$name" "$stage/previous/$name"; fi
done
for name in DeskflowRuntime.bundle "DeskflowRuntime-$arch.zip" "DeskflowRuntime-$arch.zip.sha256"; do
  mv "$stage/$name" "$output/$name"
done
publication_complete=1
echo "可选跨屏组件已生成并静态验证（未运行 Deskflow）：$final_bundle"
echo "运行架构：${arch}；组件最低 macOS：${minimum}"
/usr/bin/du -sh "$final_bundle" "$final_archive"

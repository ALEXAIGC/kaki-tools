#!/usr/bin/env bash
set -euo pipefail
archive_root=$(cd "$(dirname "$0")/.." && pwd)
project_root=$(cd "$archive_root/../.." && pwd)
bash "$project_root/scripts/build-deskflow.sh" "$@"
mkdir -p "$archive_root/native/bin"
cp "$project_root/components/bin/deskflow-core" "$archive_root/native/bin/deskflow-core"

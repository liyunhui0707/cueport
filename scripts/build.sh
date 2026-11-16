#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/build/module-cache"
export SWIFT_MODULECACHE_PATH="$PWD/build/module-cache"
mode="${1:-debug}"
if [[ "$mode" != debug && "$mode" != release ]]; then
  print -u2 'Usage: scripts/build.sh [debug|release]'
  exit 1
fi
swift build --disable-sandbox --configuration "$mode" --scratch-path build/swift --cache-path build/cache
python3 scripts/package_app.py "$mode"

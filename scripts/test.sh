#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/build/module-cache"
export SWIFT_MODULECACHE_PATH="$PWD/build/module-cache"
swift test --disable-sandbox --scratch-path build/swift --cache-path build/cache
python3 Tests/CLITests/test_cli.py
python3 scripts/test_bridge_data_migration.py
python3 scripts/test_test_app_archive.py
python3 scripts/test_website.py

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/cache/clang build/cache/swiftpm
export CLANG_MODULE_CACHE_PATH="$PWD/build/cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/cache/clang"
swift build --product codexswoop-recovery --disable-sandbox --cache-path "$PWD/build/cache/swiftpm"
bin="$(swift build --show-bin-path --disable-sandbox --cache-path "$PWD/build/cache/swiftpm")"
objects=()
if [ -f "$bin/CodexSwoopCore.o" ]; then
  objects+=("$bin/CodexSwoopCore.o")
  include="$bin"
else
  objects+=("$bin/CodexSwoopCore.build/"*.o)
  include="$bin/Modules"
fi
swiftc -swift-version 6 -parse-as-library -module-cache-path "$PWD/build/cache/clang" \
  -I "$include" Tests/CodexSwoopCoreTests/ReleaseFixtures.swift Tests/Recovery/EpochRecoveryChecks.swift \
  "${objects[@]}" -o build/epoch-recovery-checks
build/epoch-recovery-checks
"$bin/codexswoop-recovery" --help

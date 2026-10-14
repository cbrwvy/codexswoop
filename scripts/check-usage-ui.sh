#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="$PWD/build/usage-ui"
mkdir -p "$output/module" build/cache/clang
export CLANG_MODULE_CACHE_PATH="$PWD/build/cache/clang"
swiftc -swift-version 6 -parse-as-library -whole-module-optimization -emit-library -emit-module -module-name CodexSwoopCore \
  Sources/CodexSwoopCore/*.swift -o "$output/module/libCodexSwoopCore.dylib" \
  -emit-module-path "$output/module/CodexSwoopCore.swiftmodule"
swiftc -parse-as-library -swift-version 6 -I "$output/module" -L "$output/module" -lCodexSwoopCore \
  -Xlinker -rpath -Xlinker "$output/module" \
  Sources/CodexSwoop/AccountUsageView.swift Tests/UI/UsageRenderingChecks.swift -o "$output/usage-ui-checks"
"$output/usage-ui-checks" "$output"

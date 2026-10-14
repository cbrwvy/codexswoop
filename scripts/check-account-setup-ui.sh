#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in ''|--with-menu-bar|--with-accessibility) ;; *) echo 'Usage: scripts/check-account-setup-ui.sh [--with-menu-bar|--with-accessibility]' >&2; exit 2;; esac
mkdir -p build/account-setup-ui/module build/cache/clang
output="$PWD/build/account-setup-ui"
export CLANG_MODULE_CACHE_PATH="$PWD/build/cache/clang"
swiftc -swift-version 6 -parse-as-library -whole-module-optimization -emit-library -emit-module -module-name CodexSwoopCore \
  Sources/CodexSwoopCore/*.swift -o "$output/module/libCodexSwoopCore.dylib" \
  -emit-module-path "$output/module/CodexSwoopCore.swiftmodule"
swiftc -swift-version 6 -D DEBUG -D SETUP_UI_CHECKS -parse-as-library \
  -I "$output/module" -L "$output/module" -lCodexSwoopCore -Xlinker -rpath -Xlinker "$output/module" \
  Sources/CodexSwoop/*.swift Tests/UI/AccountSetupRenderingChecks.swift -o "$output/account-setup-ui-checks"
fixture="$(mktemp -d /private/tmp/codexswoop-setup-ui-XXXXXX)"
trap 'rm -rf "$fixture"' EXIT
# macOS Bash 3.2 treats an empty array as unbound under nounset.
if [ "${1:-}" = --with-accessibility ]; then
  "$output/account-setup-ui-checks" "$output" --test-storage-root "$fixture" --with-accessibility
else
  "$output/account-setup-ui-checks" "$output" --test-storage-root "$fixture"
fi
if [ "${1:-}" = --with-menu-bar ]; then
swiftc -swift-version 6 -D DEBUG -D SETUP_UI_CHECKS -parse-as-library \
  -I "$output/module" -L "$output/module" -lCodexSwoopCore -Xlinker -rpath -Xlinker "$output/module" \
  Sources/CodexSwoop/*.swift Tests/UI/PopoverAnchorChecks.swift -o "$output/popover-anchor-checks"
"$output/popover-anchor-checks"
else
  echo 'SKIP live AppKit anchor checks: use --with-menu-bar in a logged-in macOS desktop session'
fi

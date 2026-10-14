#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in ''|--require-xctest|--safe-process-checks) ;; *) echo 'Usage: scripts/check.sh [--require-xctest|--safe-process-checks]' >&2; exit 2;; esac
mkdir -p build/cache/clang build/cache/swiftpm
export CLANG_MODULE_CACHE_PATH="$PWD/build/cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/cache/clang"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
deployment_target="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
swift_flags=(--sdk "$SDKROOT" -Xlinker -platform_version -Xlinker macos -Xlinker "$deployment_target" -Xlinker "$sdk_version")
./scripts/lint.sh
python3 scripts/check-localization.py
python3 scripts/check-project.py
python3 scripts/audit-baseline.py
python3 scripts/audit-baseline.py --staged
swiftc -swift-version 6 -parse-as-library Sources/CodexSwoop/MainThreadPreparation.swift \
  Tests/TrialStartupChecks.swift -o build/trial-startup-checks
build/trial-startup-checks
./scripts/check-isolation-lab.sh
swift --version
if [ "${1:-}" = --safe-process-checks ]; then
  swift run "${swift_flags[@]}" --cache-path "$PWD/build/cache/swiftpm" --disable-sandbox codexswoop-checks --safe-process-checks
else
  swift run "${swift_flags[@]}" --cache-path "$PWD/build/cache/swiftpm" --disable-sandbox codexswoop-checks
fi
full_xcode=false
if xcodebuild -version > build/xcode-version.log 2>&1; then
  full_xcode=true
  cat build/xcode-version.log
  swift test "${swift_flags[@]}" --cache-path "$PWD/build/cache/swiftpm" --disable-sandbox
else
  echo 'SKIP XCTest: full Xcode is not available in the selected Developer Directory. Core checks above are real executable tests.'
fi
./scripts/build-app.sh debug
./scripts/build-app.sh release
python3 scripts/check-project.py --bundle build/debug/CodexSwoop.app
python3 scripts/check-project.py --bundle build/release/CodexSwoop.app
swift scripts/check-icons.swift --bundle build/debug/CodexSwoop.app
swift scripts/check-icons.swift --bundle build/release/CodexSwoop.app
if "$full_xcode"; then
  ./scripts/check-xcode.sh
else
  echo 'SKIP native Xcode build: full Xcode is not available. SwiftPM app bundles were built.'
fi
if ! "$full_xcode" && [ "${1:-}" = --require-xctest ]; then
  echo 'FAIL required XCTest/native Xcode checks were unavailable.' >&2
  exit 1
fi
echo 'PASS all available checks (review any SKIP lines above)'

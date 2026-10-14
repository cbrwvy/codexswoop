#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
architecture="${2:-native}"
case "$configuration" in debug|release) ;; *) echo 'Usage: scripts/build-app.sh [debug|release] [native|arm64|x86_64|universal]' >&2; exit 2;; esac
arch_flags=(--disable-sandbox)
case "$architecture" in
  native) output_name="$configuration" ;;
  arm64|x86_64) arch_flags+=(--arch "$architecture"); output_name="$configuration-$architecture" ;;
  universal) arch_flags+=(--arch arm64 --arch x86_64); output_name="$configuration-universal" ;;
  *) echo 'Invalid architecture: use native, arm64, x86_64 or universal' >&2; exit 2 ;;
esac
mkdir -p build/cache/clang build/cache/swiftpm
export CLANG_MODULE_CACHE_PATH="$PWD/build/cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/cache/clang"
# swiftbuild filters SDKROOT out of link jobs; supply the actual SDK/deployment tuple to the linker explicitly.
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
deployment_target="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
# Multi-architecture SwiftPM builds use XCBuild, which supplies the platform and
# deployment flags from Package.swift. Passing -Xlinker -platform_version in
# that mode leaks the raw linker option to clang under Xcode 16.4 and fails.
# Keep the explicit linker tuple for existing native/single-arch builds.
if [ "$architecture" != universal ]; then
  arch_flags+=(-Xlinker -platform_version -Xlinker macos -Xlinker "$deployment_target" -Xlinker "$sdk_version")
fi
swift build --product CodexSwoop -c "$configuration" --sdk "$SDKROOT" "${arch_flags[@]}" --cache-path "$PWD/build/cache/swiftpm"
binary_directory="$(swift build --show-bin-path -c "$configuration" --sdk "$SDKROOT" "${arch_flags[@]}" --cache-path "$PWD/build/cache/swiftpm")"
application="$PWD/build/$output_name/CodexSwoop.app"
mkdir -p "$PWD/build/$output_name"
staging="$(mktemp -d "$PWD/build/$output_name/.bundle-XXXXXX")"
trap 'rm -rf "$staging"' EXIT
bundle="$staging/CodexSwoop.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary_directory/CodexSwoop" "$bundle/Contents/MacOS/CodexSwoop"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
cp Resources/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
cp Resources/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon*.png "$bundle/Contents/Resources/"
if [ "$configuration" = release ]; then strip -S "$bundle/Contents/MacOS/CodexSwoop"; fi
# Local development signature only. Release distribution needs Developer ID and notarization.
codesign --force --sign - "$bundle"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist"
codesign --verify --deep --strict "$bundle"
python3 scripts/check-project.py --bundle "$bundle"
case "$architecture" in
  arm64|x86_64) lipo "$bundle/Contents/MacOS/CodexSwoop" -verify_arch "$architecture" ;;
  universal)
    # CLT 27's lipo rejects a multi-architecture verify invocation; check each required slice.
    for arch in arm64 x86_64; do lipo "$bundle/Contents/MacOS/CodexSwoop" -verify_arch "$arch"; done ;;
esac
# Assemble from an allowlist, so stale resources/user files cannot leak into a subsequent package.
if [ -e "$application" ]; then mv "$application" "$staging/previous.app"; fi
if ! mv "$bundle" "$application"; then
  if [ -e "$staging/previous.app" ]; then mv "$staging/previous.app" "$application"; fi
  exit 1
fi
echo "Built $application"

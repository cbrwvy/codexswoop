#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Full Xcode only. Hostless tests use temporary fixtures, never the app as a test host.
xcodebuild -version
xcodebuild -showsdks
common=(-project CodexSwoop.xcodeproj -scheme CodexSwoop -derivedDataPath "$PWD/build/DerivedData" CODE_SIGNING_ALLOWED=NO)
verify_bundle() {
  local bundle="$1" label="$2" signature_root
  for arch in arm64 x86_64; do lipo "$bundle/Contents/MacOS/CodexSwoop" -verify_arch "$arch"; done
  swift scripts/check-icons.swift --native-bundle "$bundle"
  python3 scripts/check-project.py --bundle "$bundle"
  # Native builds remain unsigned. Verify ad hoc hardened-runtime signing on a disposable copy, without Keychain identities.
  mkdir -p build/native-signatures
  signature_root="$(mktemp -d "$PWD/build/native-signatures/$label-XXXXXX")"
  ditto "$bundle" "$signature_root/CodexSwoop.app"
  # Xcode Debug can embed a separate app debug dylib; sign nested code before its containing bundle.
  for nested in "$signature_root/CodexSwoop.app/Contents/MacOS/"*.dylib; do
    if [ -f "$nested" ]; then codesign --force --sign - --options runtime --timestamp=none "$nested"; fi
  done
  codesign --force --sign - --options runtime --timestamp=none "$signature_root/CodexSwoop.app"
  codesign --verify --deep --strict --verbose=2 "$signature_root/CodexSwoop.app"
  echo "PASS local ad hoc runtime signature: $signature_root/CodexSwoop.app"
}
xcodebuild "${common[@]}" -configuration Debug -destination 'platform=macOS' \
  -parallel-testing-enabled NO -resultBundlePath "$PWD/build/XCTest-$(date -u +%Y%m%dT%H%M%SZ).xcresult" test
for configuration in Debug Release; do
  xcodebuild "${common[@]}" -configuration "$configuration" -destination 'generic/platform=macOS' \
    'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
  bundle="build/DerivedData/Build/Products/$configuration/CodexSwoop.app"
  verify_bundle "$bundle" "$configuration"
done
archive="$PWD/build/archives/CodexSwoop-$(date -u +%Y%m%dT%H%M%SZ).xcarchive"
xcodebuild "${common[@]}" -configuration Release -destination 'generic/platform=macOS' \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO -archivePath "$archive" archive
bundle="$archive/Products/Applications/CodexSwoop.app"
verify_bundle "$bundle" Archive
echo 'PASS native XCTest, universal Debug/Release and unsigned Archive; distribution signing remains separate'

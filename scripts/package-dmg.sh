#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh release
application="$PWD/build/release/CodexSwoop.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$application/Contents/Info.plist")"
case "$version" in ''|*[!0-9A-Za-z._-]*) echo 'Invalid artifact version' >&2; exit 1;; esac
architecture="$(uname -m)"
mkdir -p build/dmg
staging="$(mktemp -d "$PWD/build/dmg/.contents-XXXXXX")"
trap 'rm -rf "$staging"' EXIT
/usr/bin/ditto "$application" "$staging/CodexSwoop.app"
ln -s /Applications "$staging/Applications"
codesign --verify --strict "$staging/CodexSwoop.app"
artifact="$PWD/build/dmg/CodexSwoop-$version-$architecture-local.dmg"
# Local ad-hoc signed, unnotarized test artifact. No Gatekeeper or quarantine changes.
hdiutil create -volname CodexSwoop -srcfolder "$staging" -format UDZO -ov "$artifact"
hdiutil verify "$artifact"
echo "Local test DMG: $artifact"

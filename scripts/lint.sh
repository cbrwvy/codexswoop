#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Dependency-free formatting floor; deliberately avoids a cosmetic rewrite of existing Swift.
find Sources Tests scripts docs .github -type f \( -name '*.swift' -o -name '*.sh' -o -name '*.md' -o -name '*.yml' \) -print0 |
  xargs -0 awk '
    /[ \t]+$/ { print FILENAME ":" FNR ": trailing whitespace"; failed=1 }
    /^(<<<<<<< |=======|>>>>>>> )/ { print FILENAME ":" FNR ": conflict marker"; failed=1 }
    END { exit failed }
  '
awk '/[ \t]+$/ { print FILENAME ":" FNR ": trailing whitespace"; failed=1 } END { exit failed }' Package.swift README.md
for script in scripts/*.sh; do bash -n "$script"; done
plutil -lint Resources/Info.plist CodexSwoop.xcodeproj/project.pbxproj
echo 'PASS formatting floor, shell syntax, and project plists'

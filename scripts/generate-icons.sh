#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/cache/clang
export CLANG_MODULE_CACHE_PATH="$PWD/build/cache/clang"
swift scripts/generate-icon.swift
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
swift scripts/check-icons.swift
echo 'Generated Dual Spark 02 ICNS, asset catalogs, SVG masters and build/branding/dual-spark/Preview.png.'

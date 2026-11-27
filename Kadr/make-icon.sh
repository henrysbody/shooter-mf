#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/icon"
source "$PROJECT_DIR/scripts/toolchain.sh"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
    -sdk "$SDK_PATH" -module-cache-path "$MODULE_CACHE" \
    ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} "$PROJECT_DIR/Resources/MakeIcon.swift" \
    -o "$BUILD_DIR/MakeIcon"
"$BUILD_DIR/MakeIcon" "$BUILD_DIR/AppIcon.iconset" "$PROJECT_DIR/Resources/AppIcon.icns"
echo "Updated Resources/AppIcon.icns"

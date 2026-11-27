#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/tests"
source "$PROJECT_DIR/scripts/toolchain.sh"
mkdir -p "$BUILD_DIR/Fonts"
cp "$PROJECT_DIR"/Sources/Kadr/Fonts/*.ttf "$BUILD_DIR/Fonts/"

xcrun swiftc \
    -swift-version 5 \
    -target "$(uname -m)-apple-macosx14.0" \
    -sdk "$SDK_PATH" \
    -module-cache-path "$MODULE_CACHE" \
    ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} \
    "$PROJECT_DIR/Sources/Kadr/CanvasView.swift" \
    "$PROJECT_DIR/Sources/Kadr/ChalkStroke.swift" \
    "$PROJECT_DIR/Sources/Kadr/EditorTypography.swift" \
    "$PROJECT_DIR/Sources/Kadr/EditorPreferences.swift" \
    "$PROJECT_DIR/Tests/CanvasTests.swift" \
    -o "$BUILD_DIR/CanvasTests"
"$BUILD_DIR/CanvasTests" "$@"

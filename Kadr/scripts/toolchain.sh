#!/bin/bash
# Shared compiler configuration. Callers set PROJECT_DIR and BUILD_DIR first.
SDK_PATH="${KADR_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
MODULE_CACHE="${KADR_MODULE_CACHE:-$BUILD_DIR/ModuleCache}"
mkdir -p "$BUILD_DIR"

# A few mixed Command Line Tools installations ship duplicate SwiftBridging
# module maps. Hide the obsolete map for this process without modifying the SDK.
SWIFTC_PATH="$(xcrun --find swiftc)"
SWIFT_INCLUDE="$(cd "$(dirname "$SWIFTC_PATH")/../include/swift" && pwd)"
EXTRA_FLAGS=()
if [[ -f "$SWIFT_INCLUDE/module.modulemap" && -f "$SWIFT_INCLUDE/bridging.modulemap" ]] && \
   /usr/bin/grep -q 'module SwiftBridging' "$SWIFT_INCLUDE/module.modulemap" && \
   /usr/bin/grep -q 'module SwiftBridging' "$SWIFT_INCLUDE/bridging.modulemap"; then
    touch "$BUILD_DIR/empty.modulemap"
    /usr/bin/python3 - "$SWIFT_INCLUDE/module.modulemap" "$BUILD_DIR/empty.modulemap" "$BUILD_DIR/toolchain-overlay.json" <<'PY'
import json
import sys
with open(sys.argv[3], "w") as output:
    json.dump({"version": 0, "case-sensitive": True, "roots": [
        {"type": "file", "name": sys.argv[1], "external-contents": sys.argv[2]}
    ]}, output)
PY
    EXTRA_FLAGS=(-vfsoverlay "$BUILD_DIR/toolchain-overlay.json")
fi

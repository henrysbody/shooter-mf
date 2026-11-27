#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$(cd "$PROJECT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/bundle"
APP_DIR="$OUTPUT_DIR/Shooter MF.app"
ARCHIVE="$OUTPUT_DIR/Shooter MF-macOS.zip"
ARCH="$(uname -m)"
UNIVERSAL=false
ADHOC=false

for argument in "$@"; do
    case "$argument" in
        --universal) UNIVERSAL=true ;;
        --adhoc) ADHOC=true ;;
        --help|-h)
            echo "Usage: ./build.sh [--universal] [--adhoc]"
            echo "Default: stable certificate identity from configure-signing.sh or KADR_SIGN_IDENTITY."
            echo "--adhoc: explicit disposable development signature; screen permissions may not persist."
            exit 0
            ;;
        *)
            echo "Usage: ./build.sh [--universal] [--adhoc]" >&2
            exit 2
            ;;
    esac
done

source "$PROJECT_DIR/scripts/signing.sh"
if $ADHOC; then
    SIGN_IDENTITY="-"
    echo "Signing mode: explicit ad hoc development build."
else
    kadr_resolve_signing_identity
    SIGN_IDENTITY="$KADR_RESOLVED_SIGN_IDENTITY"
    echo "Signing mode: stable certificate identity $SIGN_IDENTITY."
fi
source "$PROJECT_DIR/scripts/toolchain.sh"

compile_arch() {
    local target_arch="$1"
    echo "Building Kadr for $target_arch…"
    xcrun swiftc \
        -swift-version 5 \
        -O \
        -module-name Kadr \
        -module-cache-path "$MODULE_CACHE" \
        ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} \
        -target "$target_arch-apple-macosx14.0" \
        -sdk "$SDK_PATH" \
        -framework AppKit \
        -framework Carbon \
        -framework ScreenCaptureKit \
        "$PROJECT_DIR"/Sources/Kadr/*.swift \
        -o "$BUILD_DIR/Kadr-$target_arch"
}

if $UNIVERSAL; then
    compile_arch arm64
    compile_arch x86_64
    xcrun lipo -create "$BUILD_DIR/Kadr-arm64" "$BUILD_DIR/Kadr-x86_64" -output "$BUILD_DIR/Kadr"
else
    compile_arch "$ARCH"
    cp "$BUILD_DIR/Kadr-$ARCH" "$BUILD_DIR/Kadr"
fi

# Sign outside Documents: cloud File Providers can add Finder metadata there
# while codesign is running. The final ZIP excludes that metadata entirely.
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kadr-bundle.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/Shooter MF.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BUILD_DIR/Kadr" "$STAGED_APP/Contents/MacOS/Kadr"
cp "$PROJECT_DIR/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
/usr/bin/ditto --norsrc "$PROJECT_DIR/Sources/Kadr/Fonts" "$STAGED_APP/Contents/Resources/Fonts"
chmod +x "$STAGED_APP/Contents/MacOS/Kadr"
/usr/bin/xattr -cr "$STAGED_APP"
/usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
    --identifier com.kadr.screenshot "$STAGED_APP"
if $ADHOC; then
    /usr/bin/codesign --verify --strict "$STAGED_APP"
else
    kadr_verify_stable_signature "$STAGED_APP" "$SIGN_IDENTITY"
    echo "Verified: stable certificate-bound identity, com.kadr.screenshot, no cdhash requirement."
fi
/usr/bin/ditto -c -k --norsrc --keepParent "$STAGED_APP" "$ARCHIVE"
# Only replace this script's generated application bundle.
rm -rf "$APP_DIR"
/usr/bin/ditto --norsrc "$STAGED_APP" "$APP_DIR"
echo "Ready: $APP_DIR"
echo "Archive: $ARCHIVE"

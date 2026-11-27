#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$PROJECT_DIR/scripts/signing.sh"
if [[ $# -gt 1 ]]; then
    echo 'Usage: ./verify-signing.sh ["path/to/Shooter MF.app"]' >&2
    exit 2
fi
APP_PATH="${1:-$PROJECT_DIR/../Shooter MF.app}"
if [[ ! -f "$APP_PATH/Contents/Info.plist" ]]; then
    kadr_signing_error "application bundle not found: $APP_PATH"
    exit 1
fi
kadr_resolve_signing_identity
IDENTITY="$KADR_RESOLVED_SIGN_IDENTITY"

# Only disposable copies are changed; the original app and installed app stay put.
VERIFY_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/kadr-signing-check.XXXXXX")"
trap 'rm -rf "$VERIFY_DIRECTORY"' EXIT
SOURCE_APP="$VERIFY_DIRECTORY/Source.app"
# File Providers may attach unsigned Finder metadata to a valid bundle in
# Documents. Verify the unchanged contents in a clean temporary copy first.
/usr/bin/ditto --norsrc "$APP_PATH" "$SOURCE_APP"
kadr_verify_stable_signature "$SOURCE_APP" "$IDENTITY"
FIRST_APP="$VERIFY_DIRECTORY/First.app"
SECOND_APP="$VERIFY_DIRECTORY/Second.app"
/usr/bin/ditto --norsrc "$SOURCE_APP" "$FIRST_APP"
/usr/bin/ditto --norsrc "$SOURCE_APP" "$SECOND_APP"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 900000001' "$FIRST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 900000002' "$SECOND_APP/Contents/Info.plist"
for variant in "$FIRST_APP" "$SECOND_APP"; do
    /usr/bin/xattr -cr "$variant"
    /usr/bin/codesign --force --sign "$IDENTITY" --timestamp=none \
        --identifier com.kadr.screenshot "$variant"
    kadr_verify_stable_signature "$variant" "$IDENTITY"
done
kadr_designated_requirement "$FIRST_APP" > "$VERIFY_DIRECTORY/first.requirement"
kadr_designated_requirement "$SECOND_APP" > "$VERIFY_DIRECTORY/second.requirement"
if ! /usr/bin/cmp -s "$VERIFY_DIRECTORY/first.requirement" "$VERIFY_DIRECTORY/second.requirement"; then
    kadr_signing_error "the two versions have different designated requirements."
    exit 1
fi
/usr/bin/codesign --verify --strict -R "$VERIFY_DIRECTORY/first.requirement" "$SECOND_APP"
/usr/bin/codesign --verify --strict -R "$VERIFY_DIRECTORY/second.requirement" "$FIRST_APP"
FIRST_HASH="$(/usr/bin/codesign -d --verbose=4 "$FIRST_APP" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')"
SECOND_HASH="$(/usr/bin/codesign -d --verbose=4 "$SECOND_APP" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')"
if [[ -z "$FIRST_HASH" || -z "$SECOND_HASH" || "$FIRST_HASH" == "$SECOND_HASH" ]]; then
    kadr_signing_error "expected two distinct CodeDirectory hashes for the test versions."
    exit 1
fi
echo "Verified: two different CDHashes, one certificate-bound designated requirement."
echo "Both versions satisfy each other's requirement and the configured leaf certificate."

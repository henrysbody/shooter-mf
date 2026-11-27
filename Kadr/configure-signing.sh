#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$PROJECT_DIR/scripts/signing.sh"

if [[ $# -ne 1 ]]; then
    echo "Usage: ./configure-signing.sh <certificate-SHA1>" >&2
    echo "Uses an existing valid code-signing identity; creates no certificate or key." >&2
    exit 2
fi

IDENTITY="$(kadr_normalize_signing_identity "$1")"
kadr_require_signing_identity "$IDENTITY"
CONFIG_PATH="$(kadr_signing_config_path)"
if [[ -d "$CONFIG_PATH" ]]; then
    kadr_signing_error "configuration path is a directory: $CONFIG_PATH"
    exit 1
fi
CONFIG_DIRECTORY="$(dirname "$CONFIG_PATH")"
umask 077
mkdir -p "$CONFIG_DIRECTORY"
TEMP_CONFIG="$(mktemp "$CONFIG_DIRECTORY/.signing-identity.XXXXXX")"
trap 'rm -f "$TEMP_CONFIG"' EXIT
printf '%s\n' "$IDENTITY" > "$TEMP_CONFIG"
chmod 600 "$TEMP_CONFIG"
mv -f "$TEMP_CONFIG" "$CONFIG_PATH"
echo "Saved stable signing identity to: $CONFIG_PATH"
echo "The certificate and private key remain in your keychain."

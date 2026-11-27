#!/bin/bash
# Shared signing helpers. This file only reads identity data and the keychain;
# it never creates certificates, imports keys, or changes keychain settings.

kadr_signing_error() {
    printf 'Kadr signing: %s\n' "$*" >&2
}

kadr_normalize_signing_identity() {
    local candidate="$1"
    if [[ ! "$candidate" =~ ^[[:xdigit:]]{40}$ ]]; then
        kadr_signing_error "identity must be exactly 40 hexadecimal characters (the certificate SHA1)."
        return 1
    fi
    printf '%s' "$candidate" | /usr/bin/tr '[:lower:]' '[:upper:]'
}

kadr_require_signing_identity() {
    local identity="$1"
    local identities
    if ! identities="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null)"; then
        kadr_signing_error "could not read valid code-signing identities from the keychain."
        return 1
    fi
    if ! printf '%s\n' "$identities" | /usr/bin/awk -v wanted="$identity" \
        'toupper($2) == wanted { found = 1 } END { exit !found }'; then
        kadr_signing_error "the configured certificate SHA1 is not a valid available code-signing identity."
        kadr_signing_error "check the certificate and its private key in Keychain Access, then run ./configure-signing.sh <SHA1>."
        return 1
    fi
}

kadr_signing_config_path() {
    printf '%s' "${KADR_SIGN_CONFIG:-$HOME/Library/Application Support/Kadr/signing-identity}"
}

kadr_resolve_signing_identity() {
    local candidate=""
    local config_path
    local line=""
    local line_count=0
    if [[ "${KADR_SIGN_IDENTITY+x}" == x ]]; then
        candidate="$KADR_SIGN_IDENTITY"
    else
        config_path="$(kadr_signing_config_path)"
        if [[ ! -f "$config_path" || ! -r "$config_path" ]]; then
            kadr_signing_error "no readable signing identity configuration at: $config_path"
            kadr_signing_error "run ./configure-signing.sh <SHA1> for an existing code-signing certificate."
            kadr_signing_error "for a disposable development build, explicitly pass --adhoc."
            return 1
        fi
        # Read as data, never source the configuration as shell code.
        while IFS= read -r line || [[ -n "$line" ]]; do
            line_count=$((line_count + 1))
            if [[ "$line_count" -gt 1 ]]; then
                kadr_signing_error "configuration must contain exactly one SHA1 line."
                return 1
            fi
            candidate="$line"
        done < "$config_path"
        if [[ "$line_count" -ne 1 ]]; then
            kadr_signing_error "signing identity configuration is empty."
            return 1
        fi
    fi
    KADR_RESOLVED_SIGN_IDENTITY="$(kadr_normalize_signing_identity "$candidate")" || return 1
    kadr_require_signing_identity "$KADR_RESOLVED_SIGN_IDENTITY"
}

kadr_designated_requirement() {
    local app_path="$1"
    local details
    local requirement
    if ! details="$(/usr/bin/codesign -d -r- "$app_path" 2>&1)"; then
        kadr_signing_error "could not inspect the designated requirement of: $app_path"
        return 1
    fi
    requirement="$(printf '%s\n' "$details" | /usr/bin/sed -nE \
        's/^#?[[:space:]]*designated[[:space:]]*=>[[:space:]]*//p')"
    if [[ -z "$requirement" ]]; then
        kadr_signing_error "the application has no readable designated requirement."
        return 1
    fi
    printf '%s\n' "$requirement"
}

kadr_verify_stable_signature() {
    local app_path="$1"
    local identity="$2"
    local requirement
    requirement="$(kadr_designated_requirement "$app_path")" || return 1
    if [[ "$requirement" == *cdhash* ]]; then
        kadr_signing_error "refusing a version-specific cdhash designated requirement."
        return 1
    fi
    if [[ "$requirement" != *'identifier "com.kadr.screenshot"'* && \
          "$requirement" != *'identifier com.kadr.screenshot'* ]]; then
        kadr_signing_error "the designated requirement must contain the Kadr bundle identifier."
        return 1
    fi
    if [[ "$requirement" != *anchor* && "$requirement" != *certificate* ]]; then
        kadr_signing_error "the designated requirement must be bound to a signing certificate."
        return 1
    fi
    /usr/bin/codesign --verify --strict \
        -R="identifier \"com.kadr.screenshot\" and certificate leaf = H\"$identity\"" \
        "$app_path"
}

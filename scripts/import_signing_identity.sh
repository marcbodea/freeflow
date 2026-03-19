#!/bin/bash
set -euo pipefail

: "${DEVELOPER_ID_CERTIFICATE_BASE64:?DEVELOPER_ID_CERTIFICATE_BASE64 is required}"
: "${DEVELOPER_ID_CERTIFICATE_PASSWORD:?DEVELOPER_ID_CERTIFICATE_PASSWORD is required}"

TEMP_DIR="${RUNNER_TEMP:-/tmp}"
CERTIFICATE_PATH="$TEMP_DIR/freeflow-developer-id.p12"
KEYCHAIN_PATH="$TEMP_DIR/freeflow-signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 20)"

echo "$DEVELOPER_ID_CERTIFICATE_BASE64" | base64 --decode > "$CERTIFICATE_PATH"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

security import "$CERTIFICATE_PATH" \
  -P "$DEVELOPER_ID_CERTIFICATE_PASSWORD" \
  -A \
  -t cert \
  -f pkcs12 \
  -k "$KEYCHAIN_PATH"

security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$KEYCHAIN_PASSWORD" \
  "$KEYCHAIN_PATH"

security list-keychains -d user -s "$KEYCHAIN_PATH" $(security list-keychains -d user | tr -d '"')

IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" | head -1 | sed 's/.*"\(.*\)".*/\1/')"

rm -f "$CERTIFICATE_PATH"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "CODESIGN_IDENTITY=$IDENTITY"
    echo "KEYCHAIN_PATH=$KEYCHAIN_PATH"
  } >> "$GITHUB_ENV"
fi

printf 'export CODESIGN_IDENTITY=%q\n' "$IDENTITY"
printf 'export KEYCHAIN_PATH=%q\n' "$KEYCHAIN_PATH"


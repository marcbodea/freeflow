#!/bin/bash
set -euo pipefail

DMG_PATH="${1:?path to DMG is required}"

if [[ ! -f "$DMG_PATH" || ! -r "$DMG_PATH" ]]; then
  echo "DMG path is missing or unreadable: $DMG_PATH" >&2
  exit 1
fi

: "${APPLE_ID:?APPLE_ID is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
: "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD is required}"

xcrun notarytool submit "$DMG_PATH" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_PASSWORD" \
  --wait

xcrun stapler staple "$DMG_PATH"

echo "Notarized and stapled $DMG_PATH"

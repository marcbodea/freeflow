#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_PATH="${1:-$BUILD_DIR/FreeFlow.app}"
DMG_PATH="${2:-$BUILD_DIR/FreeFlow.dmg}"
STAGING_DIR="$BUILD_DIR/dmg-staging"

rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/FreeFlow.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "FreeFlow" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$STAGING_DIR"

echo "Created $DMG_PATH"


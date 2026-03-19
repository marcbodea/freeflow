#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
DERIVED_DATA_PATH="$BUILD_DIR/DerivedDataRelease"
ARCHIVE_PATH="$BUILD_DIR/FreeFlow.xcarchive"
APP_PATH="$BUILD_DIR/FreeFlow.app"
ZIP_PATH="$BUILD_DIR/FreeFlow.app.zip"

mkdir -p "$BUILD_DIR"
rm -rf "$ARCHIVE_PATH" "$APP_PATH" "$ZIP_PATH"

XCODEBUILD_ARGS=(
  -project "$ROOT_DIR/FreeFlow.xcodeproj"
  -scheme "FreeFlow Release"
  -configuration Release
  -derivedDataPath "$DERIVED_DATA_PATH"
  -archivePath "$ARCHIVE_PATH"
  archive
)

if [[ -n "${FREEFLOW_BUILD_TAG:-}" ]]; then
  XCODEBUILD_ARGS+=("FREEFLOW_BUILD_TAG=$FREEFLOW_BUILD_TAG")
fi

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  XCODEBUILD_ARGS+=("CODE_SIGN_IDENTITY=$CODESIGN_IDENTITY")
  if [[ -n "${APPLE_TEAM_ID:-}" ]]; then
    XCODEBUILD_ARGS+=("DEVELOPMENT_TEAM=$APPLE_TEAM_ID")
  fi
else
  XCODEBUILD_ARGS+=("CODE_SIGNING_ALLOWED=NO")
fi

xcodebuild "${XCODEBUILD_ARGS[@]}"

cp -R "$ARCHIVE_PATH/Products/Applications/FreeFlow.app" "$APP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Created $APP_PATH"
echo "Created $ZIP_PATH"

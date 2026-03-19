#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
DERIVED_DATA_PATH="$BUILD_DIR/DerivedDataDev"

mkdir -p "$BUILD_DIR"

xcodebuild \
  -project "$ROOT_DIR/FreeFlow.xcodeproj" \
  -scheme "FreeFlow Dev" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
  build

echo "Built $BUILD_DIR/FreeFlow Dev.app"

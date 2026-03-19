#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_PATH="$ROOT_DIR/Config/Base.xcconfig"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Missing $CONFIG_PATH" >&2
  exit 1
fi

marketing_version="$(sed -n 's/^MARKETING_VERSION = //p' "$CONFIG_PATH" | head -1 | tr -d '[:space:]')"
build_number="$(sed -n 's/^CURRENT_PROJECT_VERSION = //p' "$CONFIG_PATH" | head -1 | tr -d '[:space:]')"

if [[ -z "$marketing_version" || -z "$build_number" ]]; then
  echo "Failed to read version metadata from $CONFIG_PATH" >&2
  exit 1
fi

release_tag="v${marketing_version}-b${build_number}"

command="${1:-current}"

case "$command" in
  current)
    printf 'MARKETING_VERSION=%s\n' "$marketing_version"
    printf 'CURRENT_PROJECT_VERSION=%s\n' "$build_number"
    printf 'RELEASE_TAG=%s\n' "$release_tag"
    ;;
  marketing)
    printf '%s\n' "$marketing_version"
    ;;
  build)
    printf '%s\n' "$build_number"
    ;;
  tag)
    printf '%s\n' "$release_tag"
    ;;
  *)
    echo "Usage: $0 [current|marketing|build|tag]" >&2
    exit 1
    ;;
esac

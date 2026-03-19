#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_PATH="$ROOT_DIR/Config/Base.xcconfig"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Missing $CONFIG_PATH" >&2
  exit 1
fi

extract_config_value() {
  local key="$1"
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$CONFIG_PATH" | sed -E 's/[[:space:]]+$//' | head -1
}

marketing_version="$(extract_config_value MARKETING_VERSION)"
build_number="$(extract_config_value CURRENT_PROJECT_VERSION)"

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

#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_NAME="SyncClipboard-Swift"
PROJECT_PATH="$ROOT_DIR/${APP_NAME}.xcodeproj"
SCHEME_NAME="$APP_NAME"
MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
BUILD_VERSION="${BUILD_VERSION:-$(date +%Y%m%d%H%M%S)}"
RUN_ID="$(date +%Y%m%d%H%M%S)-$$"
ZIP_PATH="$DIST_DIR/${APP_NAME}-${MARKETING_VERSION}-macOS.zip"
APP_BUNDLE="$DIST_DIR/${APP_NAME}.app"

if [[ -n "${BUILD_ROOT:-}" ]]; then
  TEMP_BUILD_ROOT=0
else
  BUILD_ROOT="$(mktemp -d "$ROOT_DIR/.xcodebuild-package-run.XXXXXX")"
  TEMP_BUILD_ROOT=1
fi

DERIVED_DATA_PATH="$BUILD_ROOT/derived"
ARCHIVE_PATH="$BUILD_ROOT/archives/${APP_NAME}.xcarchive"
ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app"

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
}

stash_existing_path() {
  local artifact_path="$1"
  local label="$2"

  if [[ ! -e "$artifact_path" ]]; then
    return
  fi

  if rm -rf "$artifact_path" 2>/dev/null; then
    return
  fi

  local parent_dir="$(dirname "$artifact_path")"
  local base_name="$(basename "$artifact_path")"
  local stash_dir="$parent_dir/.stale-artifacts"
  local backup_path="$stash_dir/${base_name}.${RUN_ID}"

  mkdir -p "$stash_dir"
  mv "$artifact_path" "$backup_path"
  echo "Moved existing $label aside: $backup_path" >&2
}

finish() {
  local exit_code=$?

  if [[ $exit_code -ne 0 ]]; then
    echo "Packaging failed." >&2
    echo "Build root retained for inspection: $BUILD_ROOT" >&2
    return $exit_code
  fi

  if [[ "$TEMP_BUILD_ROOT" == "1" && "${KEEP_BUILD_ROOT:-0}" != "1" ]]; then
    rm -rf "$BUILD_ROOT" 2>/dev/null || true
  else
    echo "Build root retained at: $BUILD_ROOT"
  fi

  return 0
}

trap finish EXIT

require_command xcodegen
require_command xcodebuild
require_command codesign
require_command ditto
require_command mktemp

cd "$ROOT_DIR"

xcodegen generate

mkdir -p "$DIST_DIR"
mkdir -p "$(dirname "$ARCHIVE_PATH")"

stash_existing_path "$DERIVED_DATA_PATH" "derived data"
stash_existing_path "$ARCHIVE_PATH" "archive"
stash_existing_path "$APP_BUNDLE" "app bundle"
stash_existing_path "$ZIP_PATH" "zip archive"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_VERSION" \
  archive \
  -archivePath "$ARCHIVE_PATH"

if [[ ! -d "$ARCHIVED_APP" ]]; then
  echo "Archived app not found at: $ARCHIVED_APP" >&2
  exit 1
fi

ditto "$ARCHIVED_APP" "$APP_BUNDLE"

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "App bundle: $APP_BUNDLE"
echo "ZIP archive: $ZIP_PATH"

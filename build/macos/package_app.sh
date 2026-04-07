#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/.xcodebuild-package}"
DERIVED_DATA_PATH="$BUILD_ROOT/derived"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_NAME="SyncClipboard-Swift"
PROJECT_PATH="$ROOT_DIR/${APP_NAME}.xcodeproj"
SCHEME_NAME="$APP_NAME"
ARCHIVE_PATH="$BUILD_ROOT/archives/${APP_NAME}.xcarchive"
ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app"
APP_BUNDLE="$DIST_DIR/${APP_NAME}.app"
MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
BUILD_VERSION="${BUILD_VERSION:-$(date +%Y%m%d%H%M%S)}"
ZIP_PATH="$DIST_DIR/${APP_NAME}-${MARKETING_VERSION}-macOS.zip"

cd "$ROOT_DIR"

xcodegen generate

rm -rf "$ARCHIVE_PATH" "$APP_BUNDLE" "$ZIP_PATH"
mkdir -p "$DIST_DIR"

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

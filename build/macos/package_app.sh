#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/.xcodebuild-package}"
DERIVED_DATA_PATH="$BUILD_ROOT/derived"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_NAME="SyncClipboard-Swift"
SCHEME_NAME="$APP_NAME"
EXECUTABLE_NAME="$APP_NAME"
ARCHIVE_PATH="$BUILD_ROOT/archives/${APP_NAME}.xcarchive"
APP_BUNDLE="$DIST_DIR/${APP_NAME}.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
TEMPLATE_PLIST="$ROOT_DIR/build/macos/Info.plist.template"
ICON_SOURCE="$ROOT_DIR/build/macos/icon.icns"
ARCHIVED_BINARY="$ARCHIVE_PATH/Products/usr/local/bin/${EXECUTABLE_NAME}"
MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
BUILD_VERSION="${BUILD_VERSION:-$(date +%Y%m%d%H%M%S)}"
ZIP_PATH="$DIST_DIR/${APP_NAME}-${MARKETING_VERSION}-macOS.zip"

rm -rf "$ARCHIVE_PATH" "$APP_BUNDLE" "$ZIP_PATH"
mkdir -p "$DIST_DIR" "$APP_MACOS" "$APP_RESOURCES"

xcodebuild \
  -scheme "$SCHEME_NAME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  archive \
  -archivePath "$ARCHIVE_PATH"

if [[ ! -f "$ARCHIVED_BINARY" ]]; then
  echo "Archived binary not found at: $ARCHIVED_BINARY" >&2
  exit 1
fi

cp "$ARCHIVED_BINARY" "$APP_MACOS/$EXECUTABLE_NAME"
chmod +x "$APP_MACOS/$EXECUTABLE_NAME"

if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$APP_RESOURCES/icon.icns"
fi

sed \
  -e "s/__MARKETING_VERSION__/$MARKETING_VERSION/g" \
  -e "s/__BUILD_VERSION__/$BUILD_VERSION/g" \
  "$TEMPLATE_PLIST" > "$APP_CONTENTS/Info.plist"

printf 'APPL????' > "$APP_CONTENTS/PkgInfo"

codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "App bundle: $APP_BUNDLE"
echo "ZIP archive: $ZIP_PATH"

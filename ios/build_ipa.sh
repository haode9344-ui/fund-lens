#!/bin/sh
set -eu

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/FundLens.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"

TEAM_ID="${TEAM_ID:-}"
BUNDLE_ID="${BUNDLE_ID:-com.local.FundLens}"

rm -rf "$BUILD_DIR"
mkdir -p "$EXPORT_PATH"

EXTRA_SETTINGS="PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID"
if [ -n "$TEAM_ID" ]; then
  EXTRA_SETTINGS="$EXTRA_SETTINGS DEVELOPMENT_TEAM=$TEAM_ID"
fi

xcodebuild archive \
  -project "$PROJECT_DIR/FundLens.xcodeproj" \
  -scheme FundLens \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  $EXTRA_SETTINGS

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$PROJECT_DIR/exportOptions.plist"

echo "IPA generated under: $EXPORT_PATH"

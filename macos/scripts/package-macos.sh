#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-${VERSION:-0.0.1}}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
BUILD_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/media-shuttle-release"
ARTIFACTS="$ROOT/artifacts"
APP="$BUILD_ROOT/Media Shuttle.app"
IDENTITY="${CODE_SIGN_IDENTITY:--}"

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT" "$ARTIFACTS"

BUILD_ARGS=(
    --package-path "$ROOT"
    --scratch-path "$BUILD_ROOT/swift"
    --configuration release
    --arch arm64
    --arch x86_64
)

swift build "${BUILD_ARGS[@]}"
BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/MediaShuttle" "$APP/Contents/MacOS/MediaShuttle"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
sed \
    -e "s/__VERSION__/$VERSION/g" \
    -e "s/__BUILD__/$BUILD_NUMBER/g" \
    "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"

plutil -lint "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

DMG="$ARTIFACTS/MediaShuttle-v$VERSION-macOS-universal.dmg"
STAGING="$BUILD_ROOT/dmg-staging"
rm -f "$DMG" "$ARTIFACTS/SHA256SUMS-macos.txt"
rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Media Shuttle.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "Media Shuttle" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG"

codesign --force --sign "$IDENTITY" "$DMG"
codesign --verify --verbose=2 "$DMG"

(
    cd "$ARTIFACTS"
    shasum -a 256 "$(basename "$DMG")" > SHA256SUMS-macos.txt
)

printf 'Created %s\n' "$DMG"

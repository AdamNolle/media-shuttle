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

# Compile the Icon Composer document into the bundle. actool emits Assets.car, which
# CFBundleIconName resolves through and which is what makes this a native icon on
# macOS 26 and newer — the system draws the document's own layers and applies the
# material, dark and tinted treatments rather than scaling a flat bitmap. It also
# emits an icns from the same document as the fallback for older systems, so the two
# can never drift apart the way a separately generated one would.
ICON_DOC="$ROOT/Resources/MediaShuttle.icon"
ICON_PLIST="$BUILD_ROOT/icon-partial.plist"
xcrun actool \
    --output-format human-readable-text \
    --notices --warnings \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --target-device mac \
    --app-icon MediaShuttle \
    --output-partial-info-plist "$ICON_PLIST" \
    --compile "$APP/Contents/Resources" \
    "$ICON_DOC"

if [[ ! -f "$APP/Contents/Resources/Assets.car" ]]; then
    print -u2 "actool produced no Assets.car from $ICON_DOC. Xcode 26 or newer is required."
    exit 1
fi

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

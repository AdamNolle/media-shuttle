#!/bin/zsh
# Renders Resources/MediaShuttle.icon (an Icon Composer document) into the
# iconset and AppIcon.icns that the app bundle ships. Run after editing the
# icon in Icon Composer.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$ROOT/Resources/MediaShuttle.icon"
ICONSET="$ROOT/Resources/AppIcon.iconset"
ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"

if [[ ! -x "$ICTOOL" ]]; then
    print -u2 "ictool not found. Install Xcode 26 or newer (it ships Icon Composer)."
    exit 1
fi

render() {
    "$ICTOOL" "$DOC" --export-image --output-file "$2" \
        --platform macOS --rendition Default --width "$1" --height "$1" --scale 1 >/dev/null
}

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

render 16   "$ICONSET/icon_16x16.png"
render 32   "$ICONSET/icon_16x16@2x.png"
render 32   "$ICONSET/icon_32x32.png"
render 64   "$ICONSET/icon_32x32@2x.png"
render 128  "$ICONSET/icon_128x128.png"
render 256  "$ICONSET/icon_128x128@2x.png"
render 256  "$ICONSET/icon_256x256.png"
render 512  "$ICONSET/icon_256x256@2x.png"
render 512  "$ICONSET/icon_512x512.png"
render 1024 "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
cp "$ICONSET/icon_512x512@2x.png" "$ROOT/Resources/AppIcon-1024.png"

printf 'Built %s\n' "$ROOT/Resources/AppIcon.icns"

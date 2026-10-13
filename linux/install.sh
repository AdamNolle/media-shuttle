#!/bin/sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if ! python3 -c 'import gi, cairo; gi.require_version("Gtk", "3.0"); from gi.repository import Gtk; import gi._gi_cairo' >/dev/null 2>&1; then
    printf 'Media Shuttle requires Python 3, PyGObject, GTK 3 introspection, and Python Cairo bindings.\n' >&2
    exit 1
fi
data_home=${XDG_DATA_HOME:-"$HOME/.local/share"}
app_dir="$data_home/media-shuttle"
bin_dir="$HOME/.local/bin"
desktop_dir="$data_home/applications"
icon_dir="$data_home/icons/hicolor/scalable/apps"

mkdir -p "$app_dir/media_shuttle" "$bin_dir" "$desktop_dir" "$icon_dir"
cp "$here/media_shuttle/"*.py "$app_dir/media_shuttle/"
cp -R "$here/assets" "$app_dir/"
cp "$here/media-shuttle" "$app_dir/media-shuttle"
chmod 755 "$app_dir/media-shuttle"
ln -sf "$app_dir/media-shuttle" "$bin_dir/media-shuttle"
cp "$here/assets/media-shuttle.svg" "$icon_dir/media-shuttle.svg"

cat > "$desktop_dir/media-shuttle.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Media Shuttle
Comment=Verified camera-card ingest for Linux
Exec="$bin_dir/media-shuttle"
Icon=media-shuttle
Terminal=false
Categories=Graphics;Photography;Utility;
StartupNotify=true
EOF

printf 'Installed Media Shuttle. Run %s/media-shuttle\n' "$bin_dir"

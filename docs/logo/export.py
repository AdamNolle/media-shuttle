"""Renders the icon tiles to PNGs, and assembles a Windows .ico from them.

Each size is rendered from the mark built for it rather than by downscaling the detailed
one, which is the whole point of having three: a 16px render of the full mark is mud.

    python -m pip install playwright && python -m playwright install chromium
    python docs/logo/export.py

Writes docs/logo/export/. For macOS, the same PNGs feed an .iconset:

    mkdir MediaShuttle.iconset && cp export/icon_*.png MediaShuttle.iconset/
    iconutil -c icns MediaShuttle.iconset
"""

import pathlib

from playwright.sync_api import sync_playwright

HERE = pathlib.Path(__file__).parent
OUT = HERE / "export"

# The board text is 38 units on a 1024 canvas, so it is under five pixels tall at 128
# and pure noise below that. The full mark therefore starts at 96, where the text at
# least reads as a line of type on a destination board even if not as words.
SIZES = {
    16: "micro", 20: "micro", 24: "micro",
    32: "small", 40: "small", 48: "small", 64: "small",
    96: "full", 128: "full", 256: "full", 512: "full", 1024: "full",
}
TILES = {
    "full": "media-shuttle-icon.svg",
    "small": "media-shuttle-icon-small.svg",
    "micro": "media-shuttle-icon-micro.svg",
}
ICO_SIZES = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]

# What macOS asks an .iconset to contain, and which render feeds each slot.
ICONSET = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}

# The .icns chunk type for each pixel size. ic04/ic05 are the 16 and 32 slots that
# modern macOS reads as PNG; ic07 upward have always been PNG.
ICNS_TYPES = {
    16: b"icp4", 32: b"icp5", 64: b"icp6", 128: b"ic07",
    256: b"ic08", 512: b"ic09", 1024: b"ic10",
}


def main() -> None:
    OUT.mkdir(exist_ok=True)
    written = []

    with sync_playwright() as play:
        browser = play.chromium.launch(args=["--force-color-profile=srgb"])
        for size, variant in SIZES.items():
            page = browser.new_page(
                viewport={"width": size, "height": size}, device_scale_factor=1
            )
            # The SVG is authored at 1024 and drawn here at the target size, so each
            # size is rasterised once at its own size rather than resampled from a
            # larger one. A standalone SVG document has no <head> to style, hence the
            # one-line HTML shell.
            shell = HERE / f"_export_{size}.html"
            shell.write_text(
                "<!doctype html><meta charset=utf-8>"
                "<style>html,body{margin:0;padding:0;background:transparent}</style>"
                f'<img src="{TILES[variant]}" width="{size}" height="{size}">',
                encoding="utf-8",
            )
            page.goto(shell.as_uri())
            page.wait_for_timeout(150)
            target = OUT / f"icon_{size}.png"
            page.screenshot(path=str(target), omit_background=True)
            page.close()
            shell.unlink()
            written.append((size, variant, target))
            print(f"{target.name:16} {variant}")
        browser.close()

    ico = OUT / "MediaShuttle.ico"
    ico.write_bytes(assemble_ico([OUT / f"icon_{s}.png" for s in ICO_SIZES]))
    print(f"\n{ico.name} ({ico.stat().st_size:,} bytes, {len(ICO_SIZES)} sizes)")

    iconset = OUT / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    for name, size in ICONSET.items():
        (iconset / name).write_bytes((OUT / f"icon_{size}.png").read_bytes())
    icns = OUT / "AppIcon.icns"
    icns.write_bytes(assemble_icns(iconset))
    print(f"{icns.name} ({icns.stat().st_size:,} bytes) and {iconset.name}/")


def assemble_icns(iconset: pathlib.Path) -> bytes:
    """Packs the iconset into an .icns.

    `iconutil` would do this, but it only exists on macOS and the icon is authored on
    Windows. The container is simple enough to write: a magic word, a total length, and
    one length-prefixed chunk per size, each holding a PNG verbatim.
    """
    import struct

    chunks = b""
    for size, kind in sorted(ICNS_TYPES.items()):
        source = iconset / ("icon_%dx%d.png" % (size, size))
        if not source.exists():  # 64 and 1024 only exist as @2x renditions.
            source = iconset / ("icon_%dx%d@2x.png" % (size // 2, size // 2))
        blob = source.read_bytes()
        chunks += kind + struct.pack(">I", len(blob) + 8) + blob

    return b"icns" + struct.pack(">I", len(chunks) + 8) + chunks


def assemble_ico(pngs: list[pathlib.Path]) -> bytes:
    """Packs already-rendered PNGs into an .ico, one frame each.

    Written out by hand rather than handed to an imaging library, because every library
    route resamples one source image to the other sizes — which throws away the whole
    point of rendering 16px from the micro mark and 256px from the detailed one.
    PNG-compressed frames are what Windows has read since Vista.
    """
    import struct

    blobs = [png.read_bytes() for png in pngs]
    sizes = [int(png.stem.split("_")[1]) for png in pngs]

    header = struct.pack("<HHH", 0, 1, len(blobs))
    offset = len(header) + 16 * len(blobs)
    directory, payload = b"", b""
    for size, blob in zip(sizes, blobs):
        directory += struct.pack(
            "<BBBBHHII",
            size if size < 256 else 0,  # 0 stands for 256 in this field.
            size if size < 256 else 0,
            0, 0, 1, 32, len(blob), offset,
        )
        payload += blob
        offset += len(blob)
    return header + directory + payload


if __name__ == "__main__":
    main()

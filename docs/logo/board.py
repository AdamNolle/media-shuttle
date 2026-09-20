"""Sets the destination-board text as outlines inside the mark.

A logo that ships live <text> is not really a logo: it renders differently, or not at
all, wherever the font is missing, and every icon export would depend on the machine
doing the exporting. This converts the board to a single <path>.

Cascadia Mono is used because it is SIL OFL 1.1, which permits the outlines being
embedded here, and because it matches the monospaced type the app's own interface uses.

    python docs/logo/board.py                 # re-set the current text
    python docs/logo/board.py "MEDIA SHUTTLE" # change what the board says
"""

import pathlib
import re
import sys

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

HERE = pathlib.Path(__file__).parent
MARK = HERE / "media-shuttle-bus.svg"
FONT = pathlib.Path(r"C:\Windows\Fonts\CascadiaMono.ttf")

# Matches the panel: the board is centred on the yellow body's interior and sits on the
# baseline between the two rub rails.
CENTRE_X = 394.0
BASELINE_Y = 538.0
SIZE = 38.0
TRACKING = 3.6
WEIGHT = 700

START = "<!-- board:start -->"
END = "<!-- board:end -->"


def outline(text: str) -> str:
    font = TTFont(FONT)
    if "fvar" in font:
        from fontTools.varLib.instancer import instantiateVariableFont

        font = instantiateVariableFont(font, {"wght": WEIGHT}, inplace=True)

    upem = font["head"].unitsPerEm
    cmap = font.getBestCmap()
    glyphs = font.getGlyphSet()
    metrics = font["hmtx"]
    scale = SIZE / upem

    names = [cmap[ord(ch)] for ch in text]
    advances = [metrics[name][0] * scale for name in names]
    width = sum(advances) + TRACKING * (len(names) - 1)

    pen = SVGPathPen(glyphs)
    x = CENTRE_X - width / 2
    for name, advance in zip(names, advances):
        # The y axis is flipped: fonts grow upward from the baseline, SVG grows downward.
        glyphs[name].draw(TransformPen(pen, (scale, 0, 0, -scale, x, BASELINE_Y)))
        x += advance + TRACKING

    return pen.getCommands()


def main() -> None:
    text = sys.argv[1] if len(sys.argv) > 1 else current_text()
    path = outline(text)
    block = (
        f'{START}\n'
        f'  <!-- "{text}" in Cascadia Mono {WEIGHT}, outlined by docs/logo/board.py. -->\n'
        f'  <path d="{path}" fill="#0F1014"/>\n'
        f'  {END}'
    )

    svg = MARK.read_text(encoding="utf-8")
    if START in svg:
        svg = re.sub(re.escape(START) + r".*?" + re.escape(END), block, svg, flags=re.S)
    else:
        svg = re.sub(r"<text\b.*?</text>", block, svg, flags=re.S)
    MARK.write_text(svg, encoding="utf-8")
    print(f'board set to "{text}" ({len(path):,} bytes of path)')


def current_text() -> str:
    svg = MARK.read_text(encoding="utf-8")
    found = re.search(r'<!-- "([^"]+)" in Cascadia Mono', svg)
    return found.group(1) if found else "MEDIA EXPRESS"


if __name__ == "__main__":
    main()

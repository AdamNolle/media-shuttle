"""Builds the README banner: the mark, the wordmark, and the line under it.

The wordmark is outlined from Cascadia Mono the same way the destination board is, so
the banner does not depend on a font being installed wherever it is rendered.

    python docs/logo/banner.py     # writes docs/banner.svg and docs/banner.png
"""

import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import board  # noqa: E402  (same directory, and it owns the font handling)

HERE = pathlib.Path(__file__).parent
DOCS = HERE.parent
WIDTH, HEIGHT = 1280, 340


def text_path(value: str, size: float, tracking: float, x: float, baseline: float) -> str:
    """Left-aligned outlines, by borrowing the board's centred setter and shifting it."""
    board.SIZE, board.TRACKING = size, tracking
    board.CENTRE_X, board.BASELINE_Y = 0.0, 0.0
    path = board.outline(value)
    # `outline` centres on x=0, so the run starts at minus half its width.
    width = run_width(value, size, tracking)
    return f'<g transform="translate({x + width / 2} {baseline})"><path d="{path}" /></g>'


def run_width(value: str, size: float, tracking: float) -> float:
    from fontTools.ttLib import TTFont

    font = TTFont(board.FONT)
    upem = font["head"].unitsPerEm
    cmap, metrics = font.getBestCmap(), font["hmtx"]
    advance = sum(metrics[cmap[ord(ch)]][0] for ch in value) * size / upem
    return advance + tracking * (len(value) - 1)


def main() -> None:
    mark = (HERE / "media-shuttle-bus.svg").read_text(encoding="utf-8")
    defs = re.search(r"<defs>(.*?)</defs>", mark, re.S).group(1).rstrip()
    body = mark[mark.index("</defs>") + 7:]
    body = body[: body.rindex("</svg>")].strip()

    wordmark = text_path("MEDIA SHUTTLE", 58, 6.5, 470, 176)
    tagline = text_path("VERIFIED CAMERA INGEST FOR MACOS AND WINDOWS", 19, 3.4, 474, 222)

    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {WIDTH} {HEIGHT}" width="{WIDTH}" height="{HEIGHT}" role="img" aria-label="Media Shuttle — verified camera ingest for macOS and Windows">
  <defs>
    <linearGradient id="bg" x1="0.1" y1="0" x2="0.9" y2="1">
      <stop offset="0" stop-color="#EC5C4D"/>
      <stop offset="0.5" stop-color="#D2372F"/>
      <stop offset="1" stop-color="#88201A"/>
    </linearGradient>
    <radialGradient id="pool" cx="0.22" cy="0.55" r="0.42">
      <stop offset="0" stop-color="#FFD9A0" stop-opacity="0.22"/>
      <stop offset="1" stop-color="#FFD9A0" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.14"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
{defs}
  </defs>

  <rect width="{WIDTH}" height="{HEIGHT}" rx="26" fill="url(#bg)"/>
  <rect width="{WIDTH}" height="{HEIGHT}" rx="26" fill="url(#pool)"/>
  <rect width="{WIDTH}" height="160" rx="26" fill="url(#sheen)"/>

  <!-- The mark, on its own 1024 grid, dropped into the left third. -->
  <g transform="translate(21 -22.3) scale(0.38)">
{body}
  </g>

  <g fill="#FFFFFF">
{wordmark}
  </g>
  <g fill="#FFFFFF" opacity="0.72">
{tagline}
  </g>
</svg>
'''
    (DOCS / "banner.svg").write_text(svg, encoding="utf-8")
    print(f"wrote banner.svg ({len(svg):,} bytes)")


if __name__ == "__main__":
    main()

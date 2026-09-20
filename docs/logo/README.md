# Media Shuttle — logo

An SD card drawn as a shuttle bus. The card's chamfered corner does double duty as the
raked windshield, and the driver's window repeats the same 45° cut, so the one detail
that makes the shape an SD card is also what makes it a bus.

Open `preview.html` in a browser to see everything below at once.

## The three marks

One drawing does not survive from 1024px to 16px, so there are three, all on the same
grid — same silhouette, same body rectangle, same wheel centres. Nothing shifts when a
size boundary swaps one for another.

| File | For | Carries |
| --- | --- | --- |
| `media-shuttle-bus.svg` | 96px and up | Everything: board text, grille, roof hatch, wheel bolts, two rub rails |
| `media-shuttle-bus-small.svg` | 32–64px | Three windows, one rail, plain rims. No text, grille or hatch |
| `media-shuttle-bus-micro.svg` | 16–24px | Body, one window band, two wheels, flat fills |

Each is also built onto an icon tile — `media-shuttle-icon*.svg` — which adds the
rounded container, its gradient and the light behind the bus. The smaller marks sit
*larger* within their tiles: at 16px the container's corners already separate the icon
from its surroundings, so margin is wasted pixels.

## Rebuilding

The tiles and the board text are generated. The mark is the only thing edited by hand.

```bash
python docs/logo/board.py                   # re-outline the destination board
python docs/logo/board.py "MEDIA SHUTTLE"   # or change what it says
python docs/logo/build.py                   # rebuild all three tiles
python docs/logo/build.py slate             # a different container colour
python docs/logo/export.py                  # PNGs at every size, plus a .ico
```

`build.py` carries five container presets — `red` (default), `sky`, `slate`, `dusk`,
`night`. Red is the app's own accent and sits mid-luminance, so it holds the black
chassis without swallowing it. The two dark presets are kept only for comparison: the
bus is black *and* yellow, so a dark container loses the chassis entirely and the icon
becomes a floating yellow blob at small sizes.

The board is set in Cascadia Mono and converted to outlines by `board.py`, so the logo
does not depend on a font being installed anywhere. Cascadia is SIL OFL 1.1, which
permits that.

`export.py` renders each size from the mark built for it rather than downscaling the
detailed one, and writes the `.ico` itself — every imaging library resamples one source
image to the other sizes, which would throw the three-mark system away.

## Colour

| | |
| --- | --- |
| Body | `#FFDC2E` → `#E9A800` |
| Chassis | `#2B2E36` → `#0B0C10` |
| Glass | `#232C3C` → `#080A0F` |
| Contacts | `#F6D072` / `#A97620` |
| Tile (red) | `#EC5C4D` → `#88201A` |

## Where it is used

Both apps now carry this mark: `windows/src/MediaShuttle/Assets/MediaShuttle.ico`,
`macos/Resources/AppIcon.icns` and its `.iconset`, the Icon Composer document in
`macos/Resources/MediaShuttle.icon`, and the in-window marks in `MainWindow.xaml` and
`AppMark.swift`. Re-run `export.py` and copy the results over after changing the mark.

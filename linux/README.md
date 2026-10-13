# Media Shuttle — Native Linux Edition

Native, pixel-accurate Linux port of Media Shuttle built in modern C (C11/GNU11) with GTK4, Cairo, Pango, and Cascadia Mono.

Maintains 100% contract safety and visual parity with the macOS and Windows editions:
- **Independent SHA-256 verification**: Source and destination files are hashed independently before publishing.
- **Atomic file publishing**: Copies write to hidden temporary files first, renamed only on valid hash match.
- **Strict card erase gating**: Erase card button stays locked until every remaining camera file matches verified copies.
- **Pixel-perfect native GUI**: Custom Cairo rendering matching the bespoke design system (dark/light themes, square toggles, Cascadia Mono typography, segmented card contents bar, status badge pill, operations metrics grid).
- **Automated Visual QA**: `--screenshot` flag for headless, deterministic offscreen rendering and diffing.

---

## Prerequisites

Install build dependencies on Ubuntu/Debian:
```bash
sudo apt update
sudo apt install build-essential pkg-config libgtk-4-dev libpango1.0-dev libcairo2-dev libfontconfig1-dev libfreetype6-dev
```

Or on Fedora:
```bash
sudo dnf install gcc make pkgconf gtk4-devel pango-devel cairo-devel fontconfig-devel freetype-devel
```

---

## Building

From the repository root or the `linux/` directory:

```bash
# Build the native GUI application (produces build/media-shuttle)
make -C linux app

# Build and run the 45-assertion core safety test suite
make -C linux tests
linux/build/core-tests

# Build offscreen render QA tool
make -C linux build/render-offscreen
```

---

## Running

```bash
# Standard interactive app
./linux/build/media-shuttle

# Visual preview mode (loads sample camera card and verified session)
./linux/build/media-shuttle --preview

# Headless offscreen render directly to PNG (useful for CI/QA)
./linux/build/media-shuttle --screenshot artifacts/ui-qa/linux-preview.png

# Force light theme
./linux/build/media-shuttle --theme light
```

---

## Architecture

- `src/core/`:
  - `sha256.c`: Streaming SHA-256 implementation with hex digest formatting.
  - `classifier.c`: Media item classification (`DCIM`, `M4ROOT`, `PRIVATE`, JPEGs, RAWs, videos, camera artifacts).
  - `card_detector.c`: Linux volume mount and camera card detection (`/media`, `/run/media`, `/mnt`, `statvfs`).
  - `transfer.c`: Collision resolution, atomic temp write, independent SHA-256 verification.
  - `wipe.c`: Safe erasing with rescan verification.
  - `state.c`: Session JSON storage and settings persistence.
  - `logger.c`: Application event and transfer logging.
- `src/ui/`:
  - `theme.c`, `theme.h`: Dark (`#101012`) and Light (`#E8E8EA`) color tokens matching Windows/macOS.
  - `font.c`, `font.h`: Subpixel Cascadia Mono font rendering and text measurement with Pango/Cairo.
  - `draw.c`, `draw.h`: Pixel-calibrated vector icons, buttons, segmented progress bar, square toggles, modals.
  - `layout.c`, `layout.h`: Hit testing and responsive layout coordinate models.
  - `app.c`, `app.h`: GTK4 window, drawing area, gestures, background transfer and wipe threads.
  - `main.c`: CLI flag parsing and application entry point.
- `tests/test_core.c`: 45 safety assertions covering classification, presence tracking, atomic transfer, collision renaming, duplicate detection, and erase locking.
- `tools/`: Offscreen rendering, diff heatmap generation, and visual inspection scripts.

#!/usr/bin/env python3
"""Measure geometry in a capture so the Linux renderer can be checked against it."""
import sys
from PIL import Image

def px(img, x, y):
    return img.getpixel((x, y))

def hexs(c):
    return "#%02X%02X%02X" % c[:3]

def main(path):
    img = Image.open(path).convert("RGB")
    w, h = img.size
    print(f"{path}: {w} x {h}")

    # Header height: walk down the left edge until the chrome colour stops.
    chrome = px(img, 2, 2)
    header = 0
    for y in range(h):
        if px(img, 2, y) != chrome:
            header = y
            break
    print(f"  top-left colour {hexs(chrome)} ends at row {header}")

    # Sidebar width: walk right along a row inside the body.
    row = max(header + 40, h // 2)
    base = px(img, 2, row)
    sidebar = 0
    for x in range(w):
        if px(img, x, row) != base:
            sidebar = x
            break
    print(f"  row {row} colour {hexs(base)} ends at col {sidebar}")

    # Hairline rows near the top of the body.
    print("  first 12 distinct colours down column 2:")
    seen = []
    for y in range(h):
        c = px(img, 2, y)
        if not seen or seen[-1][1] != c:
            seen.append((y, c))
        if len(seen) > 12:
            break
    for y, c in seen:
        print(f"    row {y}: {hexs(c)}")

    print("  first 12 distinct colours across column row:", row)
    seen = []
    for x in range(w):
        c = px(img, x, row)
        if not seen or seen[-1][1] != c:
            seen.append((x, c))
        if len(seen) > 12:
            break
    for x, c in seen:
        print(f"    col {x}: {hexs(c)}")

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "artifacts/ui-qa/windows-client.png")

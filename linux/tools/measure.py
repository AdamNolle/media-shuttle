#!/usr/bin/env python3
"""Find the app-drawn content bounds in a capture and report the layout geometry."""
import sys
from PIL import Image

BLACK = (0, 0, 0)

def main(path):
    img = Image.open(path).convert("RGB")
    w, h = img.size
    px = img.load()

    rows = [y for y in range(h) if any(px[x, y] != BLACK for x in range(w))]
    cols = [x for x in range(w) if any(px[x, y] != BLACK for y in range(h))]
    if not rows or not cols:
        print(f"{path}: {w} x {h} — nothing but black, PrintWindow produced no content")
        return

    left, right, top, bottom = min(cols), max(cols), min(rows), max(rows)
    print(f"{path}: {w} x {h}")
    print(f"  content bounds: ({left},{top}) -> ({right},{bottom})  = {right-left+1} x {bottom-top+1}")
    print(f"  inset: left {left}, top {top}, right {w-1-right}, bottom {h-1-bottom}")

    # Header height: first row below the top inset where the colour stops being chrome.
    chrome = px[left + 2, top + 2]
    header = None
    for y in range(top, bottom + 1):
        if px[left + 2, y] != chrome:
            header = y - top
            break
    print(f"  chrome at top-left {('#%02X%02X%02X' % chrome)} ends after {header} rows")

    # Sidebar width along a row in the body.
    row = top + (bottom - top) // 2
    base = px[left + 2, row]
    sidebar = None
    for x in range(left, right + 1):
        if px[x, row] != base:
            sidebar = x - left
            break
    print(f"  body row {row}: {('#%02X%02X%02X' % base)} ends after {sidebar} cols")

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "artifacts/ui-qa/windows-client.png")

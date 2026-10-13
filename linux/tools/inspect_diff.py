#!/usr/bin/env python3
import sys
from PIL import Image
import numpy as np

def examine():
    w_img = Image.open('artifacts/ui-qa/windows-client.png').convert('RGB')
    l_img = Image.open('artifacts/ui-qa/linux-preview.png').convert('RGB')
    w_arr = np.array(w_img)
    l_arr = np.array(l_img)

    print("=== HEADER ===")
    print("Windows row 24 x=700..736 (settings button area):")
    for x in range(710, 730):
        print(f"x={x}: win={list(w_arr[24, x])} lin={list(l_arr[24, x])}")

    print("\nWindows row 24 x=850..896 (caption controls area):")
    for x in range(850, 896, 5):
        print(f"x={x}: win={list(w_arr[24, x])} lin={list(l_arr[24, x])}")

    # Let's check where the settings icon is in windows
    # Settings icon is glyph E713 (gear)
    # Search for non-background pixels in row 10..38, cols 650..800
    bg = w_arr[24, 600]
    gear_pixels = []
    for y in range(10, 38):
        for x in range(650, 800):
            if np.max(np.abs(w_arr[y, x].astype(int) - bg.astype(int))) > 20:
                gear_pixels.append((x, y))
    if gear_pixels:
        xs = [p[0] for p in gear_pixels]
        ys = [p[1] for p in gear_pixels]
        print(f"Windows gear glyph bounds: x={min(xs)}..{max(xs)}, y={min(ys)}..{max(ys)}")

    gear_lin = []
    for y in range(10, 38):
        for x in range(650, 896):
            if np.max(np.abs(l_arr[y, x].astype(int) - bg.astype(int))) > 20:
                gear_lin.append((x, y))
    if gear_lin:
        xs = [p[0] for p in gear_lin]
        ys = [p[1] for p in gear_lin]
        print(f"Linux gear glyph bounds: x={min(xs)}..{max(xs)}, y={min(ys)}..{max(ys)}")

    # Check StatusPill bounds
    pill_w = []
    pill_bg = [26, 26, 29] # panel background
    for y in range(10, 40):
        for x in range(150, 450):
            # check border or background
            if np.max(np.abs(w_arr[y, x].astype(int) - bg.astype(int))) > 5:
                pill_w.append((x, y))
    if pill_w:
        xs = [p[0] for p in pill_w]
        ys = [p[1] for p in pill_w]
        print(f"Windows StatusPill bounds: x={min(xs)}..{max(xs)}, y={min(ys)}..{max(ys)}")

    pill_l = []
    for y in range(10, 40):
        for x in range(150, 450):
            if np.max(np.abs(l_arr[y, x].astype(int) - bg.astype(int))) > 5:
                pill_l.append((x, y))
    if pill_l:
        xs = [p[0] for p in pill_l]
        ys = [p[1] for p in pill_l]
        print(f"Linux StatusPill bounds: x={min(xs)}..{max(xs)}, y={min(ys)}..{max(ys)}")

    # Check App Logo bounds
    logo_w = []
    for y in range(10, 40):
        for x in range(0, 100):
            if np.max(np.abs(w_arr[y, x].astype(int) - bg.astype(int))) > 15:
                logo_w.append((x, y))
    if logo_w:
        xs = [p[0] for p in logo_w]
        ys = [p[1] for p in logo_w]
        print(f"Windows Logo/Title bounds: x={min(xs)}..{max(xs)}, y={min(ys)}..{max(ys)}")

if __name__ == "__main__":
    examine()

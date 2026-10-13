#!/usr/bin/env python3
import os
from PIL import Image, ImageChops, ImageDraw, ImageFont
import numpy as np

def make_side_by_side():
    win = Image.open('artifacts/ui-qa/windows-client.png').convert('RGB')
    lin = Image.open('artifacts/ui-qa/linux-preview.png').convert('RGB')

    w, h = win.size
    # Diff
    diff = ImageChops.difference(win, lin)
    # Amplify diff for visibility
    diff_arr = np.array(diff).astype(float)
    amp_arr = np.clip(diff_arr * 3.0, 0, 255).astype(np.uint8)
    amp_diff = Image.fromarray(amp_arr)

    # 3-panel image: Windows | Linux | Diff (amplified 3x)
    total_w = w * 3 + 40
    total_h = h + 60
    sheet = Image.new('RGB', (total_w, total_h), (18, 18, 20))
    draw = ImageDraw.Draw(sheet)

    # Paste
    sheet.paste(win, (10, 45))
    sheet.paste(lin, (w + 20, 45))
    sheet.paste(amp_diff, (w * 2 + 30, 45))

    draw.text((10, 15), "Windows Reference (WinUI 3)", fill=(220, 220, 220))
    draw.text((w + 20, 15), "Native Linux (GTK4 + Cairo + Cascadia Mono)", fill=(95, 208, 138))
    draw.text((w * 2 + 30, 15), "Visual Diff Heatmap (3x amplified)", fill=(255, 106, 94))

    out_path = 'artifacts/ui-qa/linux-vs-windows.png'
    sheet.save(out_path)
    print(f"Generated comparison sheet: {out_path} ({total_w} x {total_h})")

def make_all_states():
    preview = Image.open('artifacts/ui-qa/linux-preview.png').convert('RGB')
    settings = Image.open('artifacts/ui-qa/linux-settings.png').convert('RGB')
    confirm = Image.open('artifacts/ui-qa/linux-confirm.png').convert('RGB')
    light = Image.open('artifacts/ui-qa/linux-light.png').convert('RGB')

    w, h = preview.size
    grid_w = w * 2 + 30
    grid_h = h * 2 + 80
    sheet = Image.new('RGB', (grid_w, grid_h), (16, 16, 18))
    draw = ImageDraw.Draw(sheet)

    sheet.paste(preview, (10, 35))
    sheet.paste(settings, (w + 20, 35))
    sheet.paste(confirm, (10, h + 70))
    sheet.paste(light, (w + 20, h + 70))

    draw.text((10, 10), "1. Main View (Dark Mode · Verified Transfer)", fill=(220, 220, 220))
    draw.text((w + 20, 10), "2. Settings Flyout (Appearance & Behavior Toggles)", fill=(220, 220, 220))
    draw.text((10, h + 45), "3. Erase Card Confirmation Modal (Safety Gating)", fill=(220, 220, 220))
    draw.text((w + 20, h + 45), "4. Main View (Light Mode · Warm Off-White)", fill=(220, 220, 220))

    out_path = 'artifacts/ui-qa/linux-all-states.png'
    sheet.save(out_path)
    print(f"Generated states sheet: {out_path} ({grid_w} x {grid_h})")

if __name__ == '__main__':
    make_side_by_side()
    make_all_states()

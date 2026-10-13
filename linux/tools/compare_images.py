#!/usr/bin/env python3
import sys
from PIL import Image, ImageChops
import numpy as np

def compare(ref_path, test_path, diff_path="artifacts/ui-qa/diff.png"):
    ref = Image.open(ref_path).convert("RGB")
    test = Image.open(test_path).convert("RGB")
    print(f"Ref ({ref_path}): {ref.size}")
    print(f"Test ({test_path}): {test.size}")

    if ref.size != test.size:
        print(f"Sizes do not match: {ref.size} vs {test.size}")
        return

    diff = ImageChops.difference(ref, test)
    diff.save(diff_path)
    arr = np.array(diff)
    print(f"Diff saved to {diff_path}")
    print(f"Max diff: {arr.max()}, Mean diff: {arr.mean():.4f}")

    # Pixel match within tolerance
    diff_pixels = np.count_nonzero(arr > 10) // 3
    total_pixels = ref.size[0] * ref.size[1]
    pct_match = (1.0 - (diff_pixels / total_pixels)) * 100.0
    print(f"Pixels with delta > 10: {diff_pixels} / {total_pixels} ({100.0 - pct_match:.2f}% mismatch, {pct_match:.2f}% match)")

if __name__ == "__main__":
    ref = sys.argv[1] if len(sys.argv) > 1 else "artifacts/ui-qa/windows-client.png"
    test = sys.argv[2] if len(sys.argv) > 2 else "artifacts/ui-qa/linux-preview.png"
    compare(ref, test)

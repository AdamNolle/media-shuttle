#!/usr/bin/env python3
"""Rewrite a 16-bit-per-channel PNG as 8-bit, in place.

Icon Composer's ictool exports 16 bits per channel. An app icon has no use for the
extra precision, and it costs roughly three and a half times the file size across the
whole iconset and the .icns built from it. Nothing in the toolchain that ships with
macOS converts depth — sips preserves it — so this does the one conversion needed:
truncate each 16-bit sample to its high byte. That is exact for any value ictool
produces from an 8-bit-per-channel source, which is what the mark's SVG is.

Only the colour types ictool emits are handled; anything else is left alone.
"""

import struct
import sys
import zlib

# Bytes per pixel for the colour types this handles, at 16 bits per sample.
CHANNELS = {0: 1, 2: 3, 4: 2, 6: 4}


def unfilter(data: bytes, width: int, height: int, bpp: int) -> bytearray:
    """Reverse the per-scanline filters, returning raw samples without filter bytes."""
    stride = width * bpp
    out = bytearray()
    previous = bytearray(stride)
    position = 0
    for _ in range(height):
        filter_type = data[position]
        position += 1
        line = bytearray(data[position:position + stride])
        position += stride
        if filter_type == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif filter_type == 2:
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 0xFF
        elif filter_type == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 0xFF
        elif filter_type == 4:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                up = previous[i]
                up_left = previous[i - bpp] if i >= bpp else 0
                estimate = left + up - up_left
                da, db, dc = abs(estimate - left), abs(estimate - up), abs(estimate - up_left)
                nearest = left if (da <= db and da <= dc) else (up if db <= dc else up_left)
                line[i] = (line[i] + nearest) & 0xFF
        elif filter_type != 0:
            raise ValueError(f"unknown PNG filter type {filter_type}")
        out += line
        previous = line
    return out


def chunk(tag: bytes, payload: bytes) -> bytes:
    return (struct.pack(">I", len(payload)) + tag + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))


def convert(path: str) -> bool:
    raw = open(path, "rb").read()
    if raw[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path} is not a PNG")

    width, height, depth, colour, compression, filter_method, interlace = struct.unpack(
        ">IIBBBBB", raw[16:29])
    if depth != 16 or colour not in CHANNELS or interlace != 0:
        return False

    idat = b"".join(
        raw[i + 8:i + 8 + struct.unpack(">I", raw[i:i + 4])[0]]
        for i in iter_chunks(raw, b"IDAT"))

    channels = CHANNELS[colour]
    samples = unfilter(zlib.decompress(idat), width, height, channels * 2)

    # Keep the high byte of every 16-bit sample.
    eight = samples[0::2]

    stride = width * channels
    scanlines = bytearray()
    for row in range(height):
        scanlines.append(0)  # filter type None
        scanlines += eight[row * stride:(row + 1) * stride]

    header = struct.pack(">IIBBBBB", width, height, 8, colour, compression, filter_method, 0)
    out = (raw[:8]
           + chunk(b"IHDR", header)
           + chunk(b"IDAT", zlib.compress(bytes(scanlines), 9))
           + chunk(b"IEND", b""))
    open(path, "wb").write(out)
    return True


def iter_chunks(raw: bytes, want: bytes):
    position = 8
    while position < len(raw):
        length = struct.unpack(">I", raw[position:position + 4])[0]
        if raw[position + 4:position + 8] == want:
            yield position
        position += 12 + length


if __name__ == "__main__":
    for argument in sys.argv[1:]:
        convert(argument)

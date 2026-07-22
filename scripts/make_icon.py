#!/usr/bin/env python3
"""Generate a 1024x1024 PNG icon for TokenBar.

Pure-stdlib. A single rounded-square background in one accent color, with a
centered ascending-bars glyph (echoes the "sum" SF Symbol used for the
matching menu-bar icon) - one visual idea instead of a coin + letter + line
stacked on top of each other. Rendered at 4x and box-downsampled for
antialiasing, since the previous hard per-pixel rendering had none.
"""
import struct
import sys
import zlib
from pathlib import Path

SUPERSAMPLE = 4


def _rounded_rect_coverage(x: float, y: float, cx: float, cy: float, half: float, radius: float) -> bool:
    dx = abs(x - cx) - (half - radius)
    dy = abs(y - cy) - (half - radius)
    if dx > 0 and dy > 0:
        return (dx * dx + dy * dy) <= radius * radius
    return dx <= radius and dy <= radius


def render(size: int = 1024) -> bytes:
    bg = (64, 112, 235)          # single flat accent color (blue family)
    bg_shade = (46, 84, 190)     # subtle darker tone for a gentle vertical fade
    glyph = (255, 255, 255)

    hi = size * SUPERSAMPLE
    scale = hi / 1024.0
    pixels = bytearray(hi * hi * 4)

    cx = hi / 2
    cy = hi / 2
    half = (hi - 40 * scale) / 2
    corner_radius = 220 * scale

    bar_width = 130 * scale
    bar_gap = 60 * scale
    bar_radius = bar_width / 2
    bars = [
        # (height, x_center)
        (260 * scale, cx - bar_width - bar_gap),
        (420 * scale, cx),
        (560 * scale, cx + bar_width + bar_gap),
    ]
    baseline = cy + 300 * scale

    for y in range(hi):
        row = y * hi * 4
        t = y / max(hi - 1, 1)
        r0 = int(bg[0] + (bg_shade[0] - bg[0]) * t)
        g0 = int(bg[1] + (bg_shade[1] - bg[1]) * t)
        b0 = int(bg[2] + (bg_shade[2] - bg[2]) * t)
        for x in range(hi):
            i = row + x * 4
            if not _rounded_rect_coverage(x, y, cx, cy, half, corner_radius):
                continue
            pixels[i] = r0
            pixels[i + 1] = g0
            pixels[i + 2] = b0
            pixels[i + 3] = 255

    # Each bar is a capsule: a rounded top (half-circle) over a flat-bottomed
    # rectangle sitting on the shared baseline.
    for height, bx in bars:
        top = baseline - height
        for y in range(int(top - bar_radius), int(baseline) + 1):
            if y < 0 or y >= hi:
                continue
            row = y * hi * 4
            for x in range(int(bx - bar_radius), int(bx + bar_radius) + 1):
                if x < 0 or x >= hi:
                    continue
                i = row + x * 4
                if pixels[i + 3] == 0:
                    continue
                if abs(x - bx) > bar_radius:
                    continue
                if y < top + bar_radius and (x - bx) ** 2 + (y - (top + bar_radius)) ** 2 > bar_radius * bar_radius:
                    continue
                pixels[i] = glyph[0]
                pixels[i + 1] = glyph[1]
                pixels[i + 2] = glyph[2]

    return _downsample_and_encode(hi, pixels, SUPERSAMPLE)


def _downsample_and_encode(hi: int, pixels: bytearray, factor: int) -> bytes:
    size = hi // factor
    out = bytearray(size * size * 4)
    area = factor * factor
    for oy in range(size):
        for ox in range(size):
            r = g = b = a = 0
            for sy in range(factor):
                y = oy * factor + sy
                row = y * hi * 4
                for sx in range(factor):
                    x = ox * factor + sx
                    i = row + x * 4
                    r += pixels[i]
                    g += pixels[i + 1]
                    b += pixels[i + 2]
                    a += pixels[i + 3]
            j = (oy * size + ox) * 4
            out[j] = r // area
            out[j + 1] = g // area
            out[j + 2] = b // area
            out[j + 3] = a // area
    return encode_png(size, size, bytes(out))


def encode_png(width: int, height: int, rgba: bytes) -> bytes:
    def chunk(tag: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)
        raw.extend(rgba[y * stride:(y + 1) * stride])
    idat = zlib.compress(bytes(raw), 9)
    return sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")


def main() -> None:
    if len(sys.argv) < 2:
        print("usage: make_icon.py <out.png>", file=sys.stderr)
        sys.exit(2)
    out = Path(sys.argv[1])
    out.parent.mkdir(parents=True, exist_ok=True)
    data = render(1024)
    out.write_bytes(data)
    print(f"wrote {out} ({len(data)} bytes)")


if __name__ == "__main__":
    main()

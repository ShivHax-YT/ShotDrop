#!/usr/bin/env python3
"""Rebuild ShotDrop's original geometric placeholder icon using only the stdlib."""

import json
import math
from pathlib import Path
import struct
import zlib


ROOT = Path(__file__).resolve().parent / "Assets.xcassets"
ICON = ROOT / "AppIcon.appiconset"

# A screenshot frame and downward arrow, drawn with rounded line ends.
SEGMENTS = (
    (300, 422, 300, 308), (300, 308, 414, 308),
    (610, 308, 724, 308), (724, 308, 724, 422),
    (300, 534, 300, 648), (300, 648, 380, 648),
    (644, 648, 724, 648), (724, 648, 724, 534),
    (512, 428, 512, 736), (432, 656, 512, 736),
    (512, 736, 592, 656),
)


def clamp(value):
    return max(0.0, min(1.0, value))


def line_distance(x, y, segment):
    ax, ay, bx, by = segment
    dx, dy = bx - ax, by - ay
    amount = clamp(((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy))
    return math.hypot(x - ax - amount * dx, y - ay - amount * dy)


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def png(size):
    rows = bytearray()
    unit = 1024 / size
    for row in range(size):
        rows.append(0)  # PNG filter: none.
        y = (row + 0.5) * unit
        for column in range(size):
            x = (column + 0.5) * unit
            # Signed distance to a rounded square, inset to match macOS icon padding.
            qx, qy = abs(x - 512) - 250, abs(y - 512) - 250
            distance = math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - 180
            alpha = clamp(0.5 - distance / unit)
            blend = clamp((0.45 * x + 0.55 * y - 82) / 860)
            background = tuple(a + (b - a) * blend for a, b in zip((24, 196, 196), (27, 85, 191)))
            ink_distance = min(line_distance(x, y, segment) for segment in SEGMENTS) - 27
            ink = clamp(0.5 - ink_distance / unit)
            rows.extend(round(channel + (255 - channel) * ink) for channel in background)
            rows.append(round(alpha * 255))
    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")


def main():
    ICON.mkdir(parents=True, exist_ok=True)
    info = {"author": "xcode", "version": 1}
    images = []
    sizes = set()
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            sizes.add(pixels)
            images.append({"filename": f"icon-{pixels}.png", "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
    for size in sorted(sizes):
        (ICON / f"icon-{size}.png").write_bytes(png(size))
    (ICON / "Contents.json").write_text(json.dumps({"images": images, "info": info}, indent=2) + "\n")
    (ROOT / "Contents.json").write_text(json.dumps({"info": info}, indent=2) + "\n")


if __name__ == "__main__":
    main()

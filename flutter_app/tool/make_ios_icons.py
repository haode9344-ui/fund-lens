from __future__ import annotations

import json
import math
import struct
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ICONSET = ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"


def png_bytes(size: int) -> bytes:
    rows = []
    for y in range(size):
      row = bytearray()
      for x in range(size):
        nx = x / max(size - 1, 1)
        ny = y / max(size - 1, 1)
        base_r = int(9 + 20 * nx)
        base_g = int(98 + 62 * ny)
        base_b = int(255 - 35 * ny)
        glow = math.exp(-(((nx - 0.72) ** 2 + (ny - 0.18) ** 2) / 0.07))
        r = min(255, int(base_r + glow * 82))
        g = min(255, int(base_g + glow * 96))
        b = min(255, int(base_b + glow * 16))

        cx = nx - 0.5
        cy = ny - 0.54
        ring = abs(math.sqrt(cx * cx + cy * cy) - 0.29) < 0.035
        slash = abs((ny - 0.54) - 0.55 * (nx - 0.5)) < 0.035 and 0.22 < nx < 0.82 and 0.24 < ny < 0.84
        dot = (nx - 0.36) ** 2 + (ny - 0.34) ** 2 < 0.026
        spark = abs(nx - 0.68) < 0.025 and 0.30 < ny < 0.66 or abs(ny - 0.47) < 0.025 and 0.50 < nx < 0.86
        if ring or slash or dot or spark:
          r, g, b = 255, 255, 255
        row.extend((r, g, b))
      rows.append(bytes([0]) + bytes(row))

    raw = b"".join(rows)
    def chunk(kind: bytes, data: bytes) -> bytes:
      return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (
      b"\x89PNG\r\n\x1a\n"
      + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
      + chunk(b"IDAT", zlib.compress(raw, 9))
      + chunk(b"IEND", b"")
    )


def icon_size(image: dict[str, str]) -> int:
    points = float(image["size"].split("x", 1)[0])
    scale = int(image["scale"].replace("x", ""))
    return int(points * scale)


def main() -> None:
    contents_path = ICONSET / "Contents.json"
    contents = json.loads(contents_path.read_text())
    cache: dict[int, bytes] = {}
    for image in contents["images"]:
        filename = image.get("filename")
        if not filename:
            continue
        size = icon_size(image)
        cache.setdefault(size, png_bytes(size))
        (ICONSET / filename).write_bytes(cache[size])


if __name__ == "__main__":
    main()

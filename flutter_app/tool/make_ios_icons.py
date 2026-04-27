from __future__ import annotations

import json
import math
import struct
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ICONSET = ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
ICON_ASSETS = ROOT / "tool" / "icon_assets"


def prebuilt_icon_bytes(size: int) -> bytes | None:
    return None


def png_bytes(size: int) -> bytes:
    rendered = prebuilt_icon_bytes(size)
    if rendered is not None:
      return rendered

    def distance_to_segment(px: float, py: float, ax: float, ay: float, bx: float, by: float) -> float:
      vx = bx - ax
      vy = by - ay
      wx = px - ax
      wy = py - ay
      length = vx * vx + vy * vy
      if length == 0:
        return math.sqrt((px - ax) ** 2 + (py - ay) ** 2)
      t = max(0.0, min(1.0, (wx * vx + wy * vy) / length))
      cx = ax + t * vx
      cy = ay + t * vy
      return math.sqrt((px - cx) ** 2 + (py - cy) ** 2)

    red = (244, 67, 54)
    shadow = (255, 219, 215)
    points = [
      (0.17, 0.70),
      (0.33, 0.54),
      (0.47, 0.61),
      (0.64, 0.39),
      (0.82, 0.26),
    ]
    rows = []
    for y in range(size):
      row = bytearray()
      for x in range(size):
        nx = x / max(size - 1, 1)
        ny = y / max(size - 1, 1)
        r, g, b = 255, 255, 255

        ink = 0.0
        glow = 0.0
        for index in range(len(points) - 1):
          ax, ay = points[index]
          bx, by = points[index + 1]
          distance = distance_to_segment(nx, ny, ax, ay, bx, by)
          if distance < 0.020:
            ink = max(ink, 1.0)
          elif distance < 0.032:
            ink = max(ink, 1 - (distance - 0.020) / 0.012)
          elif distance < 0.050:
            glow = max(glow, 1 - (distance - 0.032) / 0.018)

        if glow > 0:
          r = int(255 * (1 - glow) + shadow[0] * glow)
          g = int(255 * (1 - glow) + shadow[1] * glow)
          b = int(255 * (1 - glow) + shadow[2] * glow)
        if ink > 0:
          r = int(r * (1 - ink) + red[0] * ink)
          g = int(g * (1 - ink) + red[1] * ink)
          b = int(b * (1 - ink) + red[2] * ink)

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

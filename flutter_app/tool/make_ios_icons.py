from __future__ import annotations

import json
import math
import struct
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ICONSET = ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"


def png_bytes(size: int) -> bytes:
    def blend(base: tuple[int, int, int], paint: tuple[int, int, int], alpha: float) -> tuple[int, int, int]:
      alpha = max(0.0, min(1.0, alpha))
      return tuple(int(base[i] * (1 - alpha) + paint[i] * alpha) for i in range(3))

    def inside_round_rect(nx: float, ny: float, left: float, top: float, right: float, bottom: float, radius: float) -> bool:
      if nx < left or nx > right or ny < top or ny > bottom:
        return False
      cx = min(max(nx, left + radius), right - radius)
      cy = min(max(ny, top + radius), bottom - radius)
      return (nx - cx) ** 2 + (ny - cy) ** 2 <= radius ** 2

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

    line_points = [
      (0.19, 0.59),
      (0.31, 0.55),
      (0.45, 0.62),
      (0.58, 0.48),
      (0.70, 0.42),
      (0.83, 0.31),
    ]
    baseline_y = 0.53
    rows = []
    for y in range(size):
      row = bytearray()
      for x in range(size):
        nx = x / max(size - 1, 1)
        ny = y / max(size - 1, 1)
        color = (int(19 + 23 * nx), int(28 + 22 * ny), int(45 + 28 * ny))
        red_glow = math.exp(-(((nx - 0.86) ** 2 + (ny - 0.20) ** 2) / 0.045))
        green_glow = math.exp(-(((nx - 0.08) ** 2 + (ny - 0.88) ** 2) / 0.06))
        color = blend(color, (244, 67, 54), red_glow * 0.28)
        color = blend(color, (36, 138, 61), green_glow * 0.20)

        shadow = inside_round_rect(nx, ny, 0.15, 0.17, 0.89, 0.82, 0.09)
        panel = inside_round_rect(nx, ny, 0.12, 0.14, 0.86, 0.78, 0.09)
        if shadow and not panel:
          color = blend(color, (0, 0, 0), 0.22)
        if panel:
          color = blend(color, (247, 250, 255), 0.96)
          grid = (
            abs(ny - baseline_y) < 0.004 and 0.18 < nx < 0.80
            or any(abs(nx - gx) < 0.003 and 0.22 < ny < 0.70 for gx in (0.30, 0.48, 0.66))
            or any(abs(ny - gy) < 0.003 and 0.18 < nx < 0.80 for gy in (0.35, 0.68))
          )
          if grid:
            color = blend(color, (188, 198, 213), 0.62)

          for index in range(1, len(line_points)):
            ax, ay = line_points[index - 1]
            bx, by = line_points[index]
            distance = distance_to_segment(nx, ny, ax, ay, bx, by)
            width = 0.020 if size >= 180 else 0.026
            if distance < width:
              up = by <= baseline_y
              stroke = (244, 67, 54) if up else (36, 138, 61)
              color = blend(color, stroke, 1 - distance / width)

        dot_x, dot_y = line_points[-1]
        dot_distance = math.sqrt((nx - dot_x) ** 2 + (ny - dot_y) ** 2)
        ring = 0.045 < dot_distance < 0.068
        core = dot_distance < 0.034
        if ring:
          color = blend(color, (255, 190, 74), 0.92)
        if core:
          color = blend(color, (255, 255, 255), 0.98)

        r, g, b = color
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

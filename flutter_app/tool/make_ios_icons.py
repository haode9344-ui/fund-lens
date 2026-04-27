from __future__ import annotations

import json
import math
import struct
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ICONSET = ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
ICON_ASSETS = ROOT / "tool" / "icon_assets"


def font_icon_bytes(size: int) -> bytes | None:
    prebuilt = ICON_ASSETS / f"icon-{size}.png"
    if prebuilt.exists():
        return prebuilt.read_bytes()

    try:
        from PIL import Image, ImageDraw, ImageFont
    except Exception:
        return None

    font_paths = [
        Path("/System/Library/Fonts/Supplemental/Songti.ttc"),
        Path("/System/Library/Fonts/Supplemental/Kaiti.ttc"),
        Path("/System/Library/Fonts/PingFang.ttc"),
        Path("/System/Library/Fonts/STHeiti Light.ttc"),
        Path("C:/Windows/Fonts/NotoSerifSC-VF.ttf"),
        Path("C:/Windows/Fonts/NotoSansSC-VF.ttf"),
        Path("C:/Windows/Fonts/msyhbd.ttc"),
        Path("C:/Windows/Fonts/simhei.ttf"),
    ]
    font_path = next((path for path in font_paths if path.exists()), None)
    if font_path is None:
        return None

    scale = 4
    canvas_size = size * scale
    image = Image.new("RGB", (canvas_size, canvas_size), (255, 255, 255))
    draw = ImageDraw.Draw(image)
    text = "小又"
    target_width = canvas_size * 0.84
    target_height = canvas_size * 0.58
    font_size = int(canvas_size * 0.70)
    while font_size > 12:
        font = ImageFont.truetype(str(font_path), font_size)
        bbox = draw.textbbox((0, 0), text, font=font)
        width = bbox[2] - bbox[0]
        height = bbox[3] - bbox[1]
        if width <= target_width and height <= target_height:
            break
        font_size -= max(1, int(canvas_size * 0.01))

    font = ImageFont.truetype(str(font_path), font_size)
    bbox = draw.textbbox((0, 0), text, font=font)
    width = bbox[2] - bbox[0]
    height = bbox[3] - bbox[1]
    x = (canvas_size - width) / 2 - bbox[0]
    y = (canvas_size - height) / 2 - bbox[1] - canvas_size * 0.015
    draw.text((x, y), text, fill=(0, 0, 0), font=font)
    image = image.resize((size, size), Image.Resampling.LANCZOS)

    import io

    output = io.BytesIO()
    image.save(output, format="PNG", optimize=True)
    return output.getvalue()


def png_bytes(size: int) -> bytes:
    rendered = font_icon_bytes(size)
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

    strokes = [
      # 小
      (0.30, 0.20, 0.30, 0.76, 0.026),
      (0.22, 0.49, 0.12, 0.66, 0.024),
      (0.38, 0.49, 0.48, 0.66, 0.024),
      # 又
      (0.56, 0.28, 0.86, 0.28, 0.026),
      (0.60, 0.34, 0.83, 0.72, 0.028),
      (0.84, 0.34, 0.55, 0.75, 0.028),
    ]
    rows = []
    for y in range(size):
      row = bytearray()
      for x in range(size):
        nx = x / max(size - 1, 1)
        ny = y / max(size - 1, 1)
        ink = 0.0
        for ax, ay, bx, by, width in strokes:
          distance = distance_to_segment(nx, ny, ax, ay, bx, by)
          if distance < width:
            ink = max(ink, 1.0)
          elif distance < width + 0.010:
            ink = max(ink, 1 - (distance - width) / 0.010)
        value = int(255 * (1 - ink))
        r = g = b = value
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

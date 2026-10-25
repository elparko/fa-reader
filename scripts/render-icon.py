#!/usr/bin/env python3
"""Draw the Rowlight app icon and write the sizes the Mac app needs.

design/icon.svg is the vector source (a macOS squircle, transparent outside
the plate, no white margin). This script rewrites that file from the geometry
below, then paints the same geometry into the PNG sizes and the .icns.
The amber line's glow is a gaussian blur. The SVG asks for that with a
filter; the PNGs are painted here so the glow is actually in the pixels
(the rasterizer used on Linux does not apply SVG filters).

16 and 32 px stay legible: four separated bars, the third one amber.
Run via scripts/make-icon.sh after changing the numbers below.
"""

from __future__ import annotations

import math
import struct
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SVG_PATH = ROOT / "design" / "icon.svg"
ICONSET = ROOT / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
ICNS_PATH = ROOT / "Resources" / "AppIcon.icns"
PNG_1024 = ROOT / "Resources" / "AppIcon.png"

CANVAS = 1024
# Superellipse exponent. 5 is the usual macOS icon squircle (sides flatter
# than a circle, corners smoother than a circular rounded rect).
SQUIRCLE_N = 5.0

# Fractions of the canvas, measured from the concept icon's plate.
# Centers sit on pixel centers of the 16px icon (rows 3, 6, 9, 12) so the
# four lines stay separate after downscaling. The spacing matches the concept.
BAR_LEFT = 0.1863
BAR_HEIGHT = 1.15 / 16
BAR_WIDTHS = (0.498, 0.629, 0.631, 0.556)
BAR_CENTERS = (3.5 / 16, 6.5 / 16, 9.5 / 16, 12.5 / 16)
HIGHLIGHT = 2

PLATE_TOP = (0x24, 0x2A, 0x7C)  # indigo, top left
PLATE_BOTTOM = (0x4E, 0x2E, 0x9D)  # violet, bottom right
CREAM = (0xF8, 0xF1, 0xE9, 255)
AMBER_END = (0xFF, 0xB2, 0x4E)
AMBER_MID = (0xFF, 0xD7, 0x88)
GLOW = (0xFF, 0x9A, 0x2C, 255)
GLOW_SIGMA = 0.046  # fraction of the canvas
GLOW_GAIN = 1.45

ICONSET_FILES = (
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
)

# PNG-encoded icns types written by iconutil.
ICNS_TYPES = (
    (b"icp4", 16),
    (b"icp5", 32),
    (b"ic11", 32),
    (b"icp6", 64),
    (b"ic12", 64),
    (b"ic07", 128),
    (b"ic08", 256),
    (b"ic13", 256),
    (b"ic09", 512),
    (b"ic14", 512),
    (b"ic10", 1024),
)


def squircle_geom(size: int) -> tuple[float, float]:
    # Radius reaches half a pixel past the canvas so the mid-edge pixels are
    # solid. The corners still fall outside the canvas and stay transparent.
    return (size - 1) / 2, size / 2


def squircle_path(size: int = CANVAS, n: float = SQUIRCLE_N, steps: int = 180) -> str:
    c, a = squircle_geom(size)
    e = 2 / n
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = c + a * math.copysign(abs(ct) ** e, ct)
        y = c + a * math.copysign(abs(st) ** e, st)
        pts.append(f"{x:.2f},{y:.2f}")
    return "M " + " L ".join(pts) + " Z"


def bars(size: int) -> list[tuple[float, float, float, float]]:
    """(x, y, width, height) for the four capsules, top to bottom."""
    left = BAR_LEFT * size
    height = BAR_HEIGHT * size
    out = []
    for width, center in zip(BAR_WIDTHS, BAR_CENTERS):
        out.append((left, center * size - height / 2, width * size, height))
    return out


def rect_tag(x: float, y: float, w: float, h: float, fill: str, glow: bool = False) -> str:
    filt = ' filter="url(#glow)"' if glow else ""
    return (
        f'    <rect x="{x:.2f}" y="{y:.2f}" width="{w:.2f}" height="{h:.2f}" '
        f'rx="{h / 2:.2f}" fill="{fill}"{filt}/>'
    )


def write_svg() -> None:
    d = squircle_path()
    # Glow first, then the opaque lines, so the halo sits behind the type.
    ordered = []
    sharp = []
    for i, (x, y, w, h) in enumerate(bars(CANVAS)):
        if i == HIGHLIGHT:
            ordered.append(rect_tag(x, y, w, h, "#FF9A2C", glow=True))
            sharp.append(rect_tag(x, y, w, h, "url(#amber)"))
        else:
            sharp.append(rect_tag(x, y, w, h, "#F8F1E9"))
    ordered.extend(sharp)
    svg = f"""<?xml version="1.0" encoding="UTF-8"?>
<!-- Rowlight app icon. Edit scripts/render-icon.py and rerun scripts/make-icon.sh.
     The plate is a macOS squircle (superellipse n=5) on a transparent canvas.
     There is no white margin: only the corners outside the squircle are clear. -->
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="plate" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#242A7C"/>
      <stop offset="1" stop-color="#4E2E9D"/>
    </linearGradient>
    <linearGradient id="amber" x1="0" y1="0.5" x2="1" y2="0.5">
      <stop offset="0" stop-color="#FFB24E"/>
      <stop offset="0.5" stop-color="#FFD788"/>
      <stop offset="1" stop-color="#FFB24E"/>
    </linearGradient>
    <filter id="glow" x="-50%" y="-180%" width="200%" height="460%" color-interpolation-filters="sRGB">
      <feGaussianBlur stdDeviation="47"/>
    </filter>
    <clipPath id="squircle">
      <path d="{d}"/>
    </clipPath>
  </defs>
  <path d="{d}" fill="url(#plate)"/>
  <g clip-path="url(#squircle)">
{chr(10).join(ordered)}
  </g>
</svg>
"""
    SVG_PATH.parent.mkdir(parents=True, exist_ok=True)
    SVG_PATH.write_text(svg)


def squircle_mask(size: int, n: float = SQUIRCLE_N, aa: int = 3) -> Image.Image:
    big = size * aa
    c, a = squircle_geom(big)
    mask = Image.new("L", (big, big), 0)
    px = mask.load()
    for y in range(big):
        ny = abs((y - c) / a)
        ny_n = ny ** n
        if ny_n > 1:
            continue
        reach = (1 - ny_n) ** (1 / n) * a
        x0 = max(0, int(c - reach))
        x1 = min(big - 1, int(c + reach))
        for x in range(x0, x1 + 1):
            if abs((x - c) / a) ** n + ny_n <= 1:
                px[x, y] = 255
    return mask.resize((size, size), Image.Resampling.LANCZOS)


def plate_gradient(size: int) -> Image.Image:
    im = Image.new("RGBA", (size, size))
    px = im.load()
    last = size - 1
    for y in range(size):
        ty = y / last
        for x in range(size):
            t = (x / last + ty) * 0.5
            px[x, y] = tuple(int(a + (b - a) * t) for a, b in zip(PLATE_TOP, PLATE_BOTTOM)) + (255,)
    return im


def capsule_mask(size: int, box: tuple[float, float, float, float]) -> Image.Image:
    im = Image.new("L", (size, size), 0)
    x, y, w, h = box
    ImageDraw.Draw(im).rounded_rectangle([x, y, x + w, y + h], radius=h / 2, fill=255)
    return im


def paint(size: int) -> Image.Image:
    out = plate_gradient(size)
    highlight = bars(size)[HIGHLIGHT]
    shape = capsule_mask(size, highlight)
    glow_src = Image.composite(
        Image.new("RGBA", (size, size), GLOW),
        Image.new("RGBA", (size, size), (0, 0, 0, 0)),
        shape,
    )
    sigma = max(0.6, GLOW_SIGMA * size)
    blurred = glow_src.filter(ImageFilter.GaussianBlur(radius=sigma))
    r, g, b, a = blurred.split()
    a = a.point(lambda v: min(255, int(v * GLOW_GAIN)))
    out = Image.alpha_composite(out, Image.merge("RGBA", (r, g, b, a)))

    clear = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    cream = Image.new("RGBA", (size, size), CREAM)
    for i, box in enumerate(bars(size)):
        if i == HIGHLIGHT:
            continue
        out = Image.alpha_composite(out, Image.composite(cream, clear, capsule_mask(size, box)))

    x0, y0, bw, bh = highlight
    mask = capsule_mask(size, highlight)
    mp = mask.load()
    bar = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    bp = bar.load()
    y_start, y_end = max(0, int(y0) - 2), min(size, int(y0 + bh) + 3)
    x_start, x_end = max(0, int(x0) - 2), min(size, int(x0 + bw) + 3)
    for y in range(y_start, y_end):
        for x in range(x_start, x_end):
            alpha = mp[x, y]
            if not alpha:
                continue
            t = (x - x0) / bw
            t = 0.0 if t < 0 else 1.0 if t > 1 else t
            bump = math.sin(t * math.pi) ** 0.9
            bp[x, y] = (
                255,
                int(AMBER_END[1] + (AMBER_MID[1] - AMBER_END[1]) * bump),
                int(AMBER_END[2] + (AMBER_MID[2] - AMBER_END[2]) * bump),
                alpha,
            )
    out = Image.alpha_composite(out, bar)
    r, g, b, a = out.split()
    a = ImageChops.multiply(a, squircle_mask(size))
    return Image.merge("RGBA", (r, g, b, a))


def is_cream(p) -> bool:
    r, g, b, a = p
    return a > 180 and r > 210 and g > 185 and b > 160 and g > b


def is_amber(p) -> bool:
    r, g, b, a = p
    return a > 180 and r > 190 and g > 100 and r > b + 40


def bands(im: Image.Image) -> list[str]:
    px = im.load()
    w, h = im.size
    kinds = []
    for y in range(h):
        cream = amber = 0
        for x in range(w):
            p = px[x, y]
            if is_amber(p):
                amber += 1
            elif is_cream(p):
                cream += 1
        if amber + cream >= max(3, w // 8):
            kinds.append("amber" if amber > cream else "cream")
        else:
            kinds.append("")
    groups: list[str] = []
    current = ""
    for kind in kinds:
        if kind and kind != current:
            groups.append(kind)
        if not kind:
            current = ""
        else:
            current = kind
    return groups


def assert_legible(master: Image.Image) -> None:
    for size in (16, 32):
        small = master.resize((size, size), Image.Resampling.LANCZOS)
        found = bands(small)
        if found != ["cream", "cream", "amber", "cream"]:
            raise SystemExit(f"{size}px icon is not four readable lines (got {found})")
    # The plate touches the middle of each edge and leaves the corners clear.
    px = master.load()
    w, h = master.size
    for x, y in ((w // 2, 0), (w // 2, h - 1), (0, h // 2), (w - 1, h // 2)):
        if px[x, y][3] < 200:
            raise SystemExit(f"squircle does not reach the canvas edge at {(x, y)}")
    if px[0, 0][3] > 10 or px[w - 1, 0][3] > 10:
        raise SystemExit("squircle corners are not transparent")


def write_icns(pngs: dict[int, bytes]) -> None:
    chunks = []
    for ostype, size in ICNS_TYPES:
        data = pngs[size]
        chunks.append(ostype + struct.pack(">I", 8 + len(data)) + data)
    body = b"".join(chunks)
    ICNS_PATH.write_bytes(b"icns" + struct.pack(">I", 8 + len(body)) + body)


def write_iconset(master: Image.Image) -> None:
    ICONSET.mkdir(parents=True, exist_ok=True)
    # Drop the previous single-image icon so Xcode does not keep an unreferenced file.
    for stale in ICONSET.glob("*.png"):
        stale.unlink()
    pngs: dict[int, bytes] = {}
    for name, size in ICONSET_FILES:
        im = master if size == CANVAS else master.resize((size, size), Image.Resampling.LANCZOS)
        path = ICONSET / name
        im.save(path, "PNG")
        pngs[size] = path.read_bytes()
    master.save(PNG_1024, "PNG")
    pngs[CANVAS] = PNG_1024.read_bytes()
    write_icns(pngs)
    entries = []
    for name, _size in ICONSET_FILES:
        if name == "icon_16x16.png":
            point, scale = "16x16", "1x"
        elif name == "icon_16x16@2x.png":
            point, scale = "16x16", "2x"
        elif name == "icon_32x32.png":
            point, scale = "32x32", "1x"
        elif name == "icon_32x32@2x.png":
            point, scale = "32x32", "2x"
        elif name == "icon_128x128.png":
            point, scale = "128x128", "1x"
        elif name == "icon_128x128@2x.png":
            point, scale = "128x128", "2x"
        elif name == "icon_256x256.png":
            point, scale = "256x256", "1x"
        elif name == "icon_256x256@2x.png":
            point, scale = "256x256", "2x"
        elif name == "icon_512x512.png":
            point, scale = "512x512", "1x"
        else:
            point, scale = "512x512", "2x"
        entries.append(
            "    {\n"
            f'      "filename" : "{name}",\n'
            '      "idiom" : "mac",\n'
            f'      "scale" : "{scale}",\n'
            f'      "size" : "{point}"\n'
            "    }"
        )
    (ICONSET / "Contents.json").write_text(
        "{\n  \"images\" : [\n" + ",\n".join(entries) + "\n  ],\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n"
    )


def main() -> None:
    write_svg()
    master = paint(CANVAS)
    assert_legible(master)
    write_iconset(master)
    print(f"wrote {SVG_PATH.relative_to(ROOT)}")
    print(f"wrote {ICNS_PATH.relative_to(ROOT)}")
    print(f"wrote {ICONSET.relative_to(ROOT)} ({len(ICONSET_FILES)} sizes)")


if __name__ == "__main__":
    main()

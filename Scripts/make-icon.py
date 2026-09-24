#!/usr/bin/env python3
"""Builds Resources/AppIcon.icns from BrowserBarIcon.iconset/BrowserBar_1024.png.

macOS 26 and later draw app icons inside a container shape of their own. The
source art is a browser window with its own black rounded outline, drawn left
of centre on a transparent canvas, which the system shows as an off-centre
window floating on a grey plate.

So the master is rebuilt full-bleed and centred: plain header, divider and
body bands run edge to edge, only the art inside the window (camera notch,
traffic lights, address bar) is copied over, and the corners are left to the
system.
"""
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "BrowserBarIcon.iconset" / "BrowserBar_1024.png"
ICNS = ROOT / "Resources" / "AppIcon.icns"

CANVAS = 1024
# Where things sit in the source, as (left, top, right, bottom). The window is
# drawn left of centre, so the new canvas is centred on its inside.
INTERIOR = (94, 156, 826, 864)
DIVIDER = (267, 279)             # rows of the header/body divider
ART = [
    (395, 180, 525, 322),        # camera dot and the notch under the divider
    (120, 382, 800, 680),        # traffic lights and address bar
]
# Side of the square, in source pixels, that becomes the canvas; the margin
# around the interior keeps the art clear of the system's corner mask.
SQUARE = 900

SIZES = [16, 32, 64, 128, 256, 512, 1024]


def build_master(image: Image.Image) -> Image.Image:
    source = np.array(image)
    left, top, right, bottom = INTERIOR
    x0 = (left + right - SQUARE) // 2
    y0 = (top + bottom - SQUARE) // 2
    middle = (left + right) // 2

    # Plain header, divider and body, edge to edge: no outline, no rim.
    header = source[DIVIDER[0] - 20, middle - 150, :3]
    divider = source[DIVIDER[0] + 5, middle - 150, :3]
    body = source[bottom - 30, middle, :3]
    rows = np.arange(SQUARE) + y0
    colors = np.where((rows < DIVIDER[0])[:, None], header,
                      np.where((rows < DIVIDER[1])[:, None], divider, body))
    master = np.zeros((SQUARE, SQUARE, 4), dtype=np.uint8)
    master[:, :, :3] = colors[:, None, :]
    master[:, :, 3] = 255

    for l, t, r, b in ART:
        master[t - y0:b - y0, l - x0:r - x0, :3] = source[t:b, l:r, :3]

    print(f"art centred on a {SQUARE} square, scaled to {CANVAS}")
    return Image.fromarray(master, "RGBA").resize((CANVAS, CANVAS), Image.LANCZOS)


def main() -> None:
    if not SOURCE.exists():
        raise SystemExit(f"missing {SOURCE}")

    master = build_master(Image.open(SOURCE).convert("RGBA"))

    iconset = ROOT / "build" / "AppIcon.iconset"
    if iconset.exists():
        for stale in iconset.iterdir():
            stale.unlink()
    iconset.mkdir(parents=True, exist_ok=True)

    for size in SIZES:
        scaled = master.resize((size, size), Image.LANCZOS)
        if size in (16, 32, 128, 256, 512):
            scaled.save(iconset / f"icon_{size}x{size}.png")
        if size in (32, 64, 256, 512, 1024):
            scaled.save(iconset / f"icon_{size // 2}x{size // 2}@2x.png")

    ICNS.parent.mkdir(exist_ok=True)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(ICNS)], check=True)
    print(f"wrote {ICNS.relative_to(ROOT)} ({ICNS.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    sys.exit(main())

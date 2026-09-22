"""Inset square artwork into Apple's rounded-rect icon grid.

macOS app icons are not full-bleed: the shape occupies 824 of 1024 px with a
~185 px corner radius (a superellipse, approximated here with a high-order
squircle), on a transparent canvas.

usage: python3 mask.py in.png out.png
"""
import sys

import numpy as np
from PIL import Image

CANVAS, BOX, N = 1024, 824, 5.0   # N: squircle exponent; 2 = circle, ∞ = square
SS = 4                            # supersample the mask for a clean edge


def squircle(size, n=N, ss=SS):
    g = (np.arange(size * ss) + 0.5) / (size * ss) * 2.0 - 1.0
    d = np.abs(g[None, :]) ** n + np.abs(g[:, None]) ** n
    m = np.clip((1.0 - d) * (size * ss) * 0.25, 0.0, 1.0).astype(np.float32)
    return Image.fromarray((m * 255).astype(np.uint8)).resize((size, size), Image.LANCZOS)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    art = Image.open(src).convert("RGB").resize((BOX, BOX), Image.LANCZOS)
    art.putalpha(squircle(BOX))
    out = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    off = (CANVAS - BOX) // 2
    out.paste(art, (off, off), art)
    out.save(dst)
    print(dst)


if __name__ == "__main__":
    main()

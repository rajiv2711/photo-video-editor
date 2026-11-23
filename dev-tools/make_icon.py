"""Makes the app icon from the test photo (test-data/photos/test.jpg).

The lens is cut out of its plain grey background (a brightness threshold, holes filled, the largest
shape kept, edges smoothed: no AI), the brand and scale lettering on the barrel is painted out with
the dark barrel around it (the icon must not carry the maker's logo), and the lens is placed on a dark
gradient with a soft shadow. Output: a 1024 × 1024 PNG without transparency; iPadOS makes the smaller
sizes and rounds the corners.

    python3 dev-tools/make_icon.py [--preview out.png]
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage

ROOT = Path(__file__).resolve().parent.parent
PHOTO = ROOT / "test-data/photos/test.jpg"
ICON = ROOT / "ipad-app/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
SIZE = 1024

# Lettering on the lens, in test.jpg pixels (x0, y0, x1, y1): it is painted out.
# Lettering on the lens, in test.jpg pixels (x0, y0, x1, y1, brightness above which a pixel is
# lettering): it is painted out. White lettering is far brighter than the black barrel; the
# distance window's grey marks need the lower threshold.
LETTERING = [
    (820, 2440, 1340, 2800, 45),    # maker's logo and the distance window
    (1340, 2500, 1820, 2750, 100),  # focal length and "image stabilizer"
    (1960, 2520, 2100, 2640, 120),  # "LOCK" under the switch (the switch itself stays)
    (960, 3070, 1920, 3250, 100),   # zoom scale numbers
    (1570, 950, 1810, 1075, 100),   # filter size on the front rim
    (600, 1100, 1050, 1650, 100),   # lens name on the front rim (the glass itself is never touched)
]


def largest(m: np.ndarray) -> np.ndarray:
    labels, n = ndimage.label(m)
    if n <= 1:
        return m
    sizes = ndimage.sum(m, labels, range(1, n + 1))
    return labels == (int(np.argmax(sizes)) + 1)


def lens_mask(lum: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """The lens and its glass.

    1. Rough shape: the dark pixels, closed and filled, so the bright rim highlights and the red
       ring stay part of the lens.
    2. The closing also pulls in some background where the outline has notches (by the switch,
       under the mount, the soft shadow): smooth, light patches touching the outline are removed.
       Smooth light areas inside the lens (the glass, the distance window) don't touch the outline,
       so they stay.
    3. The glass is the biggest bright area inside the lens (never painted over)."""
    dark = lum < 95
    rough = ndimage.binary_closing(dark, structure=disk(9), iterations=2)
    lens = largest(ndimage.binary_fill_holes(rough))
    mean = ndimage.uniform_filter(lum, 9)
    std = np.sqrt(np.maximum(ndimage.uniform_filter(lum * lum, 9) - mean * mean, 0))
    smooth_light = (lum > 88) & (std < 9)
    for _ in range(4):  # peel: each pass removes what the last pass uncovered on the outline
        background_like = lens & smooth_light
        labels, _ = ndimage.label(background_like)
        outline = lens & ~ndimage.binary_erosion(lens)
        touching = np.unique(labels[outline & background_like])
        touching = touching[touching > 0]
        if touching.size == 0:
            break
        lens = lens & ~np.isin(labels, touching)
    # Row by row the lens ends a few pixels past its truly black pixels: this cuts off the soft
    # shadow that clings to the mount (lighter than the lens, but too dark to peel).
    core = lens & (lum < 50)
    cols = np.arange(lum.shape[1])
    for y in np.where(core.any(1))[0]:
        xs = cols[core[y]]
        lens[y, : max(xs.min() - 15, 0)] = False
        lens[y, xs.max() + 16:] = False
    lens = largest(ndimage.binary_opening(lens, structure=disk(3)))
    lens = ndimage.binary_erosion(ndimage.binary_fill_holes(lens), structure=disk(2))  # no grey fringe
    glass = largest(ndimage.binary_opening(lens & ~dark, structure=disk(6)))
    return lens, ndimage.binary_dilation(glass, structure=disk(8))


def disk(r: int) -> np.ndarray:
    y, x = np.ogrid[-r:r + 1, -r:r + 1]
    return x * x + y * y <= r * r


def paint_out_lettering(rgb: np.ndarray, lum: np.ndarray, mask: np.ndarray, glass: np.ndarray) -> np.ndarray:
    """Light lettering inside the boxes is replaced by the dark barrel around it (normalised blur)."""
    out = rgb.copy()
    for x0, y0, x1, y1, bright in LETTERING:
        pad = 60
        X0, Y0, X1, Y1 = max(x0 - pad, 0), max(y0 - pad, 0), x1 + pad, y1 + pad
        box = np.zeros(lum.shape, bool)
        box[y0:y1, x0:x1] = True
        red = (rgb[..., 0] - rgb[..., 1]) > 28
        text = box & mask & ~glass & ((lum > bright) | red)
        text = ndimage.binary_dilation(text, structure=disk(5))
        keep = (~text & mask).astype(float)[Y0:Y1, X0:X1]  # fill from the lens only, never the background
        patch = out[Y0:Y1, X0:X1]
        for sigma in (8, 20, 45):
            num = np.stack([ndimage.gaussian_filter(patch[..., c] * keep, sigma) for c in range(3)], -1)
            den = ndimage.gaussian_filter(keep, sigma)[..., None]
            fill = num / np.maximum(den, 1e-6)
            hole = (keep < 0.5) & (den[..., 0] > 0.05)
            patch[hole] = fill[hole]
            keep = np.where(hole, 1.0, keep)
        out[Y0:Y1, X0:X1] = patch
    return out


def background() -> np.ndarray:
    """A dark slate radial gradient, lighter behind the lens."""
    y, x = np.mgrid[0:SIZE, 0:SIZE].astype(float)
    d = np.sqrt((x - SIZE * 0.5) ** 2 + (y - SIZE * 0.42) ** 2) / (SIZE * 0.72)
    d = np.clip(d, 0, 1) ** 1.2
    inner = np.array([74, 82, 99], float)
    outer = np.array([14, 16, 21], float)
    return inner * (1 - d[..., None]) + outer * d[..., None]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--preview", type=Path, help="also save a rounded, small-size preview here")
    args = parser.parse_args()

    rgb = np.asarray(Image.open(PHOTO).convert("RGB")).astype(float)
    lum = rgb @ np.array([0.2126, 0.7152, 0.0722])
    mask, glass = lens_mask(lum)
    rgb = paint_out_lettering(rgb, lum, mask, glass)

    ys, xs = np.where(mask)
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    lens = Image.fromarray(np.clip(rgb[y0:y1, x0:x1], 0, 255).astype(np.uint8))
    alpha = Image.fromarray((mask[y0:y1, x0:x1] * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.5))

    # The lens fills 80 % of the icon's height, centred a little high (room for its shadow).
    h = int(SIZE * 0.80)
    w = int(lens.width * h / lens.height)
    lens = lens.resize((w, h), Image.LANCZOS)
    alpha = alpha.resize((w, h), Image.LANCZOS)
    left, top = (SIZE - w) // 2, int(SIZE * 0.085)

    canvas = Image.fromarray(background().astype(np.uint8))
    shadow = Image.new("L", (SIZE, SIZE), 0)
    shadow.paste(alpha, (left, top + 22))
    shadow = shadow.filter(ImageFilter.GaussianBlur(26)).point(lambda v: int(v * 0.6))
    canvas.paste(Image.new("RGB", (SIZE, SIZE), (0, 0, 0)), (0, 0), shadow)
    canvas.paste(lens, (left, top), alpha)

    ICON.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(ICON, optimize=True)
    print(f"Wrote {ICON.relative_to(ROOT)} ({SIZE}×{SIZE}, lens {w}×{h})")

    if args.preview:
        # Rounded like the home screen, at 1024, 167 (iPad Pro) and 76 points.
        radius = int(SIZE * 0.2237)
        round_mask = Image.new("L", (SIZE, SIZE), 0)
        from PIL import ImageDraw
        ImageDraw.Draw(round_mask).rounded_rectangle((0, 0, SIZE - 1, SIZE - 1), radius, fill=255)
        rounded = Image.new("RGB", (SIZE, SIZE), (235, 235, 240))
        rounded.paste(canvas, (0, 0), round_mask)
        sheet = Image.new("RGB", (SIZE + 167 + 76 + 80, SIZE), (235, 235, 240))
        sheet.paste(rounded, (0, 0))
        sheet.paste(rounded.resize((167, 167), Image.LANCZOS), (SIZE + 20, 40))
        sheet.paste(rounded.resize((76, 76), Image.LANCZOS), (SIZE + 207, 40))
        sheet.save(args.preview)


if __name__ == "__main__":
    main()

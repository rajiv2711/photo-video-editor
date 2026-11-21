"""Makes test-data/raw/test.dng: a small synthetic camera raw for the raw support checks (laptop-only).

    uv run --with pidng==4.0.9 --with numpy python dev-tools/make_dng.py

PiDNG (MIT licence) writes the DNG. The scene, in linear light: four upright bands (red, green, blue and
grey), each darkening from top to bottom, seen by a 12-bit sensor with an RGGB Bayer filter whose colours
are sRGB's (ColorMatrix1 = XYZ -> linear sRGB, D65), white balanced for daylight D65 (AsShotNeutral 1, 1, 1),
so a raw decoder reads its As Shot white balance as about 6500 K. 320 x 240 pixels, uncompressed (~150 KB).
"""
from pathlib import Path

import numpy as np
from pidng.core import RAW2DNG, DNGTags, Tag
from pidng.defs import CFAPattern, CalibrationIlluminant, DNGVersion, Orientation, PhotometricInterpretation, PreviewColorSpace

W, H, BITS = 320, 240, 12
OUT = Path(__file__).resolve().parent.parent / "test-data" / "raw" / "test.dng"

# The scene in linear sRGB, 0..1.
bands = np.array([[0.70, 0.08, 0.06], [0.10, 0.55, 0.12], [0.07, 0.10, 0.65], [0.45, 0.45, 0.45]])
scene = np.zeros((H, W, 3))
for i, colour in enumerate(bands):
    scene[:, i * W // 4:(i + 1) * W // 4] = colour
scene *= np.linspace(1.0, 0.25, H)[:, None, None]

# RGGB mosaic: red at even rows / even columns, blue at odd / odd, green elsewhere.
raw = np.zeros((H, W))
raw[0::2, 0::2] = scene[0::2, 0::2, 0]
raw[0::2, 1::2] = scene[0::2, 1::2, 1]
raw[1::2, 0::2] = scene[1::2, 0::2, 1]
raw[1::2, 1::2] = scene[1::2, 1::2, 2]
white = (1 << BITS) - 1
raw = np.clip(np.round(raw * white), 0, white).astype(np.uint16)


def rational(m):
    return [[int(round(v * 10000)), 10000] for v in np.ravel(m)]


xyz_to_srgb = [[3.2406, -1.5372, -0.4986], [-0.9689, 1.8758, 0.0415], [0.0557, -0.2040, 1.0570]]
t = DNGTags()
t.set(Tag.ImageWidth, W)
t.set(Tag.ImageLength, H)
t.set(Tag.TileWidth, W)
t.set(Tag.TileLength, H)
t.set(Tag.Orientation, Orientation.Horizontal)
t.set(Tag.PhotometricInterpretation, PhotometricInterpretation.Color_Filter_Array)
t.set(Tag.SamplesPerPixel, 1)
t.set(Tag.BitsPerSample, BITS)
t.set(Tag.CFARepeatPatternDim, [2, 2])
t.set(Tag.CFAPattern, CFAPattern.RGGB)
t.set(Tag.BlackLevel, 0)
t.set(Tag.WhiteLevel, white)
t.set(Tag.ColorMatrix1, rational(xyz_to_srgb))
t.set(Tag.CalibrationIlluminant1, CalibrationIlluminant.D65)
t.set(Tag.AsShotNeutral, [[1, 1], [1, 1], [1, 1]])
t.set(Tag.BaselineExposure, [[0, 100]])
t.set(Tag.Make, "Synthetic")
t.set(Tag.Model, "Test DNG")
t.set(Tag.DNGVersion, DNGVersion.V1_4)
t.set(Tag.DNGBackwardVersion, DNGVersion.V1_2)
t.set(Tag.PreviewColorSpace, PreviewColorSpace.sRGB)

OUT.parent.mkdir(parents=True, exist_ok=True)
converter = RAW2DNG()
converter.options(t, path=str(OUT.parent), compress=False)
converter.convert(raw, filename=OUT.stem)
print(f"Wrote {OUT} ({OUT.stat().st_size} bytes)")

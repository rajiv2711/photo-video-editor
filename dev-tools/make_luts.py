#!/usr/bin/env python3
"""Writes the sample LUTs bundled with the app (17³ .cube files) into CommandEngine's resources.

    python3 dev-tools/make_luts.py

Each look is a small function on sRGB levels (0…1). The files are standard Adobe .cube text, so the
same parser reads them and any LUT a user imports later.
"""
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "command-engine" / "Sources" / "CommandEngine" / "Resources"
SIZE = 17


def clamp(x):
    return min(max(x, 0.0), 1.0)


def luma(r, g, b):
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def s_curve(x, strength):
    """Contrast around mid-grey (black, grey and white stay put); 0 = none."""
    return clamp(x + strength * (x - 0.5) * 4 * x * (1 - x))


def teal_orange(r, g, b):
    y = luma(r, g, b)
    # Shadows towards teal, highlights towards orange, a little more contrast and colour.
    t = 0.5 - y
    r, g, b = r - 0.18 * max(t, 0) + 0.12 * max(-t, 0), g + 0.04 * max(t, 0) + 0.02 * max(-t, 0), b + 0.12 * max(t, 0) - 0.14 * max(-t, 0)
    y2 = luma(r, g, b)
    r, g, b = (y2 + 1.15 * (c - y2) for c in (r, g, b))
    return tuple(s_curve(clamp(c), 0.15) for c in (r, g, b))


def warm_film(r, g, b):
    # Lifted blacks, softer whites, warmer, slightly less saturated.
    y = luma(r, g, b)
    r, g, b = (y + 0.85 * (c - y) for c in (r, g, b))
    r, g, b = r * 1.06, g * 1.0, b * 0.88
    return tuple(clamp(0.05 + 0.9 * clamp(c)) for c in (r, g, b))


def bleach_bypass(r, g, b):
    # Half the colour, strong contrast.
    y = luma(r, g, b)
    r, g, b = (y + 0.45 * (c - y) for c in (r, g, b))
    return tuple(s_curve(clamp(c), 0.35) for c in (r, g, b))


LOOKS = {"TealOrange": ("Teal & Orange", teal_orange), "WarmFilm": ("Warm Film", warm_film),
         "BleachBypass": ("Bleach Bypass", bleach_bypass)}


def main():
    for name, (title, look) in LOOKS.items():
        lines = [f"# Sample LUT for photo-video-editor (dev-tools/make_luts.py)", f'TITLE "{title}"',
                 f"LUT_3D_SIZE {SIZE}", "DOMAIN_MIN 0.0 0.0 0.0", "DOMAIN_MAX 1.0 1.0 1.0"]
        n = SIZE - 1
        for bi in range(SIZE):
            for gi in range(SIZE):
                for ri in range(SIZE):  # red varies fastest
                    r, g, b = look(ri / n, gi / n, bi / n)
                    lines.append(f"{r:.4f} {g:.4f} {b:.4f}")
        (OUT / f"{name}.cube").write_text("\n".join(lines) + "\n")
        print(f"wrote {name}.cube")


if __name__ == "__main__":
    main()

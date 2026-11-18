#!/usr/bin/env python3
"""Builds the HTML report for a parser run (laptop-only, output is git-ignored).

    python3 dev-tools/make_report.py reports/parser/results.json

Reads the JSON written by `command-scorer`, renders before/after versions of test-data/photos/test.jpg
for a few commands, and writes "reports/Command parser report.html".

The photo rendering approximates the app's Core Image filters (exposure in linear light,
then contrast and saturation); it is close to, but not pixel-identical with, the iPad.
"""
import html
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
PHOTO = ROOT / "test-data" / "photos" / "test.jpg"
OUT_DIR = ROOT / "reports"
IMG_DIR = OUT_DIR / "parser" / "img"
# Commands shown as before/after pictures (only those present in the results are used).
VISUAL_CASES = [
    "exposure 1",
    "exposure -1.5",
    "contrast max",
    "contrast more more more",
    "saturation max contrast min",
    "saturation less exposure more",
]


def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


def render(base: np.ndarray, values: dict) -> np.ndarray:
    """Mirror of ipad-app/Sources/PhotoRenderer.swift: exposure (EV), then contrast and saturation."""
    lin = srgb_to_linear(base) * (2.0 ** values.get("exposure", 0))
    rgb = linear_to_srgb(lin)
    contrast = 1 + values.get("contrast", 0) / 100 * 0.5   # −100…100 → 0.5…1.5
    saturation = 1 + values.get("saturation", 0) / 100     # −100…100 → 0…2
    luma = (rgb * np.array([0.2126, 0.7152, 0.0722])).sum(axis=2, keepdims=True)
    rgb = luma + (rgb - luma) * saturation
    rgb = (rgb - 0.5) * contrast + 0.5
    return np.clip(rgb, 0, 1)


def save(arr: np.ndarray, name: str) -> str:
    IMG_DIR.mkdir(parents=True, exist_ok=True)
    Image.fromarray((arr * 255 + 0.5).astype(np.uint8)).save(IMG_DIR / name, quality=85)
    return f"parser/img/{name}"


def fmt_cmds(cmds: list) -> str:
    if not cmds:
        return "—"
    return " ".join(json.dumps(c, separators=(",", ":"), sort_keys=True) for c in cmds)


def fmt_value(v: float) -> str:
    return f"{v:g}"


def main() -> None:
    results_path = Path(sys.argv[1] if len(sys.argv) > 1 else OUT_DIR / "parser" / "results.json")
    data = json.loads(results_path.read_text())
    cases = data["cases"]
    pct = round(100 * data["passed"] / data["total"]) if data["total"] else 0

    # 1 · Score bars (single series → one hue, no legend, value at the tip)
    rows = []
    for g in data["groups"]:
        share = g["passed"] / g["total"] if g["total"] else 0
        label = f'{g["name"]}: {g["passed"]} of {g["total"]} passed'
        rows.append(
            f'<div class="bar-row" tabindex="0" aria-label="{html.escape(label)}" data-tip="{html.escape(label)}">'
            f'<span class="bar-name">{html.escape(g["name"])}</span>'
            f'<span class="bar-track"><span class="bar" style="width:{share * 100:.1f}%"></span></span>'
            f'<span class="bar-val">{g["passed"]}/{g["total"]}</span></div>'
        )

    # 2 · Failures
    failures = [c for c in cases if not c["pass"]]
    fail_rows = "".join(
        f'<tr><td><span class="pill">{html.escape(c["group"])}</span></td>'
        f'<td class="mono">“{html.escape(c["text"])}”</td>'
        f'<td class="mono good">{html.escape(fmt_cmds(c["expect"]))}</td>'
        f'<td class="mono bad">{html.escape(fmt_cmds(c["actual"]))}</td></tr>'
        for c in failures
    )

    # 3 · Visual check
    base_img = Image.open(PHOTO).convert("RGB")
    base_img.thumbnail((420, 630))
    base = np.asarray(base_img, dtype=np.float64) / 255
    tiles = [f'<figure><img src="{save(base, "before.jpg")}" alt="Original test photo"><figcaption><b>Before</b></figcaption></figure>']
    by_text = {c["text"]: c for c in cases}
    for i, text in enumerate(t for t in VISUAL_CASES if t in by_text):
        c = by_text[text]
        changed = {k: v for k, v in c["values"].items() if v != 0}
        vals = " · ".join(f"{k} {fmt_value(v)}" for k, v in changed.items()) or "no change"
        mark = '<span class="good">✓</span>' if c["pass"] else '<span class="bad">✗</span>'
        tiles.append(
            f'<figure><img src="{save(render(base, c["values"]), f"after-{i}.jpg")}" alt="{html.escape(text)}">'
            f'<figcaption>{mark} <span class="mono">“{html.escape(text)}”</span><br><span class="muted">{html.escape(vals)}</span></figcaption></figure>'
        )

    page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Command parser report</title>
<link rel="stylesheet" href="style.css">
<style>
  :root {{ --bar: #2a78d6; }}
  @media (prefers-color-scheme: dark) {{ :root:not([data-theme="light"]) {{ --bar: #3987e5; }} }}
  :root[data-theme="dark"] {{ --bar: #3987e5; }}
  .hero {{ display:flex; align-items:baseline; gap:12px; margin-bottom:14px; }}
  .hero .num {{ font-size:52px; font-weight:700; letter-spacing:-0.02em; }}
  .bar-row {{ position:relative; display:grid; grid-template-columns:110px 1fr 52px; align-items:center; gap:10px; padding:4px 0; outline:none; }}
  .bar-name {{ font-size:13px; color:var(--muted); }}
  .bar-track {{ height:14px; border-left:1px solid var(--line); }}
  .bar {{ display:block; height:14px; background:var(--bar); border-radius:0 4px 4px 0; }}
  .bar-val {{ font-size:13px; font-variant-numeric:tabular-nums; }}
  .bar-row:hover .bar, .bar-row:focus .bar {{ filter:brightness(1.12); }}
  .bar-row:hover::after, .bar-row:focus::after {{ content:attr(data-tip); position:absolute; left:120px; top:-26px; background:var(--ink); color:var(--card);
     font-size:12px; padding:3px 8px; border-radius:6px; white-space:nowrap; pointer-events:none; z-index:2; }}
  .tiles {{ display:grid; grid-template-columns:repeat(auto-fill, minmax(150px, 1fr)); gap:12px; }}
  .tiles figcaption {{ font-size:12px; }}
  td.mono {{ font-size:12px; word-break:break-word; }}
</style>
</head>
<body>
<main>
<header>
  <h1>Command parser: rules baseline</h1>
  <p>{data["total"]} test phrases · parser: {html.escape(data["parser"])} · photo: test-data/photos/test.jpg</p>
</header>

<section>
  <h2><span class="n">1</span>Score</h2>
  <div class="hero"><span class="num">{pct}%</span><span class="muted">{data["passed"]} of {data["total"]} phrases parsed exactly right</span></div>
  {"".join(rows)}
</section>

<section>
  <h2><span class="n">2</span>Failures ({len(failures)})</h2>
  <div class="scroll"><table>
    <tr><th>Group</th><th>Said</th><th>Expected</th><th>Got</th></tr>
    {fail_rows}
  </table></div>
</section>

<section>
  <h2><span class="n">3</span>Visual check</h2>
  <div class="tiles">{"".join(tiles)}</div>
  <p class="muted" style="font-size:12px;margin-top:10px">Rendered on the laptop with the same formulas as the app; close to the iPad, not pixel-identical.</p>
</section>
</main>
</body>
</html>
"""
    out = OUT_DIR / "Command parser report.html"
    out.write_text(page)
    print(f"Wrote {out}")


if __name__ == "__main__":
    main()

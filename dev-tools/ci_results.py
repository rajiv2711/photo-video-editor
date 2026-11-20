#!/usr/bin/env python3
"""Checks the cloud build's test renders, one row per operation (laptop-only, output is git-ignored).

    python3 dev-tools/ci_results.py            # results for HEAD
    python3 dev-tools/ci_results.py <sha>      # results for another commit
    python3 dev-tools/ci_results.py --wait     # first wait (up to 45 min) until that build has published

The cloud build (.github/workflows/build.yml) renders every case in test-data/gallery/gallery.json on an
iPad simulator and force-pushes the pictures to the `ci-renders` branch with sha.txt, status.json and
build-errors.txt. This script fetches that branch into reports/ci/, measures each picture against its
reference (the "base" case, or the case named in "vs"), checks the expectation (e.g. Highlights -100 ->
p95 luma down) and writes "reports/Operation test report.html".

Exit code: 0 all passed · 1 a build step or a case failed · 3 no results for this commit yet.
"""
import argparse
import html
import json
import shutil
import subprocess
import sys
import tarfile
import io
import time
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
REPORTS = ROOT / "reports"
OUT = REPORTS / "ci"
CONTROLS = ROOT / "command-engine" / "Sources" / "CommandEngine" / "Resources" / "controls.json"
BRANCH = "origin/ci-renders"

# Smallest change that counts, per metric (luma and RGB on 0-255, saturation on 0-100, peak in linear light).
THRESHOLDS = {"mean_sat": 0.5, "peak": 0.02}
DEFAULT_THRESHOLD = 1.0
METRIC_NAMES = {
    "mean_luma": "mean luma", "p5_luma": "p5 luma", "p25_luma": "p25 luma", "p50_luma": "median luma",
    "p75_luma": "p75 luma", "p95_luma": "p95 luma", "mean_sat": "saturation", "mean_r": "mean red",
    "mean_g": "mean green", "mean_b": "mean blue", "diff": "pixel change", "peak": "peak (linear)",
}
STEPS = [("linux_tests", "Linux tests"), ("generate", "Xcode project"), ("build", "Build"),
         ("install", "Install"), ("gallery", "Gallery"), ("screenshots", "Screenshots")]


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True).stdout


def fetch() -> str | None:
    """Fetches ci-renders and returns the commit it tested, or None if the branch doesn't exist yet."""
    try:
        git("fetch", "-q", "origin", "+refs/heads/ci-renders:refs/remotes/origin/ci-renders")
        return git("show", f"{BRANCH}:sha.txt").strip()
    except subprocess.CalledProcessError:
        return None


def extract() -> None:
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True)
    data = subprocess.run(["git", "archive", "--format=tar", BRANCH], cwd=ROOT, check=True, capture_output=True).stdout
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        tar.extractall(OUT, filter="data")


def measure(path: Path) -> tuple[dict, np.ndarray]:
    a = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64)
    luma = a @ np.array([0.2126, 0.7152, 0.0722])
    hi, lo = a.max(axis=2), a.min(axis=2)
    sat = np.where(hi > 0, (hi - lo) / np.maximum(hi, 1e-6), 0) * 100
    p5, p25, p50, p75, p95 = np.percentile(luma, [5, 25, 50, 75, 95])
    stats = {
        "mean_luma": luma.mean(), "p5_luma": p5, "p25_luma": p25, "p50_luma": p50, "p75_luma": p75,
        "p95_luma": p95, "mean_sat": sat.mean(),
        "mean_r": a[..., 0].mean(), "mean_g": a[..., 1].mean(), "mean_b": a[..., 2].mean(),
    }
    return stats, a


def check(expect: dict, value: float, ref: float) -> tuple[bool, float]:
    delta = value - ref
    need = expect.get("min") or THRESHOLDS.get(expect["metric"], DEFAULT_THRESHOLD)
    ok = {
        "up": delta > need,
        "down": delta < -need,
        "changed": abs(delta) > need,
        "same": abs(delta) <= need,
    }.get(expect["dir"], False)
    return ok, delta


def thumb(src: Path, name: str) -> str:
    (OUT / "thumbs").mkdir(exist_ok=True)
    im = Image.open(src).convert("RGB")
    im.thumbnail((200, 200))
    im.save(OUT / "thumbs" / name, quality=85)
    return f"ci/thumbs/{name}"


def labels() -> dict:
    try:
        return {c["id"]: c["label"] for c in json.loads(CONTROLS.read_text())["controls"]}
    except (OSError, ValueError, KeyError):
        return {}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("commit", nargs="?", default="HEAD")
    ap.add_argument("--wait", action="store_true", help="poll every minute until the results for the commit arrive")
    ap.add_argument("--timeout", type=int, default=45, help="minutes to wait (with --wait)")
    args = ap.parse_args()

    expected = git("rev-parse", args.commit).strip()
    tested = fetch()
    deadline = time.time() + args.timeout * 60
    while args.wait and tested != expected and time.time() < deadline:
        time.sleep(60)
        tested = fetch()
    if tested != expected:
        print(f"No CI results for {expected[:7]} yet (ci-renders has {tested[:7] if tested else 'nothing'}). "
              "The cloud build takes about 10 minutes; try again or use --wait.")
        return 3

    extract()
    status = json.loads((OUT / "status.json").read_text())
    errors = (OUT / "build-errors.txt").read_text().strip() if (OUT / "build-errors.txt").exists() else ""
    print(f"CI results for {expected[:7]} ({status.get('ref', '?')})  {status.get('run', '')}")
    for key, name in STEPS:
        print(f"  {name:<13} {status.get(key, '?')}")
    if errors:
        print("\nBuild errors:\n" + errors)
    steps_ok = all(status.get(k) == "success" for k, _ in STEPS)

    # Measure every case against its reference.
    rows, failed = [], 0
    manifest_path = OUT / "gallery" / "manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {"cases": []}
    if manifest.get("error"):
        print(f"\nGallery error: {manifest['error']}")
    cases = {c["id"]: c for c in manifest["cases"]}
    measured = {}
    for c in manifest["cases"]:
        path = OUT / "gallery" / c["file"]
        if path.exists():
            stats, pixels = measure(path)
            stats["peak"] = c.get("peak", 0.0)
            measured[c["id"]] = (stats, pixels)
    names = labels()
    if manifest["cases"]:
        print(f"\n{'case':<26}{'command':<34}result")
    for c in manifest["cases"]:
        if c["id"] == "base":
            continue
        checks, ok_all = [], True
        if c["id"] not in measured:
            ok_all, checks = False, [("no picture", False)]
        for e in c["expect"]:
            ref_id = e.get("vs") or "base"
            if c["id"] not in measured or ref_id not in measured:
                ok_all = False
                checks.append((f"{METRIC_NAMES.get(e['metric'], e['metric'])}: missing {ref_id}", False))
                continue
            (stats, pixels), (ref_stats, ref_pixels) = measured[c["id"]], measured[ref_id]
            if e["metric"] == "diff":
                value = float(np.abs(pixels - ref_pixels).mean()) if pixels.shape == ref_pixels.shape else 255.0
                ref = 0.0
            else:
                value, ref = stats[e["metric"]], ref_stats[e["metric"]]
            ok, delta = check(e, value, ref)
            ok_all &= ok
            vs = "" if ref_id == "base" else f" vs {ref_id}"
            digits = 3 if e["metric"] == "peak" else 1
            checks.append((f"{METRIC_NAMES.get(e['metric'], e['metric'])} {e['dir']}{vs}: "
                           f"{ref:.{digits}f} → {value:.{digits}f} ({delta:+.{digits}f})", ok))
        failed += 0 if ok_all else 1
        print(f"{c['id']:<26}{c['command'][:33]:<34}{'PASS' if ok_all else 'FAIL'}")
        if not ok_all:
            for text, ok in checks:
                print(f"{'':<28}{'ok  ' if ok else 'FAIL'} {text}")
            print(f"{'':<28}app said: {c.get('feedback', '')}")
        rows.append((c, checks, ok_all))

    gallery_ok = bool(manifest["cases"]) and not manifest.get("error")
    all_ok = steps_ok and gallery_ok and failed == 0
    total = len(rows)
    print(f"\n{total - failed}/{total} cases pass · build {'ok' if steps_ok else 'FAILED'}")

    write_report(expected, status, errors, rows, cases, measured, names, all_ok, failed)
    return 0 if all_ok else 1


def write_report(sha, status, errors, rows, cases, measured, names, all_ok, failed) -> None:
    def chip(value: str) -> str:
        cls = "good" if value == "success" else "muted" if value == "skipped" else "bad"
        return f'<span class="{cls}">{html.escape(value)}</span>'

    steps = " · ".join(f"{name} {chip(status.get(key, '?'))}" for key, name in STEPS)
    error_block = f'<pre class="err">{html.escape(errors)}</pre>' if errors else ""

    base_thumb = thumb(OUT / "gallery" / cases["base"]["file"], "base.jpg") if "base" in measured else ""
    trs = []
    for c, checks, ok in rows:
        ref_id = next((e.get("vs") for e in c["expect"] if e.get("vs")), None)
        before = base_thumb
        if ref_id and ref_id in measured:
            before = thumb(OUT / "gallery" / cases[ref_id]["file"], f"{ref_id}.jpg")
        after = thumb(OUT / "gallery" / c["file"], f"{c['id']}.jpg") if c["id"] in measured else ""
        name = names.get(c.get("control") or "", c["id"])
        img = lambda src, alt: f'<img src="{src}" alt="{html.escape(alt)}">' if src else "—"
        lines = "<br>".join(f'<span class="{"good" if k else "bad"}">{"✓" if k else "✗"}</span> {html.escape(t)}'
                            for t, k in checks)
        trs.append(
            f'<tr><td><b>{html.escape(name)}</b><br><span class="muted">{html.escape(c["id"])}</span></td>'
            f'<td class="mono">{html.escape(c["command"])}</td>'
            f'<td class="pic">{img(before, "before")}</td><td class="pic">{img(after, "after")}</td>'
            f'<td class="small">{lines}<br><span class="muted">{html.escape(c.get("feedback", ""))}</span></td>'
            f'<td class="{"good" if ok else "bad"}">{"PASS" if ok else "FAIL"}</td></tr>')

    shots = sorted((OUT / "screenshots").glob("*.png")) if (OUT / "screenshots").exists() else []
    shot_tiles = "".join(
        f'<figure><img src="ci/screenshots/{p.name}" alt="{html.escape(p.stem)}"><figcaption>{html.escape(p.stem)}</figcaption></figure>'
        for p in shots) or '<p class="muted">No screenshots.</p>'

    verdict = ("All operations pass." if all_ok
               else f"{failed} case(s) failed." if failed else "Build or gallery step failed.")
    page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Operation test report</title>
<link rel="stylesheet" href="style.css">
<style>
  td.pic img {{ width: 110px; border-radius: 6px; border: 1px solid var(--line); display: block; }}
  td.small {{ font-size: 12px; }}
  pre.err {{ white-space: pre-wrap; font-size: 12px; background: var(--bg); border: 1px solid var(--line);
     border-radius: 8px; padding: 10px; color: var(--bad); }}
  .shots {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 12px; }}
</style>
</head>
<body>
<main>
<header>
  <h1>Operation test report</h1>
  <p>Commit <span class="mono">{sha[:7]}</span> · {html.escape(status.get("ref", ""))} ·
     <a href="{html.escape(status.get("run", "#"))}">cloud build run</a> · iPad simulator renders of test.jpg</p>
</header>
<div class="verdict {'' if all_ok else 'bad'}">{verdict} {len(rows) - failed}/{len(rows)} cases pass.</div>

<section>
  <h2><span class="n">1</span>Build</h2>
  <p>{steps}</p>
  {error_block}
</section>

<section>
  <h2><span class="n">2</span>Operations</h2>
  <div class="scroll"><table>
    <tr><th>Operation</th><th>Command</th><th>Before</th><th>After</th><th>Change</th><th></th></tr>
    {"".join(trs)}
  </table></div>
  <p class="muted" style="font-size:12px">Luma 0–255 (Rec. 709), saturation 0–100. Before = the unedited photo unless the case compares with another case.</p>
</section>

<section>
  <h2><span class="n">3</span>Screenshots</h2>
  <div class="shots">{shot_tiles}</div>
</section>
</main>
</body>
</html>
"""
    out = REPORTS / "Operation test report.html"
    out.write_text(page)
    print(f"Wrote {out}")


if __name__ == "__main__":
    sys.exit(main())

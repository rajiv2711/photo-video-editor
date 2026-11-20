#!/usr/bin/env python3
"""End-to-end voice test on the laptop: speech → voice server (Whisper) → CommandEngine parser.

    # synthetic voices (Piper), no microphone needed
    uv run --project voice-server dev-tools/voice_test.py
    # read the phrases yourself into a microphone (arecord), e.g. the Jabra headset
    uv run --project voice-server dev-tools/voice_test.py --record --mic plughw:2,0

Needs the voice server running (uv run --project voice-server voice-server/server.py).
Writes "reports/Voice test report.html" (git-ignored), with an audio player for every clip.
"""
from __future__ import annotations

import argparse
import html
import json
import os
import re
import statistics
import subprocess
import sys
import urllib.request
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PHRASES = ROOT / "test-data" / "phrases" / "commands.jsonl"
ENV_FILE = ROOT / "voice-server" / ".env"
VOICES_DIR = ROOT / "voice-server" / "voices"
OUT = ROOT / "reports" / "voice"
TEXT_RESULTS = ROOT / "reports" / "parser" / "results.json"
DEFAULT_VOICES = ["en_US-lessac-medium", "en_US-amy-medium", "en_US-ryan-medium", "en_GB-alan-medium"]
# Typos and mishears are written-text errors; they are not meaningful to speak.
SPOKEN_GROUPS_EXCLUDED = {"typos", "mishears"}


def load_phrases(limit: int | None) -> list[dict]:
    rows = [json.loads(l) for l in PHRASES.read_text().splitlines() if l.strip() and not l.startswith("//")]
    rows = [r for r in rows if r["group"] not in SPOKEN_GROUPS_EXCLUDED]
    return rows[:limit] if limit else rows


def token() -> str:
    for line in ENV_FILE.read_text().splitlines():
        if line.startswith("VOICE_SERVER_TOKEN="):
            return line.split("=", 1)[1].strip()
    sys.exit(f"No token in {ENV_FILE}; start the voice server once first.")


def synthesize(voice_name: str, phrases: list[dict]) -> list[Path]:
    from piper import PiperVoice

    voice = PiperVoice.load(str(VOICES_DIR / f"{voice_name}.onnx"))
    folder = OUT / "audio" / voice_name
    folder.mkdir(parents=True, exist_ok=True)
    paths = []
    for i, p in enumerate(phrases):
        path = folder / f"{i:03d}.wav"
        with wave.open(str(path), "wb") as wf:
            voice.synthesize_wav(p["text"], wf)
        paths.append(path)
    return paths


def record(phrases: list[dict], mic: str, seconds: float) -> list[Path]:
    folder = OUT / "audio" / "you"
    folder.mkdir(parents=True, exist_ok=True)
    paths = []
    print(f"\nRead each phrase after pressing Enter; recording lasts {seconds:g} s.\n")
    for i, p in enumerate(phrases):
        input(f"[{i + 1}/{len(phrases)}]  “{p['text']}”  (Enter to record) ")
        path = folder / f"{i:03d}.wav"
        subprocess.run(["arecord", "-q", "-D", mic, "-f", "S16_LE", "-r", "16000", "-c", "1",
                        "-d", str(int(seconds)), str(path)], check=True)
        paths.append(path)
    return paths


def transcribe(server: str, tok: str, path: Path) -> dict:
    req = urllib.request.Request(
        f"{server}/transcribe", data=path.read_bytes(), method="POST",
        headers={"Authorization": f"Bearer {tok}", "Content-Type": "audio/wav"},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read())


def score_with_command_engine(heard_rows: list[dict]) -> list[dict]:
    """Runs the Swift command-scorer (in Docker) on the transcripts."""
    jsonl = OUT / "heard.jsonl"
    jsonl.write_text("".join(json.dumps(r) + "\n" for r in heard_rows))
    rel = lambda p: str(p.relative_to(ROOT))
    cmd = ["docker", "run", "--rm", "-v", f"{ROOT}:/src", "-w", "/src", "--user", f"{os.getuid()}:{os.getgid()}",
           "-e", "HOME=/tmp", "swift:6.2", "swift", "run", "--package-path", "command-engine",
           "--scratch-path", "command-engine/.build", "command-scorer", rel(jsonl), "--out", rel(OUT / "results.json")]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return json.loads((OUT / "results.json").read_text())["cases"]


def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s.%-]", " ", text.lower())).strip(" .")


def bar_rows(items: list[tuple[str, int, int]]) -> str:
    out = []
    for name, ok, total in items:
        share = ok / total if total else 0
        tip = f"{name}: {ok} of {total} correct"
        out.append(
            f'<div class="bar-row" tabindex="0" aria-label="{html.escape(tip)}" data-tip="{html.escape(tip)}">'
            f'<span class="bar-name">{html.escape(name)}</span><span class="bar-track"><span class="bar" style="width:{share * 100:.1f}%"></span></span>'
            f'<span class="bar-val">{ok}/{total}</span></div>'
        )
    return "".join(out)


def write_report(rows: list[dict], text_pass: dict, meta: dict) -> Path:
    n = len(rows)
    ok_cmd = sum(r["pass"] for r in rows)
    exact = sum(normalize(r["heard"]) == normalize(r["said"]) for r in rows)
    lat = statistics.median(r["elapsed_ms"] for r in rows) if rows else 0
    base = [text_pass.get(r["said"]) for r in rows if r["said"] in text_pass]
    base_pct = round(100 * sum(base) / len(base)) if base else None

    voices = list(dict.fromkeys(r["voice"] for r in rows))
    by_voice = [(v, sum(r["pass"] for r in rows if r["voice"] == v), sum(r["voice"] == v for r in rows)) for v in voices]
    groups = list(dict.fromkeys(r["group"] for r in rows))
    by_group = [(g, sum(r["pass"] for r in rows if r["group"] == g), sum(r["group"] == g for r in rows)) for g in groups]

    problems = [r for r in rows if not r["pass"]]
    prob_rows = "".join(
        f'<tr><td><span class="pill">{html.escape(r["voice"])}</span></td>'
        f'<td class="mono">“{html.escape(r["said"])}”</td>'
        f'<td class="mono">“{html.escape(r["heard"])}”</td>'
        f'<td class="mono bad">{html.escape(" ".join(json.dumps(c, separators=(",", ":"), sort_keys=True) for c in r["actual"]) or "—")}</td>'
        f'<td><audio controls preload="none" src="{html.escape(r["audio"])}"></audio></td></tr>'
        for r in problems
    )
    pct = round(100 * ok_cmd / n) if n else 0
    page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Voice test report</title><link rel="stylesheet" href="style.css">
<style>
  :root {{ --bar:#2a78d6; }}
  @media (prefers-color-scheme: dark) {{ :root:not([data-theme="light"]) {{ --bar:#3987e5; }} }}
  :root[data-theme="dark"] {{ --bar:#3987e5; }}
  .tiles4 {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:12px; margin-bottom:16px; }}
  .tile {{ border:1px solid var(--line); border-radius:12px; padding:12px; }}
  .tile .v {{ font-size:34px; font-weight:700; letter-spacing:-0.02em; }}
  .tile .l {{ font-size:12px; color:var(--muted); }}
  .bar-row {{ position:relative; display:grid; grid-template-columns:150px 1fr 60px; align-items:center; gap:10px; padding:4px 0; outline:none; }}
  .bar-name {{ font-size:13px; color:var(--muted); }}
  .bar-track {{ height:14px; border-left:1px solid var(--line); }}
  .bar {{ display:block; height:14px; background:var(--bar); border-radius:0 4px 4px 0; }}
  .bar-val {{ font-size:13px; font-variant-numeric:tabular-nums; }}
  .bar-row:hover::after, .bar-row:focus::after {{ content:attr(data-tip); position:absolute; left:160px; top:-26px; background:var(--ink); color:var(--card);
     font-size:12px; padding:3px 8px; border-radius:6px; white-space:nowrap; pointer-events:none; z-index:2; }}
  audio {{ height:28px; max-width:180px; }}
  td.mono {{ font-size:12px; word-break:break-word; }}
</style></head><body><main>
<header><h1>Voice test: speech → Whisper → parser</h1>
<p>{n} clips · {len(voices)} voice(s) · Whisper {html.escape(meta.get("model", "?"))} on {html.escape(meta.get("device", "?"))}</p></header>

<section><h2><span class="n">1</span>Score</h2>
<div class="tiles4">
  <div class="tile"><div class="v">{pct}%</div><div class="l">commands correct from voice ({ok_cmd}/{n})</div></div>
  <div class="tile"><div class="v">{base_pct if base_pct is not None else "–"}%</div><div class="l">same phrases typed (text baseline)</div></div>
  <div class="tile"><div class="v">{round(100 * exact / n) if n else 0}%</div><div class="l">heard word-for-word</div></div>
  <div class="tile"><div class="v">{lat:.0f} ms</div><div class="l">median transcription time</div></div>
</div>
{bar_rows(by_voice)}
</section>

<section><h2><span class="n">2</span>By phrase group</h2>{bar_rows(by_group)}</section>

<section><h2><span class="n">3</span>Wrong commands ({len(problems)})</h2>
<div class="scroll"><table><tr><th>Voice</th><th>Said</th><th>Heard</th><th>Parsed as</th><th>Listen</th></tr>{prob_rows}</table></div>
</section>
</main></body></html>"""
    path = ROOT / "reports" / "Voice test report.html"
    path.write_text(page)
    return path


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--server", default="http://127.0.0.1:8765")
    ap.add_argument("--voices", default=",".join(DEFAULT_VOICES), help="Piper voices, comma-separated")
    ap.add_argument("--limit", type=int, help="only the first N phrases")
    ap.add_argument("--record", action="store_true", help="record your own voice instead of Piper")
    ap.add_argument("--mic", default="default", help="arecord device, e.g. plughw:2,0 for the Jabra")
    ap.add_argument("--seconds", type=float, default=3)
    args = ap.parse_args()

    phrases = load_phrases(args.limit)
    tok = token()
    sources = {"you": record(phrases, args.mic, args.seconds)} if args.record else {
        v: synthesize(v, phrases) for v in args.voices.split(",") if v
    }

    rows, heard_rows, meta = [], [], {}
    for voice, paths in sources.items():
        print(f"Transcribing {len(paths)} clips ({voice}) …")
        for p, path in zip(phrases, paths):
            res = transcribe(args.server, tok, path)
            meta = {"model": res.get("model"), "device": res.get("device")}
            rows.append({"voice": voice, "group": p["group"], "said": p["text"], "heard": res["text"],
                         "elapsed_ms": res["elapsed_ms"], "audio": str(path.relative_to(ROOT / "reports"))})
            heard_rows.append({"group": p["group"], "text": res["text"], "expect": p["expect"], **({"focus": p["focus"]} if p.get("focus") else {})})

    print("Parsing transcripts with CommandEngine …")
    for row, case in zip(rows, score_with_command_engine(heard_rows)):
        row["pass"], row["actual"] = case["pass"], case["actual"]

    text_pass = {}
    if TEXT_RESULTS.exists():
        text_pass = {c["text"]: c["pass"] for c in json.loads(TEXT_RESULTS.read_text())["cases"]}
    out = write_report(rows, text_pass, meta)
    ok = sum(r["pass"] for r in rows)
    print(f"Commands correct from voice: {ok}/{len(rows)}  ·  report: {out}")


if __name__ == "__main__":
    main()

"""Laptop speech-to-text server for the iPad editor (development phase).

The iPad records a short clip and POSTs it here (through an ngrok tunnel); Whisper turns it into
text; the iPad's CommandEngine parses the text. Every request is logged under recordings/ so real
usage becomes test and training data.

Run:   uv run --project voice-server voice-server/server.py
Then:  ngrok http 8765 --url=<your ngrok domain>     (in another terminal)

Endpoints
  GET  /health      no auth   {"ok": true}
  GET  /info        token     model, device, hint words
  POST /transcribe  token     body = 16-bit PCM WAV bytes  →  {"text": "...", ...}

Auth: header "Authorization: Bearer <token>". The token lives in voice-server/.env (git-ignored)
and is created on first start; paste it into the iPad app's Settings once.
"""
from __future__ import annotations

import glob
import io
import json
import os
import secrets
import subprocess
import sys
import threading
import time
import uuid
import wave
from datetime import datetime
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
CONTROLS_JSON = REPO / "command-engine" / "Sources" / "CommandEngine" / "Resources" / "controls.json"
ENV_FILE = HERE / ".env"
RECORDINGS = HERE / "recordings"
MAX_AUDIO_BYTES = 5 * 1024 * 1024  # ~2.5 min of 16 kHz WAV; commands are a few seconds


def _ensure_cuda_libs_on_path() -> None:
    """faster-whisper's GPU path loads CUDA 12 libraries by name at runtime; they are installed
    inside .venv (nvidia-* packages). Put them on LD_LIBRARY_PATH and restart once."""
    site = next((p for p in sys.path if p.endswith("site-packages")), None)
    if not site:
        return
    libs = sorted(glob.glob(os.path.join(site, "nvidia", "*", "lib")))
    current = os.environ.get("LD_LIBRARY_PATH", "")
    if libs and not all(d in current.split(":") for d in libs):
        os.environ["LD_LIBRARY_PATH"] = ":".join(libs + ([current] if current else []))
        os.execv(sys.executable, [sys.executable, *sys.argv])


def load_env() -> dict:
    """Reads voice-server/.env; creates it with a fresh token on first run."""
    values = {}
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.split("=", 1)
                values[k.strip()] = v.strip()
    if not values.get("VOICE_SERVER_TOKEN"):
        values["VOICE_SERVER_TOKEN"] = secrets.token_urlsafe(32)
        ENV_FILE.write_text(
            "# Voice server settings (git-ignored). Paste the token into the iPad app's Settings.\n"
            + "".join(f"{k}={v}\n" for k, v in values.items())
        )
        ENV_FILE.chmod(0o600)
        print(f"Created a new token in {ENV_FILE}")
    return values


def hint_words() -> str:
    """Control names, synonyms and action words, used to bias Whisper toward our vocabulary."""
    words = []
    try:
        for c in json.loads(CONTROLS_JSON.read_text())["controls"]:
            words += [c["label"], *c.get("synonyms", [])]
    except (OSError, KeyError, ValueError):
        pass
    words += ["more", "less", "up", "down", "reset", "reset all", "max", "min"]
    return ", ".join(dict.fromkeys(words))


def free_vram_mib() -> int:
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=memory.free", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5,
        )
        return int(out.stdout.strip().splitlines()[0])
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        return 0


def decode_wav(audio: bytes):
    """16-bit PCM WAV (any rate, mono or stereo) → mono float32 at 16 kHz, as Whisper expects.
    Decoding here keeps the server independent of PyAV/FFmpeg versions."""
    import numpy as np

    try:
        with wave.open(io.BytesIO(audio), "rb") as wf:
            channels, width, rate = wf.getnchannels(), wf.getsampwidth(), wf.getframerate()
            frames = wf.readframes(wf.getnframes())
    except (wave.Error, EOFError) as exc:
        raise ValueError("Send 16-bit PCM WAV audio") from exc
    if width != 2:
        raise ValueError("Send 16-bit PCM WAV audio")
    samples = np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0
    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)
    if rate != 16000 and len(samples):
        target = np.arange(0, len(samples) * 16000 // rate) * (rate / 16000)
        samples = np.interp(target, np.arange(len(samples)), samples).astype(np.float32)
    return samples


class WhisperTranscriber:
    """Loads Whisper once. Uses the GPU when ≥ 3 GB is free (the local LLM stack may hold the
    rest), otherwise the CPU."""

    def __init__(self, model: str, device: str = "auto"):
        from faster_whisper import WhisperModel

        if device == "auto":
            device = "cuda" if free_vram_mib() >= 3000 else "cpu"
        compute = "float16" if device == "cuda" else "int8"
        self.model_name, self.device, self.compute_type = model, device, compute
        self.hotwords = hint_words()
        self._model = WhisperModel(model, device=device, compute_type=compute)
        self._lock = threading.Lock()

    def transcribe(self, audio: bytes) -> dict:
        start = time.perf_counter()
        with self._lock:
            segments, info = self._model.transcribe(
                decode_wav(audio),
                language="en",
                beam_size=5,
                temperature=0.0,
                condition_on_previous_text=False,
                without_timestamps=True,
                vad_filter=True,
                hotwords=self.hotwords,
            )
            text = " ".join(s.text.strip() for s in segments).strip()
        return {
            "text": text,
            "audio_seconds": round(info.duration, 2),
            "elapsed_ms": round((time.perf_counter() - start) * 1000),
            "model": self.model_name,
            "device": self.device,
        }


def create_app(transcriber, token: str, log_dir: Path | None = RECORDINGS):
    app = FastAPI(title="Editor voice server", docs_url=None, redoc_url=None)
    bearer = HTTPBearer(auto_error=False)

    def require_token(creds: HTTPAuthorizationCredentials | None = Depends(bearer)):
        if creds is None or not secrets.compare_digest(creds.credentials, token):
            raise HTTPException(status_code=401, detail="Missing or wrong token")

    @app.get("/health")
    def health():
        return {"ok": True}

    @app.get("/info", dependencies=[Depends(require_token)])
    def info():
        return {
            "model": getattr(transcriber, "model_name", "?"),
            "device": getattr(transcriber, "device", "?"),
            "hint_words": getattr(transcriber, "hotwords", ""),
        }

    @app.post("/transcribe", dependencies=[Depends(require_token)])
    async def transcribe(request: Request):
        audio = await request.body()
        if not audio:
            raise HTTPException(status_code=400, detail="Empty audio")
        if len(audio) > MAX_AUDIO_BYTES:
            raise HTTPException(status_code=413, detail="Audio too long")
        try:
            result = transcriber.transcribe(audio)
        except ValueError as exc:
            raise HTTPException(status_code=415, detail=str(exc)) from exc
        except Exception as exc:
            raise HTTPException(status_code=422, detail=f"Could not transcribe: {exc}") from exc
        result["id"] = uuid.uuid4().hex[:12]
        if log_dir is not None:
            _log(log_dir, result, audio, request.headers.get("content-type", ""))
        return result

    return app


def _log(log_dir: Path, result: dict, audio: bytes, content_type: str) -> None:
    now = datetime.now()
    folder = log_dir / now.strftime("%Y-%m-%d")
    folder.mkdir(parents=True, exist_ok=True)
    ext = {"audio/wav": "wav", "audio/x-wav": "wav", "audio/m4a": "m4a", "audio/mp4": "m4a"}.get(content_type, "bin")
    stem = f"{now.strftime('%H%M%S')}-{result['id']}"
    (folder / f"{stem}.{ext}").write_bytes(audio)
    (folder / f"{stem}.json").write_text(json.dumps({**result, "content_type": content_type, "time": now.isoformat()}, indent=2))


def main() -> None:
    _ensure_cuda_libs_on_path()
    import uvicorn

    env = load_env()
    model = env.get("WHISPER_MODEL", "large-v3-turbo")
    device = env.get("WHISPER_DEVICE", "auto")
    port = int(env.get("PORT", "8765"))
    print(f"Loading Whisper {model} (device: {device}) …")
    transcriber = WhisperTranscriber(model, device)
    print(f"Ready on http://127.0.0.1:{port}  ·  device={transcriber.device}  ·  token in {ENV_FILE}")
    print(f"Expose it with:  ngrok http {port} --url=<your ngrok domain>")
    # 127.0.0.1 only: reachable from this laptop and through ngrok, not from the local network.
    uvicorn.run(create_app(transcriber, env["VOICE_SERVER_TOKEN"]), host="127.0.0.1", port=port, log_level="info")


if __name__ == "__main__":
    main()

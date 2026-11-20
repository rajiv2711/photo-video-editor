"""API tests for the voice server with a fake transcriber (no model download, runs in seconds).

    uv run --project voice-server pytest voice-server -q
"""
from fastapi.testclient import TestClient

from server import create_app, hint_words

TOKEN = "test-token"


class FakeTranscriber:
    model_name, device, hotwords = "fake", "cpu", "Contrast"

    def __init__(self):
        self.calls = []

    def transcribe(self, audio: bytes) -> dict:
        self.calls.append(audio)
        return {"text": "contrast more", "audio_seconds": 1.0, "elapsed_ms": 1, "model": "fake", "device": "cpu"}


def client(tmp_path, transcriber=None):
    return TestClient(create_app(transcriber or FakeTranscriber(), TOKEN, log_dir=tmp_path))


def auth():
    return {"Authorization": f"Bearer {TOKEN}"}


def test_health_needs_no_token(tmp_path):
    assert client(tmp_path).get("/health").json() == {"ok": True}


def test_transcribe_rejects_missing_or_wrong_token(tmp_path):
    c = client(tmp_path)
    assert c.post("/transcribe", content=b"x").status_code == 401
    assert c.post("/transcribe", content=b"x", headers={"Authorization": "Bearer nope"}).status_code == 401


def test_transcribe_returns_text_and_logs_the_clip(tmp_path):
    fake = FakeTranscriber()
    r = client(tmp_path, fake).post("/transcribe", content=b"RIFFfake", headers={**auth(), "Content-Type": "audio/wav"})
    assert r.status_code == 200
    assert r.json()["text"] == "contrast more"
    assert fake.calls == [b"RIFFfake"]
    logged = sorted(p.suffix for p in tmp_path.rglob("*.*"))
    assert logged == [".json", ".wav"]


def test_empty_audio_is_rejected(tmp_path):
    assert client(tmp_path).post("/transcribe", content=b"", headers=auth()).status_code == 400


def test_hint_words_come_from_controls_json():
    words = hint_words()
    assert "Contrast" in words and "Exposure" in words and "Saturation" in words


def test_decode_wav_resamples_to_16k_mono():
    import io
    import wave

    import numpy as np
    from server import decode_wav

    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(2)
        wf.setsampwidth(2)
        wf.setframerate(22050)
        wf.writeframes(np.zeros((22050, 2), dtype="<i2").tobytes())  # 1 s of stereo silence
    samples = decode_wav(buf.getvalue())
    assert samples.dtype == np.float32 and len(samples) == 16000


def test_non_wav_audio_gets_415(tmp_path):
    from server import decode_wav

    class DecodingTranscriber(FakeTranscriber):
        def transcribe(self, audio):
            decode_wav(audio)
            return super().transcribe(audio)

    r = client(tmp_path, DecodingTranscriber()).post("/transcribe", content=b"not audio", headers=auth())
    assert r.status_code == 415


def test_token_check_can_be_turned_off(tmp_path):
    c = TestClient(create_app(FakeTranscriber(), TOKEN, log_dir=tmp_path, require_token=False))
    assert c.post("/transcribe", content=b"RIFFfake").status_code == 200
    assert c.get("/info").status_code == 200

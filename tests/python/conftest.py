"""Shared pytest fixtures.

`pythonpath` in pyproject.toml puts verify/, tests/python/ and the fake
faster-whisper package on sys.path, so the modules under test import by name.
"""

from __future__ import annotations

import json
import struct

import faster_whisper
import pytest


# 44-byte RIFF/WAVE header, 16 kHz mono s16le -- byte for byte what the ffmpeg
# shim writes, so both halves of the harness produce the same samples.
def _wav_bytes(media_path: str) -> bytes:
    payload = f"FAKEWAV:{media_path}\n".encode()
    return (
        b"RIFF"
        + struct.pack("<I", 36 + len(payload))
        + b"WAVEfmt "
        + struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16)
        + b"data"
        + struct.pack("<I", len(payload))
        + payload
    )


@pytest.fixture(autouse=True)
def _reset_fake_whisper():
    """Each test sees a fresh recording of constructed models and media seen."""
    faster_whisper.WhisperModel.instances = []
    faster_whisper.WhisperModel.calls = []
    yield
    faster_whisper.WhisperModel.instances = []
    faster_whisper.WhisperModel.calls = []


@pytest.fixture
def fake_wav(tmp_path):
    """fake_wav("/media/x.mkv") -> path to a sample tagged with that media file."""
    counter = {"n": 0}

    def _make(media_path: str) -> str:
        counter["n"] += 1
        wav = tmp_path / f"sample-{counter['n']}.wav"
        wav.write_bytes(_wav_bytes(media_path))
        return str(wav)

    return _make


@pytest.fixture
def whisper_script(tmp_path, monkeypatch):
    """whisper_script({"/media/x.mkv": ["it", 0.97], "*": ["en", 0.9]})."""

    def _write(rules: dict) -> str:
        path = tmp_path / "whisper-script.json"
        path.write_text(json.dumps(rules), encoding="utf-8")
        monkeypatch.setenv("FAKE_WHISPER_SCRIPT", str(path))
        return str(path)

    return _write

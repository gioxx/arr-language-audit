"""Shared pytest fixtures and CSV helpers.

`pythonpath` in pyproject.toml puts verify/, tests/python/ and the fake
faster-whisper package on sys.path, so the modules under test import by name.

The fixtures that isolate a worker run from the developer's own environment
(`clean_env`, `sys_temp`, `shim_path`) live here because both test_verify.py
and test_resume.py drive `main()`; they are opt-in, so the report and harness
tests are unaffected. A module takes the first two with

    pytestmark = pytest.mark.usefixtures("clean_env", "sys_temp")
"""

from __future__ import annotations

import csv
import json
import os
import struct
import tempfile
from pathlib import Path

import audit_common
import faster_whisper
import pytest

ROOT = Path(__file__).resolve().parent.parent.parent
SHIM_BIN = ROOT / "tests" / "bats" / "fakes" / "bin"

ENV_VARS = (
    "WHISPER_MODEL",
    "SAMPLE_SECONDS",
    "SAMPLE_OFFSET_PCT",
    "MIN_FREE_SPACE_MB",
    "TEMP_DIR",
    "MIN_CONFIDENCE",
    "WHISPER_THREADS",
    "FAKE_WHISPER_SCRIPT",
    "FAKE_FFMPEG_FAIL",
    "FAKE_FFMPEG_LOG",
    "FAKE_DURATIONS",
)


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


@pytest.fixture
def clean_env(monkeypatch):
    """The developer's own WHISPER_MODEL/TEMP_DIR must not reach the code."""
    for name in ENV_VARS:
        monkeypatch.delenv(name, raising=False)


@pytest.fixture
def sys_temp(tmp_path, monkeypatch):
    """Stands in for the system temp dir; must be empty when a run is over."""
    holder = tmp_path / "systmp"
    holder.mkdir()
    monkeypatch.setattr(tempfile, "tempdir", str(holder))
    monkeypatch.setenv("TMPDIR", str(holder))
    return holder


@pytest.fixture
def shim_path(monkeypatch):
    """Put the fake ffmpeg/ffprobe ahead of anything real."""
    monkeypatch.setenv("PATH", str(SHIM_BIN) + os.pathsep + os.environ["PATH"])


# --- CSV helpers ------------------------------------------------------------


def media(tmp_path, name, content=b"not really a movie"):
    path = tmp_path / name
    path.write_bytes(content)
    return str(path)


def write_phase1(tmp_path, rows, name="in.csv"):
    path = tmp_path / name
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=audit_common.PHASE1_COLUMNS)
        writer.writeheader()
        for row in rows:
            writer.writerow({c: row.get(c, "") for c in audit_common.PHASE1_COLUMNS})
    return str(path)


def write_phase2(tmp_path, rows, name="prev.csv", columns=None):
    """A previous-run output CSV. `columns` writes an older schema verbatim."""
    fieldnames = list(columns or audit_common.PHASE2_COLUMNS)
    path = tmp_path / name
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({c: row.get(c, "") for c in fieldnames})
    return str(path)


def read_rows(path):
    with open(path, newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        return list(reader.fieldnames or []), list(reader)


def signature_of(path):
    st = os.stat(path)
    return str(int(st.st_size)), str(int(st.st_mtime))


def phase1_row(path, title="T", declared="eng", app="Radarr", episode=""):
    return {"App": app, "Title": title, "Year": "2001", "Episode": episode,
            "AudioLanguages": declared, "Path": path}

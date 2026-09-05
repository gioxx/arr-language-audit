"""Fake faster-whisper.

Importable in place of the real package (see `pythonpath` in pyproject.toml and
PYTHONPATH for the launcher e2e tests). Its decoder reads the waveform and
"FAKEWAV:<media path>" marker the ffmpeg shim writes; detection accepts only
decoded audio and answers from a JSON script.

    FAKE_WHISPER_SCRIPT   path to a JSON file:
        {"<media path>": ["it", 0.97], "<other>": "RAISE", "*": ["en", 0.9]}
      A rule of ["it", 0.97] is returned as (language, probability); the string
      "RAISE" makes the call raise; [null, 0.0] yields (None, 0.0). "*" is the
      fallback, itself defaulting to ("en", 0.9).

Class attributes record what happened: `instances` (constructor args), `calls`
(the media behind each sample, in order), `transcribe_calls` and `detect_calls`
(the arguments of each call to either API, so a test can prove which one the
worker reached for).
"""

from __future__ import annotations

import json
import os
from typing import ClassVar

from .audio import DecodedAudio

MARKER = b"FAKEWAV:"
DEFAULT_RULE = ["en", 0.9]


class _Info:
    """The subset of faster-whisper's TranscriptionInfo the code under test uses."""

    def __init__(self, language, prob):
        self.language = language
        self.language_probability = prob


def _source_of(wav_path) -> str:
    """The media path the ffmpeg shim recorded in this sample, or ""."""
    with open(wav_path, "rb") as handle:
        data = handle.read()
    marker = data.rfind(MARKER)
    if marker < 0:
        return ""
    return data[marker + len(MARKER):].decode("utf-8", "replace").removesuffix("\n")


def _script() -> dict:
    path = os.environ.get("FAKE_WHISPER_SCRIPT")
    if not path:
        return {}
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def _rule_for(source: str):
    script = _script()
    return script.get(source, script.get("*", DEFAULT_RULE))


class WhisperModel:
    """Records how it was built, which media it was asked about, and -- so a
    test can prove which detection API the worker used -- every transcribe()
    and detect_language() call it received."""

    instances: ClassVar[list] = []
    calls: ClassVar[list] = []
    transcribe_calls: ClassVar[list] = []
    detect_calls: ClassVar[list] = []

    def __init__(self, model_size_or_path, device=None, compute_type=None, **kw):
        self.args = (model_size_or_path, device, compute_type)
        self.kwargs = kw
        WhisperModel.instances.append(self)

    def _resolve(self, source):
        WhisperModel.calls.append(source)
        rule = _rule_for(source)
        if rule == "RAISE":
            raise RuntimeError("scripted failure")
        return rule

    def transcribe(self, wav_path, **kw):
        WhisperModel.transcribe_calls.append(wav_path)
        language, probability = self._resolve(_source_of(wav_path))

        def _segments():
            # Nothing may consume these: decoding segments is the slow path the
            # production code is supposed to avoid.
            raise AssertionError("segments were consumed")
            yield  # pragma: no cover - unreachable, makes this a generator

        return _segments(), _Info(language, probability)

    def detect_language(  # noqa: PLR0917 - mirrors the upstream public API
        self,
        audio=None,
        features=None,
        vad_filter=False,
        vad_parameters=None,
        language_detection_segments=1,
        language_detection_threshold=0.5,
    ):
        if not isinstance(audio, DecodedAudio):
            raise TypeError("detect_language requires a decoded waveform, not a path")
        WhisperModel.detect_calls.append({
            "audio": audio,
            "vad_filter": vad_filter,
            "language_detection_segments": language_detection_segments,
            "language_detection_threshold": language_detection_threshold,
        })
        language, probability = self._resolve(audio.source)
        return language, probability, []

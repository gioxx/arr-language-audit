"""Exercise the pinned faster-whisper audio boundary without model weights.

Run outside the fake-backed pytest harness:
    uvx --with-requirements verify/requirements.txt pytest -q -o pythonpath=verify tests/integration

The real PyAV decoder, WhisperModel.detect_language and feature extractor run;
only VAD decisions and the neural encoder/language scores are deterministic.
"""

from __future__ import annotations

import importlib
import wave
from types import SimpleNamespace

import faster_whisper
import numpy as np
import verify_audio_language as worker
from faster_whisper.feature_extractor import FeatureExtractor


def test_worker_passes_decoded_float32_waveform_to_real_whisper_detection(tmp_path, monkeypatch):
    assert "tests/fakes" not in faster_whisper.__file__, "contract test requires the real package"
    transcribe = importlib.import_module("faster_whisper.transcribe")
    samples = np.tile(np.array([1000, -1000], dtype="<i2"), 8000)
    saw_audio = []

    def speech_timestamps(audio, _parameters):
        assert isinstance(audio, np.ndarray), "detect_language requires a decoded ndarray, not a path"
        assert audio.dtype == np.float32
        assert audio.shape == (16000,)
        np.testing.assert_array_equal(audio, samples.astype(np.float32) / 32768.0)
        saw_audio.append(audio)
        return [{"start": 0, "end": audio.shape[0]}]

    def encode(features):
        assert features.ndim == 2
        assert features.shape[-1] == 3000
        assert np.isfinite(features).all()
        return features

    # Bypass __init__: no weights, tokenizer, model download or model session.
    model = object.__new__(faster_whisper.WhisperModel)
    model.feature_extractor = FeatureExtractor()
    model.encode = encode
    model.model = SimpleNamespace(detect_language=lambda _encoded: [[("<|it|>", 0.99)]])
    monkeypatch.setattr(transcribe, "get_speech_timestamps", speech_timestamps)
    wav = tmp_path / "sample.wav"
    with wave.open(str(wav), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(16000)
        handle.writeframes(samples.tobytes())
    assert worker.detect_language(model, str(wav)) == ("it", 0.99)
    assert len(saw_audio) == 1

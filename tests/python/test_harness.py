"""Smoke tests for the Python side of the harness: the fake faster-whisper
package and the shared constants module. If these fail, no other pytest test
can be trusted."""

from __future__ import annotations

import audit_common
import faster_whisper
import pytest
from faster_whisper.audio import decode_audio


def test_detect_language_returns_the_scripted_verdict(fake_wav, whisper_script):
    whisper_script({"/media/x.mkv": ["it", 0.97], "*": ["en", 0.9]})
    wav = fake_wav("/media/x.mkv")

    model = faster_whisper.WhisperModel("small", device="cpu", compute_type="int8")

    assert model.detect_language(audio=decode_audio(wav)) == ("it", 0.97, [])


def test_detection_fake_rejects_undecoded_paths(fake_wav):
    model = faster_whisper.WhisperModel("small")
    with pytest.raises(TypeError, match="decoded waveform"):
        model.detect_language(audio=fake_wav("/media/x.mkv"))


def test_transcribe_returns_the_scripted_verdict_without_decoding_segments(fake_wav, whisper_script):
    whisper_script({"/media/x.mkv": ["it", 0.97], "*": ["en", 0.9]})
    wav = fake_wav("/media/x.mkv")

    model = faster_whisper.WhisperModel("small", device="cpu", compute_type="int8")
    segments, info = model.transcribe(wav)

    assert info.language == "it"
    assert info.language_probability == 0.97
    with pytest.raises(AssertionError):
        next(iter(segments))


def test_unscripted_media_falls_back_to_the_wildcard_rule(fake_wav, whisper_script):
    whisper_script({"*": ["en", 0.9]})
    wav = fake_wav("/media/other.mkv")

    model = faster_whisper.WhisperModel("small")

    assert model.detect_language(audio=decode_audio(wav)) == ("en", 0.9, [])


def test_a_scripted_raise_propagates(fake_wav, whisper_script):
    whisper_script({"/media/x.mkv": "RAISE"})
    wav = fake_wav("/media/x.mkv")

    model = faster_whisper.WhisperModel("small")

    with pytest.raises(RuntimeError):
        model.transcribe(wav)


def test_the_model_records_its_constructor_args_and_the_media_it_saw(fake_wav, whisper_script):
    whisper_script({"*": ["en", 0.9]})

    model = faster_whisper.WhisperModel("small", device="cpu", compute_type="int8")
    model.transcribe(fake_wav("/media/x.mkv"))

    assert faster_whisper.WhisperModel.instances == [model]
    assert model.args == ("small", "cpu", "int8")
    assert faster_whisper.WhisperModel.calls == ["/media/x.mkv"]


def test_audit_common_declares_the_eleven_phase2_columns():
    assert len(audit_common.PHASE2_COLUMNS) == 11
    assert audit_common.PHASE2_COLUMNS[0] == "App"
    assert audit_common.MIN_PYTHON == (3, 9)


def test_a_scripted_null_language_is_returned_as_none(fake_wav, whisper_script):
    whisper_script({"/media/x.mkv": [None, 0.0]})
    wav = fake_wav("/media/x.mkv")

    model = faster_whisper.WhisperModel("small")

    assert model.detect_language(audio=decode_audio(wav)) == (None, 0.0, [])


def test_product_modules_import_on_floor():
    """L5: the modules must import on the declared Python floor, not just on the
    interpreter the developer happens to run."""
    # Imported inside the test on purpose: a failure here must be this test
    # failing, not the whole module failing to collect.
    import report  # noqa: PLC0415
    import verify_audio_language  # noqa: PLC0415

    assert callable(report.main)
    assert callable(verify_audio_language.main)

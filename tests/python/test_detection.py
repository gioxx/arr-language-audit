"""Detection quality in the phase 2 worker: which stream is listened to,
which detection API is used, and what a weak answer is worth.

Three audit findings live here.

    H5  the verdict ignored `language_probability`, so a 31%-confident "en"
        guessed off a music-only window was reported as CONFIRMED_NOT_ITALIAN
        -- the verdict that tells the user to re-download the file.
    R5  ffmpeg's own stream choice is "the one with the most channels", not
        the default one the README describes, so an Italian 2.0 default track
        next to an English 5.1 track was judged in English.
    P5  transcribe() only ever fed the first 30 s of the 60 s sample to
        language identification; detect_language() can look at a second
        window when the first one is unsure.

Nothing here touches the network, a real model or a real ffmpeg: the fake
`faster_whisper` package answers from a JSON script and the bats ffmpeg/ffprobe
shims are put on PATH.
"""

from __future__ import annotations

import json

import audit_common
import faster_whisper
import pytest
import verify_audio_language as vam
from conftest import (  # shared test helpers, not a private API
    Recorder,
    media,
    phase1_row,
    read_rows,
    write_phase1,
)
from faster_whisper.audio import DecodedAudio

pytestmark = pytest.mark.usefixtures("clean_env", "sys_temp")

# Two audio streams whose container indices (1 and 2) deliberately differ from
# their audio-relative indices (0 and 1): `-map 0:a:<n>` counts audio streams,
# and mixing the two up is exactly the bug R5 is about.
TWO_AUDIO_SECOND_IS_DEFAULT = json.dumps([
    {"index": 1, "codec_type": "audio", "disposition": {"default": 0}},
    {"index": 2, "codec_type": "audio", "disposition": {"default": 1}},
])
TWO_AUDIO_NONE_DEFAULT = json.dumps([
    {"index": 1, "codec_type": "audio", "disposition": {"default": 0}},
    {"index": 2, "codec_type": "audio", "disposition": {"default": 0}},
])


# --- H5: classify -----------------------------------------------------------


@pytest.mark.parametrize(
    ("lang", "prob", "expected"),
    [
        ("it", 0.97, audit_common.VERDICT_MISTAGGED),
        ("ITA", 0.61, audit_common.VERDICT_MISTAGGED),
        ("en", 0.9, audit_common.VERDICT_CONFIRMED),
        ("de", 0.6, audit_common.VERDICT_CONFIRMED),
        ("en", 0.31, audit_common.VERDICT_LOW_CONFIDENCE),
        ("it", 0.4, audit_common.VERDICT_LOW_CONFIDENCE),
        ("en", 0.0, audit_common.VERDICT_LOW_CONFIDENCE),
        (None, 0.99, audit_common.VERDICT_DETECTION_FAILED),
        (None, 0.0, audit_common.VERDICT_DETECTION_FAILED),
        ("", 0.9, audit_common.VERDICT_DETECTION_FAILED),
    ],
)
def test_classify(lang, prob, expected):
    """H5: a language nobody is confident about is its own verdict."""
    assert vam.classify(lang, prob, 0.6) == expected


@pytest.mark.parametrize(
    ("prob", "expected"),
    [
        (0.6, audit_common.VERDICT_CONFIRMED),
        (0.5999, audit_common.VERDICT_LOW_CONFIDENCE),
    ],
)
def test_classify_threshold_is_a_floor_not_a_gap(prob, expected):
    """H5: `prob == min_confidence` is confident enough."""
    assert vam.classify("en", prob, 0.6) == expected


def test_classify_honours_the_configured_threshold():
    """The same answer is low or not depending on MIN_CONFIDENCE alone."""
    assert vam.classify("en", 0.7, 0.6) == audit_common.VERDICT_CONFIRMED
    assert vam.classify("en", 0.7, 0.8) == audit_common.VERDICT_LOW_CONFIDENCE
    assert vam.classify("it", 0.7, 0.8) == audit_common.VERDICT_LOW_CONFIDENCE


# --- R5: probe_media --------------------------------------------------------


def test_probe_media_picks_the_default_disposition_audio_stream(shim_path, monkeypatch):
    """R5: the index is counted within the AUDIO streams, not the container."""
    monkeypatch.setenv("FAKE_STREAMS", TWO_AUDIO_SECOND_IS_DEFAULT)
    monkeypatch.setenv("FAKE_DURATIONS", json.dumps({"/media/x.mkv": 1200}))

    assert vam.probe_media("/media/x.mkv") == vam.MediaProbe(
        duration=1200.0, audio_stream=1
    )


def test_probe_media_falls_back_to_the_first_audio_stream(shim_path, monkeypatch):
    """R5: no stream flagged default -> the first one, never 'the loudest'."""
    monkeypatch.setenv("FAKE_STREAMS", TWO_AUDIO_NONE_DEFAULT)

    assert vam.probe_media("/media/x.mkv") == vam.MediaProbe(
        duration=600.0, audio_stream=0
    )


def test_probe_media_skips_video_streams_when_counting(shim_path, monkeypatch):
    """The video stream is stream 0 of the container and default in it; it
    must not shift the audio numbering `-map 0:a:<n>` uses."""
    monkeypatch.setenv("FAKE_STREAMS", json.dumps([
        {"index": 0, "codec_type": "video", "disposition": {"default": 1}},
        {"index": 1, "codec_type": "audio", "disposition": {"default": 0}},
        {"index": 2, "codec_type": "audio", "disposition": {"default": 1}},
    ]))

    assert vam.probe_media("/media/x.mkv").audio_stream == 1


def test_probe_media_without_audio_has_no_stream_to_map(shim_path, monkeypatch):
    monkeypatch.setenv("FAKE_STREAMS", "[]")

    assert vam.probe_media("/media/x.mkv") == vam.MediaProbe(
        duration=600.0, audio_stream=None
    )


def test_probe_media_asks_ffprobe_exactly_once(shim_path, monkeypatch, tmp_path):
    """Duration and stream choice come out of ONE invocation: this runs per
    file over a whole library."""
    log = tmp_path / "ffprobe.log"
    monkeypatch.setenv("FAKE_FFPROBE_LOG", str(log))

    assert vam.probe_media("/media/x.mkv").audio_stream == 0
    assert len(log.read_text(encoding="utf-8").splitlines()) == 1


def test_probe_media_asks_ffprobe_for_both_sections(monkeypatch):
    """The contract with a tool no test here can run: assert the whole argv.

    Every flag in it is load-bearing and silently so. Drop -show_format and
    ffprobe stops emitting format.duration, so every file is sampled from
    offset 0 instead of 25% in -- no error, no changed verdict count, nothing
    to notice. Drop -select_streams a and the array positions stop being the
    indices `-map 0:a:<n>` counts. Exact equality, deliberately: this argv
    should not drift without someone deciding to change it."""
    probe_json = json.dumps({
        "format": {"duration": "600"},
        "streams": [{"index": 0, "codec_type": "audio", "disposition": {"default": 1}}],
    })
    recorder = Recorder(payload=None, stdout=probe_json)
    monkeypatch.setattr(vam.subprocess, "run", recorder)

    assert vam.probe_media("/media/a.mkv") == vam.MediaProbe(600.0, 0)

    assert recorder.calls == [[
        "ffprobe", "-v", "error",
        "-select_streams", "a",
        "-show_streams",
        "-show_format",
        "-of", "json",
        "/media/a.mkv",
    ]]


def test_probe_media_garbage_output_is_no_probe(monkeypatch):
    """Y8: garbage from ffprobe means 'unknown', not a crash."""
    monkeypatch.setattr(vam.subprocess, "run",
                        Recorder(payload=None, stdout="not json{"))

    assert vam.probe_media("/media/a.mkv") == vam.MediaProbe(None, None)


def test_probe_media_missing_ffprobe_is_no_probe(monkeypatch):
    monkeypatch.setattr(vam.subprocess, "run",
                        Recorder(payload=None, exc=FileNotFoundError("ffprobe")))

    assert vam.probe_media("/media/a.mkv") == vam.MediaProbe(None, None)


def test_probe_media_keeps_the_stream_when_the_duration_is_unusable(monkeypatch):
    """A container with no duration still tells us which track to listen to."""
    payload = json.dumps({
        "format": {},
        "streams": [{"index": 1, "codec_type": "audio", "disposition": {"default": 1}}],
    })
    monkeypatch.setattr(vam.subprocess, "run", Recorder(payload=None, stdout=payload))

    assert vam.probe_media("/media/a.mkv") == vam.MediaProbe(None, 0)


# --- R5: what extract_sample tells ffmpeg -----------------------------------


def _ffmpeg_argv(tmp_path, monkeypatch, probe):
    """The exact argv extract_sample builds for `probe`."""
    recorder = Recorder()
    monkeypatch.setattr(vam.subprocess, "run", recorder)
    out_wav = str(tmp_path / "sample_1.wav")

    assert vam.extract_sample("/media/a.mkv", out_wav, vam.Config(), probe) is True

    return recorder.calls[0]


@pytest.mark.parametrize("stream", [0, 1, 3])
def test_extract_sample_maps_the_chosen_audio_stream(tmp_path, monkeypatch, stream):
    """R5: -map goes right after the input, and names an audio-relative index."""
    argv = _ffmpeg_argv(tmp_path, monkeypatch, vam.MediaProbe(600.0, stream))

    at_input = argv.index("-i")
    assert argv[at_input:at_input + 4] == ["-i", "/media/a.mkv", "-map", f"0:a:{stream}"]
    assert argv[-1] == str(tmp_path / "sample_1.wav")


def test_extract_sample_omits_map_when_the_probe_failed(tmp_path, monkeypatch):
    """An unprobeable file is still sampled -- ffmpeg picks, as it always did."""
    argv = _ffmpeg_argv(tmp_path, monkeypatch, vam.MediaProbe(None, None))

    assert "-map" not in argv
    assert argv[argv.index("-i") + 1] == "/media/a.mkv"
    assert argv[argv.index("-ss") + 1] == "0"


def test_extract_sample_uses_the_probed_duration_for_the_offset(tmp_path, monkeypatch):
    """The probe replaces the second ffprobe call, offset math unchanged."""
    argv = _ffmpeg_argv(tmp_path, monkeypatch, vam.MediaProbe(200.0, 0))

    assert argv[argv.index("-ss") + 1] == "50.0"
    assert argv[argv.index("-t") + 1] == "60"


def test_probe_then_extract_maps_the_default_stream(tmp_path, shim_path, monkeypatch):
    """R5 through both halves: what the shim reports is what ffmpeg is told."""
    monkeypatch.setenv("FAKE_STREAMS", TWO_AUDIO_SECOND_IS_DEFAULT)
    probe = vam.probe_media("/media/a.mkv")

    argv = _ffmpeg_argv(tmp_path, monkeypatch, probe)

    assert argv[argv.index("-map") + 1] == "0:a:1"


def test_e2e_run_samples_the_default_audio_stream(tmp_path, shim_path, whisper_script,
                                                  monkeypatch):
    """R5 end to end: the ffmpeg the worker really runs carries the -map."""
    path = media(tmp_path, "a.mkv")
    whisper_script({path: ["it", 0.97]})
    monkeypatch.setenv("FAKE_STREAMS", TWO_AUDIO_SECOND_IS_DEFAULT)
    log = tmp_path / "ffmpeg.log"
    monkeypatch.setenv("FAKE_FFMPEG_LOG", str(log))

    inp = write_phase1(tmp_path, [phase1_row(path)])
    assert vam.main(["--input", inp, "--output", str(tmp_path / "out.csv")]) == 0

    argv_line = log.read_text(encoding="utf-8").strip()
    assert f"-i {path} -map 0:a:1 -t 60" in argv_line


# --- P5: which detection API ------------------------------------------------


def test_detect_language_prefers_the_dedicated_detection_api(fake_wav, whisper_script):
    """P5: detect_language() looks at a second window when the first is
    unsure; transcribe() only ever saw the first 30 s."""
    whisper_script({"/media/x.mkv": ["it", 0.97]})
    wav = fake_wav("/media/x.mkv")
    model = faster_whisper.WhisperModel("tiny")

    assert vam.detect_language(model, wav) == ("it", 0.97)

    calls = faster_whisper.WhisperModel.detect_calls
    assert len(calls) == 1
    audio = calls[0]["audio"]
    assert isinstance(audio, DecodedAudio)
    assert audio.source == "/media/x.mkv"
    assert audio.shape[0] > 0
    assert {key: value for key, value in calls[0].items() if key != "audio"} == {
        "vad_filter": True,
        "language_detection_segments": 2,
        "language_detection_threshold": 0.5,
    }
    assert faster_whisper.WhisperModel.transcribe_calls == []
    assert faster_whisper.WhisperModel.calls == ["/media/x.mkv"]


def test_detect_language_falls_back_to_transcribe(fake_wav, whisper_script, monkeypatch):
    """An older faster-whisper without detect_language() must still work."""
    whisper_script({"/media/x.mkv": ["en", 0.42]})
    wav = fake_wav("/media/x.mkv")
    model = faster_whisper.WhisperModel("tiny")
    monkeypatch.delattr(faster_whisper.WhisperModel, "detect_language")

    assert vam.detect_language(model, wav) == ("en", 0.42)

    assert faster_whisper.WhisperModel.transcribe_calls == [wav]
    assert faster_whisper.WhisperModel.detect_calls == []


class _Info:
    def __init__(self, language, probability):
        self.language = language
        self.language_probability = probability


class _LegacyDetectModel:
    """A faster-whisper that HAS detect_language() but not today's signature.

    The narrow signature is the point: Python raises the TypeError at the call
    site, exactly as a real older build would, so nothing here has to
    impersonate the error."""

    def __init__(self, transcribed=("en", 0.42)):
        self.transcribe_calls = []
        self.transcribed = transcribed

    def detect_language(self, audio=None, vad_filter=False):
        # Unreachable while the worker passes the windowing keywords; if it
        # ever stops, this answer makes the test fail rather than pass.
        return "xx", 1.0, []

    def transcribe(self, wav_path, **kwargs):
        self.transcribe_calls.append(wav_path)
        return iter(()), _Info(*self.transcribed)


class _BrokenDetectModel:
    """A detector that really failed, as opposed to one that is out of date."""

    def __init__(self):
        self.transcribe_calls = []

    def detect_language(self, **kwargs):
        raise RuntimeError("CUDA out of memory")

    def transcribe(self, wav_path, **kwargs):
        self.transcribe_calls.append(wav_path)
        return iter(()), _Info("it", 0.99)


def test_detect_language_falls_back_on_a_signature_mismatch():
    """Users may still have older faster-whisper builds installed. A build
    whose detect_language() predates the windowing keywords must reach the
    fallback, not turn every file in the library into DETECTION_FAILED."""
    model = _LegacyDetectModel()

    assert vam.detect_language(model, "/tmp/s.wav") == ("en", 0.42)
    assert model.transcribe_calls == ["/tmp/s.wav"]


def test_detect_language_does_not_swallow_a_real_detector_failure(fake_wav):
    """The fallback is for version drift only: a detector that blew up stays
    blown up, and verify_one records it as one DETECTION_FAILED row."""
    model = _BrokenDetectModel()

    with pytest.raises(RuntimeError):
        vam.detect_language(model, fake_wav("/media/x.mkv"))
    assert model.transcribe_calls == []


def test_detect_language_coerces_a_missing_probability(fake_wav, whisper_script):
    """D8, through the detection API this time."""
    whisper_script({"/media/x.mkv": ["it", None]})
    wav = fake_wav("/media/x.mkv")

    assert vam.detect_language(faster_whisper.WhisperModel("tiny"), wav) == ("it", 0.0)


def test_e2e_run_uses_the_detection_api(tmp_path, shim_path, whisper_script):
    """P5 end to end: the worker never reaches for transcribe()."""
    path = media(tmp_path, "a.mkv")
    whisper_script({path: ["it", 0.97]})

    inp = write_phase1(tmp_path, [phase1_row(path)])
    assert vam.main(["--input", inp, "--output", str(tmp_path / "out.csv")]) == 0

    assert len(faster_whisper.WhisperModel.detect_calls) == 1
    assert faster_whisper.WhisperModel.transcribe_calls == []


# --- H5 end to end ----------------------------------------------------------


def test_e2e_low_confidence_row_and_summary(tmp_path, shim_path, whisper_script,
                                            monkeypatch, capsys):
    """H5: a 70%-confident "en" under MIN_CONFIDENCE=0.8 must not be reported
    as 'redownload this file'."""
    path = media(tmp_path, "a.mkv")
    whisper_script({path: ["en", 0.7]})
    monkeypatch.setenv("MIN_CONFIDENCE", "0.8")

    inp = write_phase1(tmp_path, [phase1_row(path)])
    out = str(tmp_path / "out.csv")
    assert vam.main(["--input", inp, "--output", out]) == 0

    _header, rows = read_rows(out)
    assert rows[0]["Verdict"] == audit_common.VERDICT_LOW_CONFIDENCE
    # The weak answer is still recorded: it is what the user judges the
    # re-run against.
    assert rows[0]["DetectedLanguage"] == "en"
    assert rows[0]["Confidence"] == "0.70"

    err = capsys.readouterr().err
    assert "Low confidence:               1" in err
    assert "Confirmed not Italian:        0" in err
    assert "Errors this run:              0" in err


def test_e2e_low_confidence_is_kept_then_retried(tmp_path, shim_path, whisper_script,
                                                 monkeypatch):
    """A LOW_CONFIDENCE row is a real verdict on resume, and --retry-errors
    listens again -- a bigger model or a different offset can settle it."""
    path = media(tmp_path, "a.mkv")
    whisper_script({path: ["en", 0.7]})
    monkeypatch.setenv("MIN_CONFIDENCE", "0.8")
    inp = write_phase1(tmp_path, [phase1_row(path)])
    out = str(tmp_path / "out.csv")

    assert vam.main(["--input", inp, "--output", out]) == 0
    assert faster_whisper.WhisperModel.calls == [path]

    # A plain resume leaves it alone: it was listened to, unlike an error row.
    assert vam.main(["--input", inp, "--output", out]) == 0
    assert faster_whisper.WhisperModel.calls == [path]
    # ... and run 2 rewrites the output in full, so the row has to have
    # survived that rewrite, not merely have escaped re-detection.
    _header, kept = read_rows(out)
    assert len(kept) == 1
    assert kept[0]["Verdict"] == audit_common.VERDICT_LOW_CONFIDENCE
    assert kept[0]["Confidence"] == "0.70"
    assert kept[0]["DetectedLanguage"] == "en"

    whisper_script({path: ["en", 0.95]})
    assert vam.main(["--input", inp, "--output", out, "--retry-errors"]) == 0
    assert faster_whisper.WhisperModel.calls == [path, path]

    _header, rows = read_rows(out)
    assert len(rows) == 1
    assert rows[0]["Verdict"] == audit_common.VERDICT_CONFIRMED
    assert rows[0]["Confidence"] == "0.95"


def test_e2e_low_confidence_is_not_an_error_exit(tmp_path, shim_path, whisper_script,
                                                 monkeypatch):
    """Exit 3 means 'nothing could be verified'. A run that only produced weak
    answers did verify them, so it is a plain success."""
    path = media(tmp_path, "a.mkv")
    whisper_script({path: ["en", 0.1]})
    monkeypatch.setenv("MIN_CONFIDENCE", "0.8")

    inp = write_phase1(tmp_path, [phase1_row(path)])
    assert vam.main(["--input", inp, "--output", str(tmp_path / "out.csv")]) == 0


def test_min_confidence_is_read_from_the_environment():
    assert vam.Config.from_env({}).min_confidence == 0.6
    assert vam.Config.from_env({"MIN_CONFIDENCE": ""}).min_confidence == 0.6
    assert vam.Config.from_env({"MIN_CONFIDENCE": "0.8"}).min_confidence == 0.8
    with pytest.raises(vam.ConfigError):
        vam.Config.from_env({"MIN_CONFIDENCE": "abc"})
    with pytest.raises(vam.ConfigError):
        vam.Config.from_env({"MIN_CONFIDENCE": "1.5"})


def test_help_documents_the_new_verdict_and_knobs(capsys):
    """The verdict the user sees in the CSV has to be findable in --help."""
    with pytest.raises(SystemExit):
        vam.main(["--help"])

    out = capsys.readouterr().out
    assert "LOW_CONFIDENCE" in out
    assert "MIN_CONFIDENCE" in out
    assert "WHISPER_THREADS" in out

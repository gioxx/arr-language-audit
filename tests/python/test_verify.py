"""Tests for verify/verify_audio_language.py.

Nothing here touches the network, a real model or a real ffmpeg: the fake
`faster_whisper` package (tests/fakes/pypath) answers from a JSON script and
the bats ffmpeg/ffprobe shims are put on PATH.

Every test redirects `tempfile.tempdir` into its own tmp_path, so a leaked
scratch directory shows up as a test failure instead of as litter in /tmp.
"""

from __future__ import annotations

import os
import subprocess
from decimal import Decimal
from pathlib import Path

import audit_common
import faster_whisper
import pytest
import verify_audio_language as vam
from conftest import (  # shared test helpers, not a private API
    Recorder,
    media,
    phase1_row,
    read_rows,
    signature_of,
    write_phase1,
    write_phase2,
)

pytestmark = pytest.mark.usefixtures("clean_env", "sys_temp")


# --- helpers ----------------------------------------------------------------


class _Info:
    def __init__(self, language, probability):
        self.language = language
        self.language_probability = probability


class ScriptedModel:
    """A model injected in place of load_model()'s return value.

    Deliberately has no detect_language(), so it drives detect_language()'s
    transcribe() fallback; the dedicated API is covered in test_detection.py."""

    def __init__(self, behaviour):
        self.behaviour = behaviour
        self.calls = 0

    def transcribe(self, wav_path, **kwargs):
        self.calls += 1
        outcome = self.behaviour
        if isinstance(outcome, type) and issubclass(outcome, BaseException):
            raise outcome
        return iter(()), _Info(*outcome)


# --- Y2: is_italian ---------------------------------------------------------


@pytest.mark.parametrize(
    ("lang", "expected"),
    [("it", True), ("IT", True), ("ita", True), ("ITA", True),
     ("en", False), ("ita-x", False), ("", False), (None, False)],
)
def test_is_italian(lang, expected):
    """Y2: a None language must answer False, not raise."""
    assert vam.is_italian(lang) is expected


# --- Y4-Y8: sample extraction ----------------------------------------------

# What probe_media() would have returned for an ordinary 10-minute file; the
# stream choice itself is exercised in test_detection.py.
PROBE = vam.MediaProbe(duration=600.0, audio_stream=0)


@pytest.mark.parametrize(
    ("duration", "expected_ss"),
    [(100.0, "25.0"), (50.0, "0"), (200.0, "50.0"), (None, "0")],
)
def test_extract_sample_offset_math(tmp_path, monkeypatch, duration, expected_ss):
    """Y4: where the 60 s window starts, and the exact ffmpeg argv."""
    recorder = Recorder()
    monkeypatch.setattr(vam.subprocess, "run", recorder)

    out_wav = str(tmp_path / "sample_1.wav")
    probe = vam.MediaProbe(duration=duration, audio_stream=0)
    assert vam.extract_sample("/media/a.mkv", out_wav, vam.Config(), probe) is True

    argv = recorder.calls[0]
    assert argv[0] == "ffmpeg"
    assert argv[-1] == out_wav
    assert argv[argv.index("-ss") + 1] == expected_ss
    assert argv[argv.index("-i") + 1] == "/media/a.mkv"
    assert argv[argv.index("-t") + 1] == "60"
    joined = " ".join(argv)
    assert "-nostdin -loglevel error -y" in joined
    assert "-vn -acodec pcm_s16le -ar 16000 -ac 1" in joined


def test_extract_sample_zero_byte_output_is_failure(tmp_path, monkeypatch):
    """Y5: ffmpeg exited 0 but produced nothing usable."""
    monkeypatch.setattr(vam.subprocess, "run", Recorder(payload=b""))
    assert vam.extract_sample("/media/a.mkv", str(tmp_path / "s.wav"), vam.Config(),
                              PROBE) is False


def test_extract_sample_ffmpeg_error_logs_truncated_stderr(tmp_path, monkeypatch, capsys):
    """Y6: a 1 KB ffmpeg complaint is truncated, and names the file."""
    noise = "E" * 1000
    exc = subprocess.CalledProcessError(1, ["ffmpeg"], output="", stderr=noise)
    monkeypatch.setattr(vam.subprocess, "run", Recorder(exc=exc))

    assert vam.extract_sample("/media/a.mkv", str(tmp_path / "s.wav"), vam.Config(),
                              PROBE) is False

    line = capsys.readouterr().err.strip()
    assert "/media/a.mkv" in line
    assert noise not in line
    assert len(line) <= len("/media/a.mkv") + 230


def test_extract_sample_timeout_is_failure(tmp_path, monkeypatch, capsys):
    """Y7: a hung ffmpeg is one failed row, not a dead run."""
    exc = subprocess.TimeoutExpired(["ffmpeg"], 120)
    monkeypatch.setattr(vam.subprocess, "run", Recorder(exc=exc))
    assert vam.extract_sample("/media/a.mkv", str(tmp_path / "s.wav"), vam.Config(),
                              PROBE) is False
    assert "/media/a.mkv" in capsys.readouterr().err


# --- Y9: model construction -------------------------------------------------


@pytest.mark.parametrize(
    ("threads", "expected"),
    [(0, None), (3, 3)],
)
def test_load_model_uses_config_model_cpu_int8_and_threads(threads, expected):
    """Y9: the real load_model against the fake package."""
    cfg = vam.Config(whisper_model="tiny", whisper_threads=threads)
    vam.load_model(cfg)

    built = faster_whisper.WhisperModel.instances[-1]
    assert built.args == ("tiny", "cpu", "int8")
    assert built.kwargs["cpu_threads"] == (expected if expected else (os.cpu_count() or 4))


def test_detect_language_coerces_a_missing_probability():
    """Y13/D8: a detector that names a language but no probability must not
    blow up the f-string that formats it."""
    model = ScriptedModel(("it", None))
    assert vam.detect_language(model, "/tmp/s.wav") == ("it", 0.0)


def test_detect_language_passes_language_and_probability_through():
    model = ScriptedModel(("en", 0.42))
    assert vam.detect_language(model, "/tmp/s.wav") == ("en", 0.42)


# --- Y30: configuration -----------------------------------------------------


def test_config_from_env_empty_is_default_and_garbage_raises():
    """Y30: an exported-but-empty variable is 'unset', not '0'."""
    assert vam.Config.from_env({"SAMPLE_SECONDS": ""}).sample_seconds == 60
    assert vam.Config.from_env({}).sample_seconds == 60
    assert vam.Config.from_env({"SAMPLE_SECONDS": "30"}).sample_seconds == 30
    assert vam.Config.from_env({"TEMP_DIR": ""}).temp_parent is None
    assert vam.Config.from_env({"TEMP_DIR": "/scratch"}).temp_parent == "/scratch"
    with pytest.raises(vam.ConfigError):
        vam.Config.from_env({"SAMPLE_SECONDS": "abc"})
    with pytest.raises(vam.ConfigError):
        vam.Config.from_env({"SAMPLE_OFFSET_PCT": "abc"})


def test_help_works_with_a_broken_env(monkeypatch, capsys):
    """Y30: --help must not be hostage to a bad SAMPLE_SECONDS."""
    monkeypatch.setenv("SAMPLE_SECONDS", "abc")
    with pytest.raises(SystemExit) as excinfo:
        vam.main(["--help"])
    assert excinfo.value.code == 0
    assert "usage:" in capsys.readouterr().out


def test_bad_env_returns_1_with_a_message(tmp_path, monkeypatch, capsys):
    """Y30: a bad env is a clean exit 1, not a traceback."""
    monkeypatch.setenv("SAMPLE_SECONDS", "abc")
    inp = write_phase1(tmp_path, [phase1_row(media(tmp_path, "a.mkv"))])
    rc = vam.main(["--input", inp, "--output", str(tmp_path / "out.csv")])
    assert rc == 1
    assert "SAMPLE_SECONDS" in capsys.readouterr().err


# --- Y25/Y26/Y29: pre-flight ------------------------------------------------


class _Usage:
    """shutil.disk_usage's named tuple, minus the tuple."""

    def __init__(self, free):
        self.total = free * 10
        self.used = self.total - free
        self.free = free


def test_check_disk_space_raises_with_message(tmp_path, monkeypatch):
    """Y25: the helper raises; only main decides the exit code."""
    monkeypatch.setattr(vam.shutil, "disk_usage", lambda _p: _Usage(10 * 1024 * 1024))
    with pytest.raises(vam.DiskSpaceError) as excinfo:
        vam.check_disk_space(str(tmp_path), 500)
    assert "need at least" in str(excinfo.value)


def test_low_disk_space_exits_1(tmp_path, monkeypatch, capsys):
    """Y25: and main turns it into exit 1 with the same message."""
    monkeypatch.setattr(vam.shutil, "disk_usage", lambda _p: _Usage(10 * 1024 * 1024))
    inp = write_phase1(tmp_path, [phase1_row(media(tmp_path, "a.mkv"))])
    rc = vam.main(["--input", inp, "--output", str(tmp_path / "out.csv")])
    assert rc == 1
    assert "need at least" in capsys.readouterr().err


def test_disk_filling_up_mid_run_exits_1_with_a_valid_csv(tmp_path, shim_path,
                                                          whisper_script, monkeypatch,
                                                          capsys):
    """Y25: the per-file check aborts the run, but what was written stays
    readable -- the rows already verified are not lost."""
    a = media(tmp_path, "a.mkv")
    b = media(tmp_path, "b.mkv")
    whisper_script({"*": ["it", 0.9]})

    seen = {"n": 0}

    def usage(_path):
        seen["n"] += 1
        # pre-flight + first file are fine; the disk fills up before the second.
        return _Usage(10 * 1024 * 1024 if seen["n"] > 2 else 900 * 1024 * 1024)

    monkeypatch.setattr(vam.shutil, "disk_usage", usage)

    inp = write_phase1(tmp_path, [phase1_row(a), phase1_row(b)])
    out = str(tmp_path / "out.csv")
    assert vam.main(["--input", inp, "--output", out]) == 1
    assert "need at least" in capsys.readouterr().err

    header, rows = read_rows(out)
    assert header == audit_common.PHASE2_COLUMNS
    assert [r["Path"] for r in rows] == [a]


def test_usage_error_exits_2(capsys):
    """The --help epilog promises 2 for a bad flag; argparse must keep it."""
    with pytest.raises(SystemExit) as excinfo:
        vam.main(["--bogus"])
    assert excinfo.value.code == 2
    assert "unrecognized arguments" in capsys.readouterr().err


def test_missing_input_exits_1(tmp_path, capsys):
    """Y26."""
    rc = vam.main(["--input", str(tmp_path / "nope.csv"), "--output", str(tmp_path / "o.csv")])
    assert rc == 1
    assert "not found" in capsys.readouterr().err


def test_output_directory_created(tmp_path, shim_path, whisper_script):
    """Y29: a nested --output path is created, not an OSError."""
    path = media(tmp_path, "a.mkv")
    whisper_script({path: ["it", 0.97]})
    inp = write_phase1(tmp_path, [phase1_row(path)])
    out = tmp_path / "deep" / "nested" / "out.csv"
    assert vam.main(["--input", inp, "--output", str(out)]) == 0
    assert out.is_file()


def test_unusable_output_path_exits_1(tmp_path, shim_path, whisper_script, capsys):
    """Y29 twin: an output path that cannot be used is exit 1, not a traceback.

    The two cases fail at different points, and the assertions say so: a
    directory that cannot be created is caught in the pre-flight, before any
    model is loaded; an output path that is itself a directory only fails when
    the file is opened, which is after the model load (the model is loaded
    first on purpose, so that a failure there cannot truncate the previous
    results -- see test_model_load_failure_leaves_previous_output_untouched)."""
    path = media(tmp_path, "a.mkv")
    whisper_script({path: ["it", 0.97]})
    inp = write_phase1(tmp_path, [phase1_row(path)])

    blocker = tmp_path / "blocker"
    blocker.write_text("I am a file, not a directory", encoding="utf-8")
    assert vam.main(["--input", inp, "--output", str(blocker / "out.csv")]) == 1
    assert "cannot create the output directory" in capsys.readouterr().err
    assert faster_whisper.WhisperModel.instances == []

    a_directory = tmp_path / "adir"
    a_directory.mkdir()
    assert vam.main(["--input", inp, "--output", str(a_directory)]) == 1
    assert "cannot write" in capsys.readouterr().err
    assert len(faster_whisper.WhisperModel.instances) == 1


# --- Y11-Y13, Y28, Y32: the detection loop ---------------------------------


def test_e2e_fresh_run_writes_all_verdicts(tmp_path, shim_path, whisper_script,
                                           monkeypatch, capsys):
    """Y11: one row per input row, in order, with the expected verdicts."""
    good_it = media(tmp_path, "italian.mkv")
    good_en = media(tmp_path, "english.mkv")
    gone = str(tmp_path / "gone.mkv")
    broken = media(tmp_path, "broken.mkv")
    monkeypatch.setenv("FAKE_FFMPEG_FAIL", "broken.mkv")
    whisper_script({good_it: ["it", 0.97], good_en: ["en", 0.88]})

    inp = write_phase1(tmp_path, [
        phase1_row(good_it, title="A", declared="eng"),
        phase1_row(good_en, title="B", declared="ita"),
        phase1_row(gone, title="C", declared="eng"),
        phase1_row(broken, title="D", declared="eng"),
    ])
    out = str(tmp_path / "out.csv")
    assert vam.main(["--input", inp, "--output", out]) == 0

    header, rows = read_rows(out)
    assert header == audit_common.PHASE2_COLUMNS
    assert len(header) == 11
    assert [r["Path"] for r in rows] == [good_it, good_en, gone, broken]
    assert [r["Verdict"] for r in rows] == [
        audit_common.VERDICT_MISTAGGED,
        audit_common.VERDICT_CONFIRMED,
        audit_common.VERDICT_FILE_NOT_FOUND,
        audit_common.VERDICT_EXTRACTION_FAILED,
    ]
    assert rows[0]["Confidence"] == "0.97"
    assert rows[0]["DetectedLanguage"] == "it"
    assert [r["DeclaredAudioLanguages"] for r in rows] == ["eng", "ita", "eng", "eng"]
    assert (rows[2]["FileSize"], rows[2]["FileMtime"]) == ("", "")
    assert rows[3]["FileSize"] == str(os.stat(broken).st_size)
    assert Decimal(rows[3]["FileMtime"]) * 1_000_000_000 == os.stat(broken).st_mtime_ns
    assert "Errors this run:" in capsys.readouterr().err


def test_e2e_detector_exception_marks_row_and_continues(tmp_path, shim_path,
                                                        whisper_script, sys_temp):
    """Y12: one exploding file does not stop the run."""
    a = media(tmp_path, "a.mkv")
    b = media(tmp_path, "b.mkv")
    c = media(tmp_path, "c.mkv")
    whisper_script({a: ["it", 0.9], b: "RAISE", c: ["en", 0.8]})

    inp = write_phase1(tmp_path, [phase1_row(a), phase1_row(b), phase1_row(c)])
    out = str(tmp_path / "out.csv")
    assert vam.main(["--input", inp, "--output", out]) == 0

    _header, rows = read_rows(out)
    assert [r["Verdict"] for r in rows] == [
        audit_common.VERDICT_MISTAGGED,
        audit_common.VERDICT_DETECTION_FAILED,
        audit_common.VERDICT_CONFIRMED,
    ]
    assert list(sys_temp.iterdir()) == []


def test_detector_returning_none_language_is_detection_failed(tmp_path, shim_path,
                                                              whisper_script):
    """Y13: language=None is a verdict, not a traceback."""
    silent = media(tmp_path, "silent.mkv")
    spoken = media(tmp_path, "spoken.mkv")
    whisper_script({silent: [None, 0.0], spoken: ["it", 0.95]})

    inp = write_phase1(tmp_path, [phase1_row(silent), phase1_row(spoken)])
    out = str(tmp_path / "out.csv")
    assert vam.main(["--input", inp, "--output", out]) == 0

    _header, rows = read_rows(out)
    assert rows[0]["Verdict"] == audit_common.VERDICT_DETECTION_FAILED
    assert rows[1]["Verdict"] == audit_common.VERDICT_MISTAGGED


def test_null_probability_still_writes_a_verdict(tmp_path, shim_path, whisper_script):
    """Y13/D8: ("it", None) is a normal row, not a traceback.

    H5 decides which row: a detector that names a language but no probability
    at all has told us nothing, so 0.00 is below any MIN_CONFIDENCE and the
    verdict is LOW_CONFIDENCE, not "this file is fine"."""
    path = media(tmp_path, "a.mkv")
    whisper_script({path: ["it", None]})
    inp = write_phase1(tmp_path, [phase1_row(path)])
    out = str(tmp_path / "out.csv")
    assert vam.main(["--input", inp, "--output", out]) == 0

    _header, rows = read_rows(out)
    assert rows[0]["Verdict"] == audit_common.VERDICT_LOW_CONFIDENCE
    assert rows[0]["DetectedLanguage"] == "it"
    assert rows[0]["Confidence"] == "0.00"


def test_empty_path_row_is_file_not_found(tmp_path, shim_path, whisper_script):
    """Y28."""
    good = media(tmp_path, "a.mkv")
    whisper_script({good: ["it", 0.9]})
    inp = write_phase1(tmp_path, [phase1_row(""), phase1_row(good)])
    out = str(tmp_path / "out.csv")
    assert vam.main(["--input", inp, "--output", out]) == 0

    _header, rows = read_rows(out)
    assert rows[0]["Verdict"] == audit_common.VERDICT_FILE_NOT_FOUND
    assert rows[1]["Verdict"] == audit_common.VERDICT_MISTAGGED


def test_every_file_errored_exits_3(tmp_path, shim_path, capsys):
    """Y32 (R7): a run where nothing could be verified is not a success."""
    inp = write_phase1(tmp_path, [
        phase1_row(str(tmp_path / "gone-a.mkv")),
        phase1_row(str(tmp_path / "gone-b.mkv")),
    ])
    out = str(tmp_path / "out.csv")
    assert vam.main(["--input", inp, "--output", out]) == 3
    assert "every file errored" in capsys.readouterr().err


# --- Y31: the model is loaded before the output is touched ------------------


def test_model_load_failure_leaves_previous_output_untouched(tmp_path, shim_path,
                                                             monkeypatch, capsys):
    """Y31 (R1): an ImportError must not cost the previous run's verdicts."""
    def boom(_cfg):
        raise ImportError("No module named 'faster_whisper'")

    monkeypatch.setattr(vam, "load_model", boom)

    fresh = media(tmp_path, "fresh.mkv")
    kept = media(tmp_path, "kept.mkv")
    size, mtime = signature_of(kept)
    out = write_phase2(tmp_path, [{
        "App": "Radarr", "Title": "Kept", "Year": "2000", "Episode": "",
        "DeclaredAudioLanguages": "eng", "DetectedLanguage": "en",
        "Confidence": "0.90", "Verdict": audit_common.VERDICT_CONFIRMED,
        "Path": kept, "FileSize": size, "FileMtime": mtime,
    }], name="out.csv")
    before = Path(out).read_bytes()

    inp = write_phase1(tmp_path, [phase1_row(kept), phase1_row(fresh)])
    assert vam.main(["--input", inp, "--output", out]) == 1
    assert Path(out).read_bytes() == before
    assert "faster_whisper" in capsys.readouterr().err


# --- Y22: a crash mid-detection still leaves a valid CSV --------------------


def test_output_has_header_and_kept_rows_even_if_detection_crashes(
    tmp_path, shim_path, sys_temp, monkeypatch
):
    """Y22: Ctrl-C during detection."""
    model = ScriptedModel(KeyboardInterrupt)
    monkeypatch.setattr(vam, "load_model", lambda _cfg: model)

    kept = media(tmp_path, "kept.mkv")
    fresh = media(tmp_path, "fresh.mkv")
    size, mtime = signature_of(kept)
    out = write_phase2(tmp_path, [{
        "App": "Radarr", "Title": "Kept", "Year": "2000", "Episode": "",
        "DeclaredAudioLanguages": "eng", "DetectedLanguage": "en",
        "Confidence": "0.90", "Verdict": audit_common.VERDICT_CONFIRMED,
        "Path": kept, "FileSize": size, "FileMtime": mtime,
    }], name="out.csv")

    inp = write_phase1(tmp_path, [phase1_row(kept), phase1_row(fresh)])
    rc = vam.main(["--input", inp, "--output", out])

    # 130 is the contract the launcher and the orchestrator key off, not
    # merely "something non-zero".
    assert rc == vam.EXIT_INTERRUPTED == 130
    header, rows = read_rows(out)
    assert header == audit_common.PHASE2_COLUMNS
    assert [r["Path"] for r in rows] == [kept]
    assert list(sys_temp.iterdir()) == []


# --- Y23/Y24: the temp directory -------------------------------------------


def test_user_temp_dir_survives_run(tmp_path, shim_path, whisper_script, monkeypatch):
    """Y23 (D6): TEMP_DIR is a parent to borrow, never a directory to delete."""
    keep = tmp_path / "keep"
    keep.mkdir()
    marker = keep / "marker.txt"
    marker.write_text("do not delete me", encoding="utf-8")
    (keep / "sub").mkdir()
    (keep / "sub" / "nested.txt").write_text("also mine", encoding="utf-8")
    monkeypatch.setenv("TEMP_DIR", str(keep))

    path = media(tmp_path, "a.mkv")
    whisper_script({path: ["it", 0.97]})
    inp = write_phase1(tmp_path, [phase1_row(path)])
    assert vam.main(["--input", inp, "--output", str(tmp_path / "out.csv")]) == 0

    assert keep.is_dir()
    assert marker.read_text(encoding="utf-8") == "do not delete me"
    assert (keep / "sub" / "nested.txt").read_text(encoding="utf-8") == "also mine"
    assert list(keep.glob("**/sample_*.wav")) == []
    assert list(keep.glob("lang-check-*")) == []


def test_default_temp_dir_removed_on_both_paths(tmp_path, shim_path, whisper_script,
                                                sys_temp):
    """Y24: mkdtemp's directory is cleaned up whether or not there was work."""
    path = media(tmp_path, "a.mkv")
    whisper_script({path: ["it", 0.97]})
    inp = write_phase1(tmp_path, [phase1_row(path)])
    out = str(tmp_path / "out.csv")

    assert vam.main(["--input", inp, "--output", out]) == 0
    assert list(sys_temp.glob("lang-check-*")) == []
    assert len(faster_whisper.WhisperModel.instances) == 1

    # Second run: same signature, nothing to verify.
    assert vam.main(["--input", inp, "--output", out]) == 0
    assert list(sys_temp.glob("lang-check-*")) == []
    # R1: no model is loaded when there is no work for it.
    assert len(faster_whisper.WhisperModel.instances) == 1


def test_make_temp_dir_always_creates_a_private_subdirectory(tmp_path):
    """Y23: even with TEMP_DIR set, the removable directory is our own."""
    parent = tmp_path / "parent"
    created = vam.make_temp_dir(vam.Config(temp_parent=str(parent)))
    try:
        assert Path(created).parent == parent
        assert Path(created).name.startswith("lang-check-")
    finally:
        os.rmdir(created)

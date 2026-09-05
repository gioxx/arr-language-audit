"""Worker boundaries: malformed inputs must not become trusted verdicts."""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import audit_common
import pytest
import verify_audio_language as vam
from conftest import media, phase1_row, read_rows, write_phase1, write_phase2

pytestmark = pytest.mark.usefixtures("clean_env", "sys_temp")


@pytest.mark.parametrize("name", ["SAMPLE_OFFSET_PCT", "MIN_CONFIDENCE"])
@pytest.mark.parametrize("value", ["nan", "NaN", "inf", "-inf"])
def test_config_rejects_nonfinite_numbers(name, value):
    with pytest.raises(vam.ConfigError):
        vam.Config.from_env({name: value})


def test_negative_limit_is_usage_error_before_input_is_opened():
    with pytest.raises(SystemExit) as exc:
        vam.main(["--limit", "-1"])
    assert exc.value.code == 2


@pytest.mark.parametrize("prob", [float("nan"), float("inf"), -0.1, 1.1])
def test_invalid_probability_cannot_produce_a_trusted_verdict(prob):
    assert vam.classify("en", prob, 0.6) == audit_common.VERDICT_DETECTION_FAILED


@pytest.mark.parametrize("lang", ["   ", 42, {"language": "it"}])
def test_invalid_language_cannot_produce_a_trusted_verdict(lang):
    assert vam.classify(lang, 0.99, 0.6) == audit_common.VERDICT_DETECTION_FAILED


@pytest.mark.parametrize("data", [
    {"streams": 42},
    {"streams": [{"disposition": 1}]},
    {"streams": [{"disposition": [1]}]},
])
def test_malformed_probe_metadata_never_aborts_the_scan(monkeypatch, data):
    monkeypatch.setattr(vam.subprocess, "run", lambda *a, **kw:
                        subprocess.CompletedProcess(a, 0, json.dumps(data), ""))
    assert vam.probe_media("/media/a.mkv").audio_stream in (None, 0)


@pytest.mark.parametrize("duration", ["nan", "inf", "-inf"])
def test_nonfinite_duration_is_unknown_but_keeps_the_audio_stream(monkeypatch, duration):
    data = {"format": {"duration": duration}, "streams": [{"codec_type": "audio"}]}
    monkeypatch.setattr(vam.subprocess, "run", lambda *a, **kw:
                        subprocess.CompletedProcess(a, 0, json.dumps(data), ""))
    assert vam.probe_media("/media/a.mkv") == vam.MediaProbe(None, 0)


def test_failed_probe_does_not_trust_partial_metadata(monkeypatch):
    data = {"format": {"duration": "600"}, "streams": [{"codec_type": "audio"}]}
    monkeypatch.setattr(vam.subprocess, "run", lambda *a, **kw:
                        subprocess.CompletedProcess(a, 1, json.dumps(data), "read error"))
    assert vam.probe_media("/media/a.mkv") == vam.MediaProbe(None, None)


def test_internal_detector_typeerror_is_not_treated_as_an_old_api(fake_wav):
    class BrokenModel:
        def detect_language(self, **kwargs):
            raise TypeError("bad audio buffer")

        def transcribe(self, *args, **kwargs):
            pytest.fail("a broken detector must not silently become another result")

    with pytest.raises(TypeError, match="bad audio buffer"):
        vam.detect_language(BrokenModel(), fake_wav("/media/x.mkv"))


@pytest.mark.parametrize("failure", [False, KeyboardInterrupt])
def test_failed_extraction_removes_partial_sample_immediately(tmp_path, monkeypatch, failure):
    path = media(tmp_path, "broken.mkv")
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    monkeypatch.setattr(vam, "probe_media", lambda _path: vam.MediaProbe(60, 0))

    def extract(_path, sample, *_args):
        Path(sample).write_bytes(b"partial wav")
        if failure:
            raise failure
        return False

    monkeypatch.setattr(vam, "extract_sample", extract)
    if failure:
        with pytest.raises(KeyboardInterrupt):
            vam.verify_one(phase1_row(path), None, vam.Config(min_free_space_mb=0), str(scratch), 1)
    else:
        row = vam.verify_one(phase1_row(path), None, vam.Config(min_free_space_mb=0), str(scratch), 1)
        assert row["Verdict"] == audit_common.VERDICT_EXTRACTION_FAILED
    assert list(scratch.iterdir()) == []


@pytest.mark.parametrize("contents", [
    "",
    "wrong,header\nA,B\n",
    "App,Title,Year,Episode,AudioLanguages,Path\nRadarr,T\n",
    "App,Title,Year,Episode,AudioLanguages,Path\nRadarr,T,2000,,eng,/m/a,extra\n",
    'App,Title,Year,Episode,AudioLanguages,Path\nRadarr,"unfinished',
    "App,Title,Year,Episode,AudioLanguages,Path,Path\nRadarr,T,2000,,eng,a,b\n",
])
def test_invalid_phase1_csv_is_rejected_without_touching_previous_output(tmp_path, contents):
    inp = tmp_path / "in.csv"
    inp.write_text(contents, encoding="utf-8")
    out = write_phase2(tmp_path, [{"Path": "/old.mkv", "Verdict": "CONFIRMED_NOT_ITALIAN"}])
    before = Path(out).read_bytes()
    assert vam.main(["--input", str(inp), "--output", out]) == 1
    assert Path(out).read_bytes() == before


@pytest.mark.parametrize("verdict", ["", "TYPO_VERDICT"])
def test_invalid_resume_verdict_is_rejected_without_overwriting_the_report(tmp_path, verdict):
    inp = write_phase1(tmp_path, [phase1_row("/old.mkv")])
    out = write_phase2(tmp_path, [{"Path": "/old.mkv", "Verdict": verdict}])
    before = Path(out).read_bytes()
    assert vam.main(["--input", inp, "--output", out]) == 1
    assert Path(out).read_bytes() == before


def test_input_and_output_cannot_alias_even_through_a_symlink(tmp_path):
    inp = write_phase1(tmp_path, [phase1_row("/missing.mkv")])
    out = tmp_path / "out.csv"
    out.symlink_to(inp)
    before = Path(inp).read_bytes()
    assert vam.main(["--input", inp, "--output", str(out), "--no-resume"]) == 1
    assert Path(inp).read_bytes() == before


@pytest.mark.parametrize("alias", ["same", "symlink", "hardlink"])
@pytest.mark.parametrize("name", ["movie.mkv", "movie.mkv ", " movie.mkv", " movie.mkv "])
def test_output_cannot_overwrite_a_suspect_media_file(tmp_path, alias, name):
    path = media(tmp_path, name)
    inp = write_phase1(tmp_path, [phase1_row(path)])
    out = tmp_path / "output.csv"
    if alias == "same":
        out = Path(path)
    elif alias == "symlink":
        out.symlink_to(path)
    else:
        os.link(path, out)
    before = Path(path).read_bytes()
    assert vam.main(["--input", inp, "--output", str(out), "--no-resume"]) == 1
    assert Path(path).read_bytes() == before


@pytest.mark.parametrize("spaced", ["movie.mkv ", " movie.mkv", " movie.mkv "])
def test_worker_preserves_distinct_whitespace_paths_through_detection_and_resume(
    tmp_path, shim_path, whisper_script, monkeypatch, spaced
):
    monkeypatch.chdir(tmp_path)
    media(tmp_path, "movie.mkv", b"English")
    media(tmp_path, spaced, b"Italian")

    whisper_script({"movie.mkv": ["en", 0.99], spaced: ["it", 0.99]})
    inp = write_phase1(tmp_path, [phase1_row("movie.mkv"), phase1_row(spaced)])
    out = str(tmp_path / "out.csv")

    assert vam.main(["--input", inp, "--output", out]) == 0
    assert [(row["Path"], row["Verdict"]) for row in read_rows(out)[1]] == [
        ("movie.mkv", "CONFIRMED_NOT_ITALIAN"), (spaced, "MISTAGGED_IS_ITALIAN"),
    ]

    def unexpected_detection(_cfg):
        pytest.fail("both exact paths were verified and must resume without another model")

    monkeypatch.setattr(vam, "load_model", unexpected_detection)
    assert vam.main(["--input", inp, "--output", out]) == 0
    assert [(row["Path"], row["Verdict"]) for row in read_rows(out)[1]] == [
        ("movie.mkv", "CONFIRMED_NOT_ITALIAN"), (spaced, "MISTAGGED_IS_ITALIAN"),
    ]


def test_resume_detects_same_size_changes_within_one_second(tmp_path, shim_path, whisper_script):
    path = media(tmp_path, "movie.mkv", b"first")
    os.utime(path, ns=(1_700_000_000_100_000_000, 1_700_000_000_100_000_000))
    inp = write_phase1(tmp_path, [phase1_row(path)])
    out = str(tmp_path / "out.csv")
    whisper_script({path: ["en", 0.99]})
    assert vam.main(["--input", inp, "--output", out]) == 0
    Path(path).write_bytes(b"other")
    os.utime(path, ns=(1_700_000_000_200_000_000, 1_700_000_000_200_000_000))
    whisper_script({path: ["it", 0.99]})
    assert vam.main(["--input", inp, "--output", out]) == 0
    assert read_rows(out)[1][0]["Verdict"] == "MISTAGGED_IS_ITALIAN"


def test_legacy_verdict_does_not_acquire_an_unverified_signature():
    row = phase1_row("/movie.mkv")
    previous = {("/movie.mkv", ""): vam.make_row(row, verdict="CONFIRMED_NOT_ITALIAN")}
    plan = vam.plan_rows([row], previous, retry_errors=False, limit=0,
                         signature=lambda _path: (20, "1700000000.100000000"))
    assert plan.kept[0]["FileSize"] == ""
    assert plan.kept[0]["FileMtime"] == ""


def test_limit_keeps_old_verdict_for_a_relabelled_file_that_needs_retry():
    old = phase1_row("/movie.mkv", episode="S01E01 - Old")
    previous = {vam.row_key(old): vam.make_row(old, verdict="EXTRACTION_FAILED", size=10, mtime=20)}
    rows = [phase1_row("/first.mkv"), phase1_row("/movie.mkv", episode="S01E01 - New")]
    plan = vam.plan_rows(rows, previous, retry_errors=True, limit=1,
                         signature=lambda _path: (10, 20))
    assert [(row["Path"], row["Verdict"]) for row in plan.deferred] == [
        ("/movie.mkv", "EXTRACTION_FAILED"),
    ]


@pytest.mark.parametrize("error", [RuntimeError("model corrupt"), ValueError("unknown model")])
def test_model_initialization_error_returns_one_and_preserves_report(tmp_path, monkeypatch, error):
    inp = write_phase1(tmp_path, [phase1_row(media(tmp_path, "new.mkv"))])
    out = write_phase2(tmp_path, [{"Path": "/old.mkv", "Verdict": "CONFIRMED_NOT_ITALIAN"}])
    before = Path(out).read_bytes()

    def load(_cfg):
        raise error

    monkeypatch.setattr(vam, "load_model", load)
    assert vam.main(["--input", inp, "--output", out]) == 1
    assert Path(out).read_bytes() == before


def test_interrupted_retry_keeps_previous_unprocessed_verdicts(tmp_path, monkeypatch):
    paths = [media(tmp_path, name) for name in ("a.mkv", "b.mkv")]
    inp = write_phase1(tmp_path, [phase1_row(path) for path in paths])
    out = write_phase2(tmp_path, [{"Path": path, "Verdict": "EXTRACTION_FAILED"} for path in paths])
    monkeypatch.setattr(vam, "load_model", lambda _cfg: object())

    def verify(row, *_args):
        if row["Path"] == paths[1]:
            raise KeyboardInterrupt
        return vam.make_row(row, verdict="MISTAGGED_IS_ITALIAN", detected="it", confidence="0.99")

    monkeypatch.setattr(vam, "verify_one", verify)
    assert vam.main(["--input", inp, "--output", out, "--retry-errors"]) == 130
    _header, rows = read_rows(out)
    assert {row["Path"]: row["Verdict"] for row in rows} == {
        paths[0]: "MISTAGGED_IS_ITALIAN", paths[1]: "EXTRACTION_FAILED",
    }


def test_failed_initial_csv_write_preserves_previous_output(tmp_path, monkeypatch):
    inp = write_phase1(tmp_path, [])
    out = write_phase2(tmp_path, [{"Path": "/old.mkv", "Verdict": "CONFIRMED_NOT_ITALIAN"}])
    before = Path(out).read_bytes()

    class FailedWriter(vam.csv.DictWriter):
        def writeheader(self):
            super().writeheader()
            raise OSError("No space left on device")

    monkeypatch.setattr(vam.csv, "DictWriter", FailedWriter)
    assert vam.main(["--input", inp, "--output", out]) == 1
    assert Path(out).read_bytes() == before


def test_direct_worker_does_not_export_arr_credentials_to_media_tools(tmp_path, monkeypatch):
    monkeypatch.setenv("RADARR_API_KEY", "test-radarr-key")
    monkeypatch.setenv("SONARR_API_KEY", "test-sonarr-key")
    environments = []

    def run(argv, **kwargs):
        environments.append(kwargs.get("env", os.environ))
        if argv[0] == "ffmpeg":
            Path(argv[-1]).write_bytes(b"sample")
        return subprocess.CompletedProcess(argv, 0, '{"streams": []}', "")

    monkeypatch.setattr(vam.subprocess, "run", run)
    probe = vam.probe_media("/media/movie.mkv")
    assert vam.extract_sample("/media/movie.mkv", str(tmp_path / "sample.wav"), vam.Config(), probe)
    assert len(environments) == 2
    assert all("RADARR_API_KEY" not in env and "SONARR_API_KEY" not in env for env in environments)
    assert all(env["PATH"] == os.environ["PATH"] for env in environments)

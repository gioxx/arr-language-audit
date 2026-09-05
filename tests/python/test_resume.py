"""Resume planning for verify/verify_audio_language.py.

Two halves:

  * direct unit tests of `plan_rows`, which is pure -- it is handed the input
    rows, the previous rows and a `signature` callable, and reaches the disk
    through none of them. They pass no path that exists, read and write no
    CSV and build no model; the injected `Signatures` fake answers from a
    dict and records every call.
  * end-to-end runs through `main()` that pin the resume behaviour the user
    actually sees, using the fake `faster_whisper` package and the ffmpeg
    shims (see conftest.py).

The module-level fixtures isolate the environment (a clean env, a private
stand-in for the system temp dir) for that second half; the unit tests are
unaffected by them.
"""

from __future__ import annotations

import os
from decimal import Decimal

import audit_common
import faster_whisper
import pytest
import verify_audio_language as vam
from conftest import (  # shared test helpers, not a private API
    media,
    phase1_row,
    read_rows,
    signature_of,
    write_phase1,
    write_phase2,
)

pytestmark = pytest.mark.usefixtures("clean_env", "sys_temp")

LEGACY_COLUMNS = [
    "App", "Title", "Year", "Episode", "DeclaredAudioLanguages",
    "DetectedLanguage", "Confidence", "Verdict", "Path",
]


# --- helpers ----------------------------------------------------------------


def prev_row(path, verdict=audit_common.VERDICT_CONFIRMED, *, episode="",
             size="", mtime="", detected="en", confidence="0.90", title="T"):
    """One row as a previous run's output CSV would hold it."""
    return {
        "App": "Radarr", "Title": title, "Year": "2001", "Episode": episode,
        "DeclaredAudioLanguages": "eng", "DetectedLanguage": detected,
        "Confidence": confidence, "Verdict": verdict, "Path": path,
        "FileSize": size, "FileMtime": mtime,
    }


def stamped(path, verdict=audit_common.VERDICT_CONFIRMED, **kwargs):
    """A previous row carrying `path`'s current, matching signature."""
    size, mtime = signature_of(path)
    return prev_row(path, verdict, size=size, mtime=mtime, **kwargs)


def reset_model_recording():
    faster_whisper.WhisperModel.instances = []
    faster_whisper.WhisperModel.calls = []


def bump_mtime(path, delta=120):
    """Change mtime while leaving the size alone."""
    st = os.stat(path)
    os.utime(path, (st.st_atime + delta, st.st_mtime + delta))


def key(path, episode=""):
    return (path, episode)


def assert_precise_signature(row, path):
    stat = os.stat(path)
    assert row["FileSize"] == str(stat.st_size)
    assert Decimal(row["FileMtime"]) * 1_000_000_000 == stat.st_mtime_ns


class Signatures:
    """An injectable `signature`: a dict of path -> (size, mtime), counted."""

    def __init__(self, table):
        self.table = table
        self.calls = []

    def __call__(self, path):
        self.calls.append(path)
        return self.table.get(path, (None, None))


# --- Y1: resume_decision ----------------------------------------------------


@pytest.mark.parametrize(
    ("entry", "cur", "retry", "expected"),
    [
        # 1. never seen before
        (None, (10, 20), False, "verify"),
        # 2. unchanged signature: reuse
        (prev_row("/m/a.mkv", size="10", mtime="20"), (10, 20), False, "keep"),
        # 3. size changed: the file was replaced
        (prev_row("/m/a.mkv", size="10", mtime="20"), (11, 20), False, "verify"),
        # 4. mtime changed alone: re-encoded in place
        (prev_row("/m/a.mkv", size="10", mtime="20"), (10, 21), False, "verify"),
        # 5. stored signature, file not visible now: do not churn
        (prev_row("/m/a.mkv", size="10", mtime="20"), (None, None), False, "keep"),
        # 6. legacy row (no signature), ordinary verdict: keep
        (prev_row("/m/a.mkv"), (10, 20), False, "keep"),
        # 7. R3: unstamped error row whose file is visible again: retry it
        (prev_row("/m/a.mkv", audit_common.VERDICT_FILE_NOT_FOUND), (10, 20), False, "verify"),
        # 8. R3 does not fire while the file is still missing
        (prev_row("/m/a.mkv", audit_common.VERDICT_FILE_NOT_FOUND), (None, None), False, "keep"),
        # 9. --retry-errors reprocesses a stamped error row
        (prev_row("/m/a.mkv", audit_common.VERDICT_EXTRACTION_FAILED, size="10", mtime="20"),
         (10, 20), True, "verify"),
        # 10. --retry-errors also covers LOW_CONFIDENCE ...
        (prev_row("/m/a.mkv", audit_common.VERDICT_LOW_CONFIDENCE, size="10", mtime="20"),
         (10, 20), True, "verify"),
        # 11. ... but never a settled verdict
        (prev_row("/m/a.mkv", audit_common.VERDICT_MISTAGGED, size="10", mtime="20"),
         (10, 20), True, "keep"),
    ],
)
def test_resume_decision(entry, cur, retry, expected):
    """Y1: every branch of the reuse decision, including R3."""
    assert vam.resume_decision(entry, cur[0], cur[1], retry) == expected


# --- plan_rows: pure unit tests --------------------------------------------


def test_plan_rows_without_previous_verifies_everything():
    """No previous output: every input row needs detection, nothing is kept."""
    rows = [phase1_row("/m/a.mkv"), phase1_row("/m/b.mkv")]
    sig = Signatures({"/m/a.mkv": (1, 2), "/m/b.mkv": (3, 4)})

    plan = vam.plan_rows(rows, {}, retry_errors=False, limit=0, signature=sig)

    assert plan.to_verify == rows
    assert plan.kept == []
    assert plan.deferred == []
    assert plan.orphans == []
    assert plan.dropped_stale == 0


def test_plan_rows_keeps_unchanged_and_verifies_changed():
    """The split the whole feature exists for, plus the signature cache: one
    stat per distinct path, however many rows -- input rows and orphan rows
    alike -- are decided from it."""
    rows = [phase1_row("/m/a.mkv", episode="S01E01"),
            phase1_row("/m/a.mkv", episode="S01E02"),
            phase1_row("/m/b.mkv")]
    previous = {
        key("/m/a.mkv", "S01E01"): prev_row("/m/a.mkv", episode="S01E01",
                                            size="1", mtime="2"),
        key("/m/a.mkv", "S01E02"): prev_row("/m/a.mkv", episode="S01E02",
                                            size="1", mtime="2"),
        key("/m/b.mkv"): prev_row("/m/b.mkv", size="3", mtime="4"),
        key("/m/c.mkv"): prev_row("/m/c.mkv", size="5", mtime="6"),
    }
    sig = Signatures({"/m/a.mkv": (1, 2), "/m/b.mkv": (99, 4), "/m/c.mkv": (5, 6)})

    plan = vam.plan_rows(rows, previous, retry_errors=False, limit=0, signature=sig)

    assert [r["Episode"] for r in plan.kept] == ["S01E01", "S01E02"]
    assert [r["Path"] for r in plan.to_verify] == ["/m/b.mkv"]
    assert [r["Path"] for r in plan.orphans] == ["/m/c.mkv"]
    # Four rows on /m/a.mkv, /m/b.mkv and /m/c.mkv -> three stats, not five.
    assert sorted(sig.calls) == ["/m/a.mkv", "/m/b.mkv", "/m/c.mkv"]
    assert len(sig.calls) == 3


def test_plan_rows_keys_on_path_and_episode():
    """R2: one file, two episodes -- each row carries its own verdict."""
    rows = [phase1_row("/m/dual.mkv", episode="S01E01"),
            phase1_row("/m/dual.mkv", episode="S01E02")]
    previous = {
        key("/m/dual.mkv", "S01E01"): prev_row(
            "/m/dual.mkv", episode="S01E01", size="1", mtime="2"),
    }
    sig = Signatures({"/m/dual.mkv": (1, 2)})

    plan = vam.plan_rows(rows, previous, retry_errors=False, limit=0, signature=sig)

    assert [r["Episode"] for r in plan.kept] == ["S01E01"]
    assert [r["Episode"] for r in plan.to_verify] == ["S01E02"]
    assert plan.orphans == []


def test_plan_rows_limit_defers_previous_rows_of_the_remainder():
    """R4: a row cut by --limit keeps its old verdict; a row cut by --limit
    that never had one is simply left for the next run."""
    rows = [phase1_row("/m/a.mkv"), phase1_row("/m/b.mkv"), phase1_row("/m/c.mkv")]
    previous = {
        key("/m/b.mkv"): prev_row("/m/b.mkv", size="1", mtime="2", title="B"),
    }
    sig = Signatures({"/m/a.mkv": (9, 9), "/m/b.mkv": (7, 7), "/m/c.mkv": (5, 5)})

    plan = vam.plan_rows(rows, previous, retry_errors=False, limit=1, signature=sig)

    assert [r["Path"] for r in plan.to_verify] == ["/m/a.mkv"]
    assert [r["Path"] for r in plan.deferred] == ["/m/b.mkv"]
    assert plan.deferred[0]["Verdict"] == audit_common.VERDICT_CONFIRMED
    assert plan.kept == []


def test_plan_rows_limit_does_not_touch_the_orphan_rules():
    """--limit caps the work, and nothing else: which previous rows are
    carried over and which are dropped is decided from `previous` and the
    input alone, so a limited run reports the same orphans as a full one."""
    rows = [phase1_row("/m/a.mkv"), phase1_row("/m/b.mkv")]
    previous = {
        key("/m/b.mkv"): prev_row("/m/b.mkv", size="1", mtime="2"),
        key("/m/orphan-same.mkv"): prev_row("/m/orphan-same.mkv", size="3", mtime="4"),
        key("/m/orphan-changed.mkv"): prev_row(
            "/m/orphan-changed.mkv", size="5", mtime="6"),
    }
    table = {"/m/a.mkv": (9, 9), "/m/b.mkv": (7, 7),
             "/m/orphan-same.mkv": (3, 4), "/m/orphan-changed.mkv": (99, 6)}

    full = vam.plan_rows(rows, previous, retry_errors=False, limit=0,
                         signature=Signatures(table))
    limited = vam.plan_rows(rows, previous, retry_errors=False, limit=1,
                            signature=Signatures(table))

    assert [r["Path"] for r in limited.orphans] == ["/m/orphan-same.mkv"]
    assert limited.orphans == full.orphans
    assert limited.dropped_stale == full.dropped_stale == 1
    assert limited.dropped_superseded == full.dropped_superseded == 0
    # ... and only to_verify/deferred differ between the two.
    assert [r["Path"] for r in full.to_verify] == ["/m/a.mkv", "/m/b.mkv"]
    assert [r["Path"] for r in limited.to_verify] == ["/m/a.mkv"]
    assert [r["Path"] for r in limited.deferred] == ["/m/b.mkv"]


def test_plan_rows_carries_a_verdict_across_an_episode_relabel():
    """Phase 1 renaming an episode changes the row's key but not one byte of
    the media: the verdict moves to the new label instead of being re-earned,
    and the row under the old label does not survive beside it."""
    rows = [phase1_row("/m/x.mkv", episode="S01E01 - The Pilot")]
    previous = {
        key("/m/x.mkv", "S01E01 - Pilot"): prev_row(
            "/m/x.mkv", audit_common.VERDICT_CONFIRMED, episode="S01E01 - Pilot",
            size="1", mtime="2", detected="en", confidence="0.88"),
    }
    sig = Signatures({"/m/x.mkv": (1, 2)})

    plan = vam.plan_rows(rows, previous, retry_errors=False, limit=0, signature=sig)

    assert plan.to_verify == []
    assert plan.orphans == []
    assert plan.dropped_superseded == 0
    assert len(plan.kept) == 1
    carried = plan.kept[0]
    assert carried["Episode"] == "S01E01 - The Pilot"
    assert carried["Verdict"] == audit_common.VERDICT_CONFIRMED
    assert carried["DetectedLanguage"] == "en"
    assert carried["Confidence"] == "0.88"
    assert (carried["FileSize"], carried["FileMtime"]) == ("1", "2")


@pytest.mark.parametrize(
    ("previous_row", "table"),
    [
        # the file changed as well as the label: the old verdict is worthless
        (prev_row("/m/x.mkv", episode="old", size="1", mtime="2"), {"/m/x.mkv": (99, 2)}),
        # an error verdict is never carried onto a new label
        (prev_row("/m/x.mkv", audit_common.VERDICT_DETECTION_FAILED, episode="old",
                  size="1", mtime="2"), {"/m/x.mkv": (1, 2)}),
        # a legacy row has no signature to prove it is the same file
        (prev_row("/m/x.mkv", episode="old"), {"/m/x.mkv": (1, 2)}),
    ],
)
def test_plan_rows_drops_a_superseded_row_it_cannot_carry_over(previous_row, table):
    """The old label still goes: keeping it would show the file twice for
    ever, since a metadata edit never changes the signature."""
    rows = [phase1_row("/m/x.mkv", episode="new")]
    previous = {key("/m/x.mkv", "old"): previous_row}

    plan = vam.plan_rows(rows, previous, retry_errors=False, limit=0,
                         signature=Signatures(table))

    assert [r["Episode"] for r in plan.to_verify] == ["new"]
    assert plan.kept == []
    assert plan.orphans == []
    assert plan.dropped_superseded == 1
    assert plan.dropped_stale == 0


@pytest.mark.parametrize(
    ("retry_errors", "carried"),
    [(False, True), (True, False)],
)
def test_plan_rows_relabelled_low_confidence_follows_the_retry_errors_rule(
    retry_errors, carried
):
    """A LOW_CONFIDENCE row was really listened to, so a relabel treats it
    exactly as its own key would: carried over while --retry-errors is off,
    re-verified under the new label when it is on. Only error verdicts are
    excluded from carry-over outright, because they were never earned."""
    rows = [phase1_row("/m/x.mkv", episode="new")]
    previous = {
        key("/m/x.mkv", "old"): prev_row(
            "/m/x.mkv", audit_common.VERDICT_LOW_CONFIDENCE, episode="old",
            size="1", mtime="2", detected="en", confidence="0.41"),
    }
    sig = Signatures({"/m/x.mkv": (1, 2)})

    plan = vam.plan_rows(rows, previous, retry_errors=retry_errors, limit=0,
                         signature=sig)

    assert plan.orphans == []
    if carried:
        assert plan.to_verify == []
        assert [r["Episode"] for r in plan.kept] == ["new"]
        assert plan.kept[0]["Verdict"] == audit_common.VERDICT_LOW_CONFIDENCE
        assert plan.kept[0]["Confidence"] == "0.41"
        assert plan.dropped_superseded == 0
    else:
        assert plan.kept == []
        assert [r["Episode"] for r in plan.to_verify] == ["new"]
        # The old label goes either way -- one file, one row.
        assert plan.dropped_superseded == 1


def test_plan_rows_carries_over_exactly_one_of_several_old_labels():
    """Two old labels for one file and a single new one: the verdict is
    carried once and the surplus row is dropped, never written twice."""
    rows = [phase1_row("/m/x.mkv", episode="new")]
    previous = {
        key("/m/x.mkv", "old-a"): prev_row(
            "/m/x.mkv", audit_common.VERDICT_CONFIRMED, episode="old-a",
            size="1", mtime="2", detected="en", confidence="0.90"),
        key("/m/x.mkv", "old-b"): prev_row(
            "/m/x.mkv", audit_common.VERDICT_MISTAGGED, episode="old-b",
            size="1", mtime="2", detected="it", confidence="0.95"),
    }
    sig = Signatures({"/m/x.mkv": (1, 2)})

    plan = vam.plan_rows(rows, previous, retry_errors=False, limit=0, signature=sig)

    assert len(plan.kept) == 1
    assert plan.kept[0]["Episode"] == "new"
    # The first candidate in the previous CSV's own order wins, deterministically.
    assert plan.kept[0]["Verdict"] == audit_common.VERDICT_CONFIRMED
    assert plan.dropped_superseded == 1
    assert plan.to_verify == []
    assert plan.deferred == []
    assert plan.orphans == []
    # One file, one row -- whatever else the plan holds.
    written = plan.kept + plan.deferred + plan.orphans
    assert [r["Path"] for r in written] == ["/m/x.mkv"]


def test_plan_rows_relabel_never_steals_a_row_another_input_row_owns():
    """R2 must survive the relabel rule: with two episodes in one file, the
    second episode's own previous row is not a candidate for the first."""
    rows = [phase1_row("/m/dual.mkv", episode="S01E01"),
            phase1_row("/m/dual.mkv", episode="S01E03")]
    previous = {
        key("/m/dual.mkv", "S01E01"): prev_row(
            "/m/dual.mkv", episode="S01E01", size="1", mtime="2"),
        key("/m/dual.mkv", "S01E02"): prev_row(
            "/m/dual.mkv", episode="S01E02", size="1", mtime="2"),
    }
    sig = Signatures({"/m/dual.mkv": (1, 2)})

    plan = vam.plan_rows(rows, previous, retry_errors=False, limit=0, signature=sig)

    # S01E01 keeps its own row; S01E03 inherits S01E02's, the only one going
    # spare -- and neither is verified again.
    assert [r["Episode"] for r in plan.kept] == ["S01E01", "S01E03"]
    assert plan.to_verify == []
    assert plan.orphans == []
    assert plan.dropped_superseded == 0


def test_plan_rows_drops_only_orphans_that_provably_changed():
    """A verdict for a file phase 1 no longer flags is dropped only when the
    file itself changed; a narrower scan scope must not cost hours of work."""
    previous = {
        key("/m/changed.mkv"): prev_row("/m/changed.mkv", size="1", mtime="2"),
        key("/m/same.mkv"): prev_row("/m/same.mkv", size="3", mtime="4"),
        key("/m/gone.mkv"): prev_row("/m/gone.mkv", size="5", mtime="6"),
        key("/m/legacy.mkv"): prev_row("/m/legacy.mkv"),
    }
    sig = Signatures({
        "/m/changed.mkv": (99, 2), "/m/same.mkv": (3, 4), "/m/legacy.mkv": (7, 8),
    })

    plan = vam.plan_rows([], previous, retry_errors=False, limit=0, signature=sig)

    assert [r["Path"] for r in plan.orphans] == [
        "/m/same.mkv", "/m/gone.mkv", "/m/legacy.mkv"]
    assert plan.dropped_stale == 1


def test_plan_rows_never_stamps_a_signature_on_a_kept_error_row():
    """R3's other half: an error row that is kept (its file is still not
    visible) must stay unstamped, or it can never be retried automatically."""
    rows = [phase1_row("/m/gone.mkv"), phase1_row("/m/legacy.mkv")]
    previous = {
        key("/m/gone.mkv"): prev_row("/m/gone.mkv", audit_common.VERDICT_FILE_NOT_FOUND),
        key("/m/legacy.mkv"): prev_row("/m/legacy.mkv"),
    }
    sig = Signatures({"/m/legacy.mkv": (7, 8)})

    plan = vam.plan_rows(rows, previous, retry_errors=False, limit=0, signature=sig)

    by_path = {r["Path"]: r for r in plan.kept}
    assert (by_path["/m/gone.mkv"]["FileSize"], by_path["/m/gone.mkv"]["FileMtime"]) == ("", "")
    assert (by_path["/m/legacy.mkv"]["FileSize"],
            by_path["/m/legacy.mkv"]["FileMtime"]) == ("", "")


def test_plan_rows_retry_errors_reprocesses_retryable_verdicts_only():
    rows = [phase1_row("/m/ok.mkv"), phase1_row("/m/err.mkv"), phase1_row("/m/low.mkv")]
    previous = {
        key("/m/ok.mkv"): prev_row("/m/ok.mkv", size="1", mtime="1"),
        key("/m/err.mkv"): prev_row(
            "/m/err.mkv", audit_common.VERDICT_DETECTION_FAILED, size="1", mtime="1"),
        key("/m/low.mkv"): prev_row(
            "/m/low.mkv", audit_common.VERDICT_LOW_CONFIDENCE, size="1", mtime="1"),
    }
    sig = Signatures({p: (1, 1) for p in ("/m/ok.mkv", "/m/err.mkv", "/m/low.mkv")})

    plan = vam.plan_rows(rows, previous, retry_errors=True, limit=0, signature=sig)

    assert [r["Path"] for r in plan.kept] == ["/m/ok.mkv"]
    assert [r["Path"] for r in plan.to_verify] == ["/m/err.mkv", "/m/low.mkv"]


def test_plan_rows_row_without_a_path_is_left_for_the_worker():
    """An empty Path is not a resume question: the loop records it as
    FILE_NOT_FOUND, and it never becomes an orphan key."""
    rows = [phase1_row("")]
    sig = Signatures({})

    plan = vam.plan_rows(rows, {}, retry_errors=False, limit=0, signature=sig)

    assert plan.to_verify == rows
    assert sig.calls == []


def test_row_key_preserves_path_and_normalises_only_episode():
    assert vam.row_key({"Path": " /m/a.mkv ", "Episode": " S01E01 "}) == (" /m/a.mkv ", "S01E01")
    assert vam.row_key({"Path": "/m/a.mkv"}) == ("/m/a.mkv", "")
    assert vam.row_key({"Path": None, "Episode": None}) == ("", "")


# --- Y14/Y15: change detection end to end -----------------------------------


def test_resume_reverifies_only_the_changed_file(tmp_path, shim_path, whisper_script,
                                                 capsys):
    """Y14: three files verified, one grows a byte, only that one is redone."""
    a = media(tmp_path, "a.mkv")
    b = media(tmp_path, "b.mkv")
    c = media(tmp_path, "c.mkv")
    whisper_script({"*": ["en", 0.9]})
    inp = write_phase1(tmp_path, [phase1_row(a), phase1_row(b), phase1_row(c)])
    out = str(tmp_path / "out.csv")

    assert vam.main(["--input", inp, "--output", out]) == 0
    assert faster_whisper.WhisperModel.calls == [a, b, c]

    with open(b, "ab") as handle:
        handle.write(b"!")
    reset_model_recording()
    capsys.readouterr()

    assert vam.main(["--input", inp, "--output", out]) == 0
    assert faster_whisper.WhisperModel.calls == [b]
    assert "Reusing 2 previous verdict(s)" in capsys.readouterr().err

    _header, rows = read_rows(out)
    assert [r["Path"] for r in rows] == [a, c, b]
    assert_precise_signature(rows[2], b)


def test_resume_reverifies_on_an_mtime_only_change(tmp_path, shim_path, whisper_script):
    """Y15: same size, new mtime -- a remux in place is still a new file."""
    a = media(tmp_path, "a.mkv")
    whisper_script({"*": ["en", 0.9]})
    inp = write_phase1(tmp_path, [phase1_row(a)])
    out = str(tmp_path / "out.csv")

    assert vam.main(["--input", inp, "--output", out]) == 0
    bump_mtime(a)
    reset_model_recording()

    assert vam.main(["--input", inp, "--output", out]) == 0
    assert faster_whisper.WhisperModel.calls == [a]


def test_legacy_rows_keep_their_missing_signatures_until_verification(
    tmp_path, shim_path, whisper_script
):
    """A pre-signature CSV must not invent evidence from a later stat call."""
    a = media(tmp_path, "a.mkv")
    gone = str(tmp_path / "gone.mkv")
    whisper_script({"*": ["en", 0.9]})
    out = write_phase2(tmp_path, [
        {"App": "Radarr", "Title": "A", "Year": "2001", "Episode": "",
         "DeclaredAudioLanguages": "eng", "DetectedLanguage": "en",
         "Confidence": "0.90", "Verdict": audit_common.VERDICT_CONFIRMED, "Path": a},
        {"App": "Radarr", "Title": "G", "Year": "2001", "Episode": "",
         "DeclaredAudioLanguages": "eng", "DetectedLanguage": "",
         "Confidence": "", "Verdict": audit_common.VERDICT_FILE_NOT_FOUND, "Path": gone},
    ], name="out.csv", columns=LEGACY_COLUMNS)
    inp = write_phase1(tmp_path, [phase1_row(a), phase1_row(gone)])

    assert vam.main(["--input", inp, "--output", out]) == 0

    header, rows = read_rows(out)
    assert header == audit_common.PHASE2_COLUMNS
    assert [r["Path"] for r in rows] == [a, gone]
    assert (rows[0]["FileSize"], rows[0]["FileMtime"]) == ("", "")
    assert (rows[1]["FileSize"], rows[1]["FileMtime"]) == ("", "")
    assert rows[1]["Verdict"] == audit_common.VERDICT_FILE_NOT_FOUND
    # Nothing needed detection, so no model was ever built.
    assert faster_whisper.WhisperModel.instances == []


# --- Y17: --retry-errors ----------------------------------------------------


def test_retry_errors_reprocesses_error_and_low_confidence_rows(
    tmp_path, shim_path, whisper_script, capsys
):
    """Y17: settled verdicts are left alone; retryable ones are redone."""
    ok = media(tmp_path, "ok.mkv")
    err = media(tmp_path, "err.mkv")
    low = media(tmp_path, "low.mkv")
    whisper_script({"*": ["it", 0.95]})
    out = write_phase2(tmp_path, [
        stamped(ok, audit_common.VERDICT_CONFIRMED, title="OK"),
        stamped(err, audit_common.VERDICT_EXTRACTION_FAILED, title="ERR"),
        stamped(low, audit_common.VERDICT_LOW_CONFIDENCE, title="LOW"),
    ], name="out.csv")
    inp = write_phase1(tmp_path, [phase1_row(ok), phase1_row(err), phase1_row(low)])

    assert vam.main(["--input", inp, "--output", out, "--retry-errors"]) == 0

    assert faster_whisper.WhisperModel.calls == [err, low]
    assert "Reusing 1 previous verdict(s)" in capsys.readouterr().err

    _header, rows = read_rows(out)
    assert [r["Path"] for r in rows] == [ok, err, low]
    assert rows[0]["Verdict"] == audit_common.VERDICT_CONFIRMED
    assert [r["Verdict"] for r in rows[1:]] == [audit_common.VERDICT_MISTAGGED] * 2


def test_without_retry_errors_a_stamped_error_row_is_kept(tmp_path, shim_path,
                                                          whisper_script):
    """Y17's twin: the flag is what re-runs them, not the verdict alone."""
    err = media(tmp_path, "err.mkv")
    whisper_script({"*": ["it", 0.95]})
    out = write_phase2(tmp_path, [
        stamped(err, audit_common.VERDICT_EXTRACTION_FAILED),
    ], name="out.csv")
    inp = write_phase1(tmp_path, [phase1_row(err)])

    assert vam.main(["--input", inp, "--output", out]) == 0
    assert faster_whisper.WhisperModel.calls == []
    _header, rows = read_rows(out)
    assert rows[0]["Verdict"] == audit_common.VERDICT_EXTRACTION_FAILED


# --- Y18: orphaned previous rows -------------------------------------------


def test_orphan_rows_kept_unless_the_file_provably_changed(tmp_path, shim_path,
                                                           whisper_script, capsys):
    """Y18: four verdicts for files phase 1 no longer lists."""
    changed = media(tmp_path, "changed.mkv")
    same = media(tmp_path, "same.mkv")
    legacy = media(tmp_path, "legacy.mkv")
    gone = str(tmp_path / "gone.mkv")
    fresh = media(tmp_path, "fresh.mkv")
    whisper_script({"*": ["en", 0.9]})

    out = write_phase2(tmp_path, [
        prev_row(changed, size="1", mtime="1", title="CHANGED"),
        stamped(same, title="SAME"),
        prev_row(gone, size="1", mtime="1", title="GONE"),
        prev_row(legacy, title="LEGACY"),
    ], name="out.csv")
    inp = write_phase1(tmp_path, [phase1_row(fresh, title="FRESH")])

    assert vam.main(["--input", inp, "--output", out]) == 0

    err = capsys.readouterr().err
    assert "Carrying over 3 row(s)" in err
    assert "Dropped 1 stale row(s)" in err

    _header, rows = read_rows(out)
    assert [r["Path"] for r in rows] == [same, gone, legacy, fresh]
    assert [r["Title"] for r in rows] == ["SAME", "GONE", "LEGACY", "FRESH"]


# --- Y19/Y20/Y21: --no-resume and --limit ----------------------------------


def test_no_resume_ignores_the_previous_output(tmp_path, shim_path, whisper_script):
    """Y19."""
    a = media(tmp_path, "a.mkv")
    whisper_script({"*": ["it", 0.95]})
    out = write_phase2(tmp_path, [stamped(a, audit_common.VERDICT_CONFIRMED)],
                       name="out.csv")
    inp = write_phase1(tmp_path, [phase1_row(a)])

    assert vam.main(["--input", inp, "--output", out, "--no-resume"]) == 0
    assert faster_whisper.WhisperModel.calls == [a]

    _header, rows = read_rows(out)
    assert len(rows) == 1
    assert rows[0]["Verdict"] == audit_common.VERDICT_MISTAGGED


def test_limit_verifies_the_first_n_in_input_order(tmp_path, shim_path, whisper_script):
    """Y20."""
    a = media(tmp_path, "a.mkv")
    b = media(tmp_path, "b.mkv")
    c = media(tmp_path, "c.mkv")
    whisper_script({"*": ["en", 0.9]})
    inp = write_phase1(tmp_path, [phase1_row(a), phase1_row(b), phase1_row(c)])
    out = str(tmp_path / "out.csv")

    assert vam.main(["--input", inp, "--output", out, "--limit", "2"]) == 0

    assert faster_whisper.WhisperModel.calls == [a, b]
    _header, rows = read_rows(out)
    assert [r["Path"] for r in rows] == [a, b]


def test_limit_keeps_the_previous_verdict_of_a_deferred_row(tmp_path, shim_path,
                                                            whisper_script):
    """Y21 (R4): C changed and is cut by --limit 1 -- its old verdict must
    survive the run instead of vanishing from the report."""
    a = media(tmp_path, "a.mkv")
    b = media(tmp_path, "b.mkv")
    c = media(tmp_path, "c.mkv")
    whisper_script({"*": ["it", 0.95]})

    out = write_phase2(tmp_path, [
        stamped(b, audit_common.VERDICT_CONFIRMED, title="B"),
        prev_row(c, audit_common.VERDICT_CONFIRMED, size="1", mtime="1", title="C"),
    ], name="out.csv")
    inp = write_phase1(tmp_path, [phase1_row(a, title="A"), phase1_row(b, title="B"),
                                  phase1_row(c, title="C")])

    assert vam.main(["--input", inp, "--output", out, "--limit", "1"]) == 0

    assert faster_whisper.WhisperModel.calls == [a]
    _header, rows = read_rows(out)
    assert [r["Path"] for r in rows] == [b, c, a]
    assert rows[1]["Verdict"] == audit_common.VERDICT_CONFIRMED
    assert (rows[1]["FileSize"], rows[1]["FileMtime"]) == ("1", "1")
    assert rows[2]["Verdict"] == audit_common.VERDICT_MISTAGGED


# --- Y33: R2, one file with two episode rows -------------------------------


def test_two_episodes_of_one_file_keep_their_own_rows(tmp_path, shim_path,
                                                      whisper_script):
    """Y33 (R2): a double episode in a single file is two Sonarr rows sharing
    one path. Resume must not collapse them onto each other."""
    path = media(tmp_path, "S01E01E02.mkv")
    whisper_script({"*": ["en", 0.9]})
    inp = write_phase1(tmp_path, [
        phase1_row(path, title="Show", episode="S01E01 - A"),
        phase1_row(path, title="Show", episode="S01E02 - B"),
    ])
    out = str(tmp_path / "out.csv")

    assert vam.main(["--input", inp, "--output", out]) == 0
    assert faster_whisper.WhisperModel.calls == [path, path]

    _header, rows = read_rows(out)
    assert [r["Episode"] for r in rows] == ["S01E01 - A", "S01E02 - B"]

    reset_model_recording()
    assert vam.main(["--input", inp, "--output", out]) == 0
    assert faster_whisper.WhisperModel.calls == []

    _header, rows = read_rows(out)
    assert len(rows) == 2
    assert [r["Episode"] for r in rows] == ["S01E01 - A", "S01E02 - B"]
    assert [r["Path"] for r in rows] == [path, path]


# --- Y35: an episode phase 1 relabelled ------------------------------------


def test_relabelled_episode_keeps_its_verdict_without_relistening(
    tmp_path, shim_path, whisper_script, capsys
):
    """Y35: renaming an episode in Sonarr must not cost an hour of CPU, and
    must not leave the same file in the report twice for ever."""
    path = media(tmp_path, "x.mkv")
    whisper_script({"*": ["en", 0.9]})
    out = str(tmp_path / "out.csv")

    old = write_phase1(tmp_path, [phase1_row(path, title="Show",
                                             episode="S01E01 - Pilot")])
    assert vam.main(["--input", old, "--output", out]) == 0
    assert faster_whisper.WhisperModel.calls == [path]
    _header, rows = read_rows(out)
    assert rows[0]["Verdict"] == audit_common.VERDICT_CONFIRMED

    new_input = write_phase1(tmp_path, [phase1_row(path, title="Show",
                                                   episode="S01E01 - The Pilot")],
                             name="in2.csv")
    reset_model_recording()
    capsys.readouterr()

    assert vam.main(["--input", new_input, "--output", out]) == 0

    # No model was even constructed: nothing needed listening to.
    assert faster_whisper.WhisperModel.instances == []
    assert faster_whisper.WhisperModel.calls == []

    _header, rows = read_rows(out)
    assert len(rows) == 1
    assert rows[0]["Episode"] == "S01E01 - The Pilot"
    assert rows[0]["Verdict"] == audit_common.VERDICT_CONFIRMED
    assert rows[0]["DetectedLanguage"] == "en"
    assert_precise_signature(rows[0], path)

    # A third run must be a no-op too: the old label is gone for good, not
    # carried along as an orphan that reappears on every run.
    reset_model_recording()
    assert vam.main(["--input", new_input, "--output", out]) == 0
    _header, rows = read_rows(out)
    assert len(rows) == 1
    assert faster_whisper.WhisperModel.instances == []


def test_relabelled_episode_whose_file_also_changed_is_dropped_and_reverified(
    tmp_path, shim_path, whisper_script, capsys
):
    """Y35 twin: when the verdict cannot be carried over, the old label is
    still dropped -- one row for one file, either way."""
    path = media(tmp_path, "x.mkv")
    whisper_script({"*": ["it", 0.95]})
    out = write_phase2(tmp_path, [
        prev_row(path, audit_common.VERDICT_CONFIRMED, episode="S01E01 - Pilot",
                 size="1", mtime="1"),
    ], name="out.csv")
    inp = write_phase1(tmp_path, [phase1_row(path, episode="S01E01 - The Pilot")])

    assert vam.main(["--input", inp, "--output", out]) == 0

    err = capsys.readouterr().err
    assert "Dropped 1 superseded row(s): same file, relabelled by phase 1." in err
    assert "Carrying over" not in err

    assert faster_whisper.WhisperModel.calls == [path]
    _header, rows = read_rows(out)
    assert len(rows) == 1
    assert rows[0]["Episode"] == "S01E01 - The Pilot"
    assert rows[0]["Verdict"] == audit_common.VERDICT_MISTAGGED


# --- Y34: R3, an unstamped error row whose file came back ------------------


def test_file_not_found_row_is_retried_once_the_file_appears(tmp_path, shim_path,
                                                             whisper_script):
    """Y34 (R3): the share was unmounted last run. Without this the row is
    stamped with a real signature and never retried again."""
    path = media(tmp_path, "back.mkv")
    whisper_script({"*": ["it", 0.95]})
    out = write_phase2(tmp_path, [
        prev_row(path, audit_common.VERDICT_FILE_NOT_FOUND, detected="", confidence=""),
    ], name="out.csv")
    inp = write_phase1(tmp_path, [phase1_row(path)])

    assert vam.main(["--input", inp, "--output", out]) == 0

    assert faster_whisper.WhisperModel.calls == [path]
    _header, rows = read_rows(out)
    assert len(rows) == 1
    assert rows[0]["Verdict"] == audit_common.VERDICT_MISTAGGED
    assert_precise_signature(rows[0], path)


# --- Y27: quoting survives the round trip ----------------------------------


def test_quoted_phase1_line_round_trips_through_resume(tmp_path, shim_path,
                                                       whisper_script):
    """Y27: a title with a comma and embedded quotes, and a path with both,
    must come back out of the resume CSV byte for byte."""
    whisper_script({"*": ["en", 0.9]})
    inp = tmp_path / "in.csv"
    inp.write_text(
        "App,Title,Year,Episode,AudioLanguages,Path\n"
        'Radarr,"Hello, ""World""",2003,,"","/m/a, ""b"".mkv"\n',
        encoding="utf-8",
    )
    out = str(tmp_path / "out.csv")

    # The path does not exist, so this run verifies nothing successfully.
    assert vam.main(["--input", str(inp), "--output", out]) == vam.EXIT_ALL_FAILED

    _header, rows = read_rows(out)
    assert rows[0]["Title"] == 'Hello, "World"'
    assert rows[0]["Path"] == '/m/a, "b".mkv'
    assert rows[0]["Verdict"] == audit_common.VERDICT_FILE_NOT_FOUND

    # Second run: the row is read back, matched to the same input row and
    # kept -- if the quoting were lost it would not match and would be an
    # orphan alongside a fresh row.
    reset_model_recording()
    assert vam.main(["--input", str(inp), "--output", out]) == 0

    _header, rows = read_rows(out)
    assert len(rows) == 1
    assert rows[0]["Title"] == 'Hello, "World"'
    assert rows[0]["Path"] == '/m/a, "b".mkv'
    assert faster_whisper.WhisperModel.instances == []

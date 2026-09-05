#!/usr/bin/env python3
"""
Phase 2 worker for arr-language-audit.

Reads the CSV produced by find-missing-italian-audio.sh and, for each file,
extracts a short audio sample and runs local language detection on it using
faster-whisper. Produces a new CSV comparing the DECLARED tag (from Radarr/
Sonarr mediaInfo) against the ACTUALLY DETECTED spoken language.

This does NOT rely on container metadata at all -- it listens to the audio.
No media file is modified; the only output is the verdict CSV.

What is listened to: the audio stream the container marks as default (else
the first one), sampled for SAMPLE_SECONDS from SAMPLE_OFFSET_PCT into the
file. Only that window decides -- a file whose sampled minute is music, or
whose tracks differ from the default one, is judged on what that minute
contains, which is why a detection below MIN_CONFIDENCE is reported as
LOW_CONFIDENCE rather than as an answer.

Normally you run this through verify-audio-language.sh, which performs the
dependency and disk-space checks first. You can also call it directly:

    python3 verify_audio_language.py --input missing-italian-audio.csv \
        --output verified-language-results.csv

By default, if the output CSV already exists, files already verified in it
are reused on subsequent runs, so you can stop and resume a long scan.
Rows are matched on (path, episode), not on the path alone: a single file
holding a double episode is two Sonarr rows sharing one path, and each of
them keeps its own verdict.

A file is re-verified automatically when its size or mtime changed since
the last run (it was replaced, re-encoded or re-downloaded), even though
its path is unchanged. Rows written before this behaviour existed carry no
stored size/mtime and are reused as-is until verified again. An error row
carrying no signature (typically FILE_NOT_FOUND from a run where the share
was not mounted) is retried as soon as the file is visible again, and is
never stamped with a signature it was not verified against.

Rows in the output whose (path, episode) is no longer in the phase 1 CSV:
if the file also changed on disk (it was fixed), the stale verdict is
dropped; if its signature still matches (the scan just had a narrower
scope) or the file is gone, the row is kept. Use the orchestrator's
"Reset reports" action to wipe everything and start over.

An episode phase 1 relabels keeps its verdict: the row under the old label
is superseded and dropped, and the verdict moves to the new one as long as
the file's signature is unchanged. Renaming an episode never costs a
re-listen, and never leaves the same file in the report twice.

--limit caps how many files are (re)verified in one run; the rows it cuts
keep the verdict they already had, so a limited run never empties out the
report.

    --retry-errors   also reprocess rows whose previous verdict is
                     retryable (FILE_NOT_FOUND, EXTRACTION_FAILED,
                     DETECTION_FAILED, LOW_CONFIDENCE)
    --no-resume      ignore any existing output file and start fresh
                     (overwrites it)

Verdicts written to the output CSV:
    MISTAGGED_IS_ITALIAN    spoken language is Italian; only the tag was
                            wrong. Fix the mediaInfo/tag, no redownload.
    CONFIRMED_NOT_ITALIAN   spoken language really is not Italian. Needs a
                            real fix: redownload or remux an Italian track.
    LOW_CONFIDENCE          a language was named but below MIN_CONFIDENCE, so
                            it decides nothing. Re-run with a bigger
                            WHISPER_MODEL or another SAMPLE_OFFSET_PCT, or
                            with --retry-errors.
    FILE_NOT_FOUND          path from the phase 1 CSV does not exist here.
    EXTRACTION_FAILED       ffmpeg could not produce an audio sample.
    DETECTION_FAILED        faster-whisper raised while analyzing the sample,
                            or could not name a language at all.

Exit codes:
    0   finished (including "nothing new to verify")
    1   configuration, input, output path or disk-space problem, or the
        model could not be loaded (the previous output CSV is untouched)
    2   usage error: an unknown flag or a bad value (argparse)
    3   every file this run tried to verify errored
    130 interrupted (Ctrl-C); the CSV written so far stays valid

Environment variables (optional):
    WHISPER_MODEL       tiny | base | small | medium (default: small)
    WHISPER_THREADS     CPU threads for the model (default: all cores)
    SAMPLE_SECONDS      length of the audio sample to analyze (default: 60)
    SAMPLE_OFFSET_PCT   where to start sampling, as % of duration (default: 25)
    MIN_CONFIDENCE      0..1; a detection below it is LOW_CONFIDENCE
                        (default: 0.6)
    MIN_FREE_SPACE_MB   minimum free space required in temp dir (default: 500)
    TEMP_DIR            PARENT directory for the run's scratch directory
                        (default: the system temp dir). A private
                        'lang-check-XXXX' directory is created inside it and
                        only that directory is ever removed -- the directory
                        you point TEMP_DIR at is never deleted.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

from audit_common import (
    ERROR_VERDICTS,
    PHASE2_COLUMNS,
    RETRYABLE_VERDICTS,
    VERDICT_CONFIRMED,
    VERDICT_DETECTION_FAILED,
    VERDICT_EXTRACTION_FAILED,
    VERDICT_FILE_NOT_FOUND,
    VERDICT_LOW_CONFIDENCE,
    VERDICT_MISTAGGED,
    check_python_floor,
    log,
)

# Default report location: <repo>/reports/ (this file lives in <repo>/verify/).
# Keeps phase 1, phase 2 and the HTML report pointed at the same directory
# regardless of the current working directory.
REPORTS_DIR = Path(__file__).resolve().parent.parent / "reports"
DEFAULT_INPUT = str(REPORTS_DIR / "missing-italian-audio.csv")
DEFAULT_OUTPUT = str(REPORTS_DIR / "verified-language-results.csv")

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_ALL_FAILED = 3
EXIT_INTERRUPTED = 130

# How much of a tool's complaint is worth keeping in the log.
MAX_ERROR_CHARS = 200


class WorkerError(Exception):
    """Anything that stops the run with exit 1 and a message for the user.

    Helpers raise instead of calling sys.exit, so main() stays the only place
    that decides an exit code -- and so the tests can call them directly."""


class ConfigError(WorkerError):
    """An environment variable does not hold a usable value."""


class DiskSpaceError(WorkerError):
    """Not enough free space left in the scratch directory."""


@dataclass(frozen=True)
class Config:
    """Everything the run takes from the environment, read once in main()."""

    whisper_model: str = "small"
    sample_seconds: int = 60
    sample_offset_pct: float = 25.0
    min_free_space_mb: int = 500
    temp_parent: str | None = None
    # The floor a detection has to clear before its language is believed;
    # anything under it is VERDICT_LOW_CONFIDENCE. See classify().
    min_confidence: float = 0.6
    whisper_threads: int = 0

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> Config:
        """Build a Config from `env` (default: os.environ).

        An unset variable and one exported empty ("SAMPLE_SECONDS=") mean the
        same thing: use the default. Anything else that is not a usable value
        raises ConfigError, which main() reports as exit 1."""
        source: Mapping[str, str] = os.environ if env is None else env

        def text(name: str) -> str:
            return (source.get(name) or "").strip()

        kinds = {int: "whole number", float: "number"}

        def number(name: str, default, cast, low=None, high=None):
            raw = text(name)
            if not raw:
                return default
            try:
                value = cast(raw)
            except (TypeError, ValueError):
                raise ConfigError(
                    f"{name} must be a {kinds[cast]}, got '{raw}'."
                ) from None
            if (low is not None and value < low) or (high is not None and value > high):
                bounds = f"{low}..{high}" if high is not None else f">= {low}"
                raise ConfigError(f"{name} must be {bounds}, got '{raw}'.")
            return value

        return cls(
            whisper_model=text("WHISPER_MODEL") or "small",
            sample_seconds=number("SAMPLE_SECONDS", 60, int, low=1),
            sample_offset_pct=number("SAMPLE_OFFSET_PCT", 25.0, float, low=0.0, high=100.0),
            min_free_space_mb=number("MIN_FREE_SPACE_MB", 500, int, low=0),
            temp_parent=text("TEMP_DIR") or None,
            min_confidence=number("MIN_CONFIDENCE", 0.6, float, low=0.0, high=1.0),
            whisper_threads=number("WHISPER_THREADS", 0, int, low=0),
        )


def make_temp_dir(cfg: Config) -> str:
    """A private scratch directory for this run's audio samples.

    TEMP_DIR (cfg.temp_parent) is only ever the PARENT: a user pointing it at
    /tmp or at a scratch share must get their directory back untouched, so the
    only thing this program ever removes is the directory it created here."""
    if cfg.temp_parent:
        os.makedirs(cfg.temp_parent, exist_ok=True)
    return tempfile.mkdtemp(prefix="lang-check-", dir=cfg.temp_parent)


def check_disk_space(path: str, min_mb: int) -> None:
    usage = shutil.disk_usage(path)
    free_mb = usage.free / (1024 * 1024)
    if free_mb < min_mb:
        raise DiskSpaceError(
            f"only {free_mb:.0f} MB free in '{path}', need at least {min_mb} MB."
        )


@dataclass(frozen=True)
class MediaProbe:
    """What one ffprobe call tells us about a media file.

    duration      length in seconds, or None when it could not be read
    audio_stream  which audio stream to listen to, counted WITHIN the file's
                  audio streams (what `-map 0:a:<n>` takes, not the container
                  stream index), or None when the file has no audio stream or
                  the probe failed
    """

    duration: float | None
    audio_stream: int | None


def probe_media(file_path: str) -> MediaProbe:
    """Duration and the audio stream to sample, from ONE ffprobe invocation.

    R5: ffmpeg left to itself takes the audio stream with the most channels,
    so an Italian 2.0 track flagged default alongside an English 5.1 track was
    being judged in English. The stream the container marks as default is the
    one the user hears, and it is the one we listen to; failing that, the first
    audio stream.

    One invocation because this runs once per file over a whole library.
    -select_streams a is what makes the array position an audio-relative
    index; -show_streams (rather than -show_entries stream_disposition=...)
    is spelled the way every ffprobe build accepts."""
    try:
        result = subprocess.run(
            [
                "ffprobe", "-v", "error",
                "-select_streams", "a",
                "-show_streams",
                "-show_format",
                "-of", "json",
                file_path,
            ],
            capture_output=True, text=True, timeout=30, check=False,
        )
        data = json.loads(result.stdout)
        if not isinstance(data, dict):
            raise ValueError("ffprobe did not return an object")
    except Exception:  # noqa: BLE001
        # Any probe failure means "nothing known"; the caller falls back to
        # sampling from the start and letting ffmpeg choose the stream.
        return MediaProbe(None, None)

    try:
        duration = float((data.get("format") or {})["duration"])
    except (AttributeError, KeyError, TypeError, ValueError):
        duration = None

    # Defensive on top of -select_streams: a build that ignored it must not
    # shift the numbering by counting a video stream.
    audio = [s for s in (data.get("streams") or [])
             if isinstance(s, dict) and (s.get("codec_type") or "audio") == "audio"]
    if not audio:
        return MediaProbe(duration, None)
    chosen = 0
    for position, stream in enumerate(audio):
        if (stream.get("disposition") or {}).get("default"):
            chosen = position
            break
    return MediaProbe(duration, chosen)


def extract_sample(file_path: str, out_wav: str, cfg: Config, probe: MediaProbe) -> bool:
    duration = probe.duration
    if duration is None or duration <= 0:
        start = 0
    else:
        start = max(0, duration * (cfg.sample_offset_pct / 100.0))
        # don't start so late that there's not enough left to sample
        start = min(start, max(0, duration - cfg.sample_seconds))

    argv = [
        "ffmpeg",
        "-nostdin",
        "-loglevel", "error",
        "-y",
        "-ss", str(start),
        "-i", file_path,
    ]
    if probe.audio_stream is not None:
        # R5: name the stream explicitly, or ffmpeg picks the one with the
        # most channels rather than the one the container marks as default.
        argv += ["-map", f"0:a:{probe.audio_stream}"]
    argv += [
        "-t", str(cfg.sample_seconds),
        "-vn",
        "-acodec", "pcm_s16le",
        "-ar", "16000",
        "-ac", "1",
        out_wav,
    ]

    try:
        subprocess.run(
            argv,
            capture_output=True, text=True, timeout=120, check=True,
        )
        return os.path.exists(out_wav) and os.path.getsize(out_wav) > 0
    except subprocess.CalledProcessError as e:
        detail = (e.stderr or "").strip()[:MAX_ERROR_CHARS]
        log(f"  ffmpeg failed for '{file_path}': {detail}")
        return False
    except Exception as e:  # noqa: BLE001
        # One unreadable file must not end the run: report it and carry on.
        log(f"  ffmpeg failed for '{file_path}': {str(e)[:MAX_ERROR_CHARS]}")
        return False


def load_model(cfg: Config):
    # Imported here on purpose: loading faster_whisper costs seconds, and the
    # script must run --help (and fail cleanly) without the package installed.
    from faster_whisper import WhisperModel  # noqa: PLC0415

    threads = cfg.whisper_threads or os.cpu_count() or 4
    log(f"Loading Whisper model '{cfg.whisper_model}' (CPU, {threads} thread(s))...")
    return WhisperModel(
        cfg.whisper_model, device="cpu", compute_type="int8", cpu_threads=threads
    )


def detect_language(model, wav_path: str) -> tuple[str | None, float]:
    """(language, probability) for a sample. The language is None when the
    detector could not name one -- the caller turns that into a verdict.

    P5: transcribe() identifies the language from the first 30 s window only,
    so half of a 60 s sample never reached the decision. faster-whisper's
    dedicated detect_language() takes a second window when the first one comes
    back under language_detection_threshold, which is what a sample opening on
    music or on a silent title card needs. transcribe() stays as the fallback
    for a faster-whisper too old to have the method."""
    if hasattr(model, "detect_language"):
        result = model.detect_language(
            audio=wav_path,
            vad_filter=True,
            language_detection_segments=2,
            language_detection_threshold=0.5,
        )
        language, probability = result[0], result[1]
    else:
        _segments, info = model.transcribe(
            wav_path, beam_size=1, best_of=1, vad_filter=True
        )
        # Force generator evaluation is not needed: info.language is populated
        # after the initial language-detection pass, before segment decoding.
        language, probability = info.language, info.language_probability
    return language, float(probability or 0.0)


def classify(lang: str | None, prob: float, min_confidence: float) -> str:
    """The verdict for one detection result.

    H5: the probability used to be thrown away, so a 31%-confident "en"
    guessed off a window of music was written out as CONFIRMED_NOT_ITALIAN --
    the verdict that tells the user to re-download the file. A detection that
    does not clear `min_confidence` says nothing about the language and gets
    its own verdict, which --retry-errors picks up again.

    The threshold is a floor, not a gap: prob == min_confidence is believed."""
    if not lang:
        # Silence, or VAD stripped everything: no language to compare.
        return VERDICT_DETECTION_FAILED
    if prob < min_confidence:
        return VERDICT_LOW_CONFIDENCE
    return VERDICT_MISTAGGED if is_italian(lang) else VERDICT_CONFIRMED


def is_italian(lang_code: str | None) -> bool:
    """True only for a language code that names Italian. A missing code
    (the detector gave up) is not Italian and is not an error here."""
    if not lang_code:
        return False
    return lang_code.lower() in ("it", "ita")


def file_signature(path: str) -> tuple[int | None, int | None]:
    """(size_bytes, mtime_epoch_seconds) for path, or (None, None) if it
    cannot be stat()'d. Comparing this against the value stored on the
    previous run is how we notice a file was replaced even though its path
    did not change."""
    try:
        st = os.stat(path)
        return int(st.st_size), int(st.st_mtime)
    except OSError:
        return None, None


def row_key(row: Mapping[str, str]) -> tuple[str, str]:
    """(path, episode) -- what identifies a row across runs.

    The path alone is not enough: a file holding a double episode appears in
    the phase 1 CSV once per episode, and keying on the path made those two
    rows overwrite each other on every resume."""
    return ((row.get("Path") or "").strip(), (row.get("Episode") or "").strip())


def load_previous_rows(output_path: str) -> dict[tuple[str, str], dict]:
    """(path, episode) -> the previous run's output row (dict), for resume
    decisions. Empty when there is no readable previous output."""
    previous: dict[tuple[str, str], dict] = {}
    if not os.path.isfile(output_path):
        return previous
    with open(output_path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            key = row_key(row)
            if key[0]:
                previous[key] = row
    return previous


def resume_decision(entry, cur_size, cur_mtime, retry_errors: bool) -> str:
    """Decide what to do with an input row we have a previous verdict for.

        entry         previous output row for this (path, episode), or None
        cur_size      current file size in bytes, or None if the file is gone
        cur_mtime     current file mtime (epoch seconds), or None if gone
        retry_errors  reprocess rows whose previous verdict is retryable
                      (RETRYABLE_VERDICTS: the three error verdicts, plus
                      LOW_CONFIDENCE once the detector produces it)

    Returns 'verify' (run detection again and replace the old row) or
    'keep' (reuse the previous verdict unchanged)."""
    if entry is None:
        return "verify"
    verdict = (entry.get("Verdict", "") or "").strip()
    if retry_errors and verdict in RETRYABLE_VERDICTS:
        return "verify"

    prev_size = (entry.get("FileSize", "") or "").strip()
    prev_mtime = (entry.get("FileMtime", "") or "").strip()
    if not prev_size or not prev_mtime:
        if verdict in ERROR_VERDICTS and cur_size is not None and cur_mtime is not None:
            # An error row was never given a signature (FILE_NOT_FOUND is
            # written without one, and so is every row from a run older than
            # signatures). The file is readable again now, so the reason for
            # the error may be gone: verify instead of carrying the failure
            # forward for ever.
            return "verify"
        # Legacy row from before signatures were recorded: fall back to the
        # old path-only behaviour (keep). It gets a signature stamped on
        # this run, so change detection works for it from now on.
        return "keep"
    if cur_size is None or cur_mtime is None:
        # File not visible right now (unmounted share, transient error):
        # do not churn, keep the previous verdict.
        return "keep"
    unchanged = str(cur_size) == prev_size and str(cur_mtime) == prev_mtime
    return "keep" if unchanged else "verify"


def normalise_previous(row: Mapping[str, str], size=None, mtime=None) -> dict:
    """A row read back from a previous output CSV, reshaped to the current
    schema. Missing columns (older CSV) become "". A fresh signature is
    stamped on when one is passed, so legacy rows pick one up without being
    re-verified."""
    out = {k: (row.get(k, "") or "") for k in PHASE2_COLUMNS}
    if size is not None:
        out["FileSize"] = str(size)
    if mtime is not None:
        out["FileMtime"] = str(mtime)
    return out


def make_row(row: Mapping[str, str], *, detected="", confidence="", verdict="",
             size=None, mtime=None) -> dict:
    """An output row for an input row this run verified (or failed to).

    Keyword-only past `row`: six same-typed slots read as noise at the call
    site, and a mistyped one would silently land in the wrong column."""
    return {
        "App": row.get("App", ""),
        "Title": row.get("Title", ""),
        "Year": row.get("Year", ""),
        "Episode": row.get("Episode", ""),
        "DeclaredAudioLanguages": row.get("AudioLanguages", ""),
        "DetectedLanguage": detected,
        "Confidence": confidence,
        "Verdict": verdict,
        "Path": row.get("Path", ""),
        "FileSize": "" if size is None else str(size),
        "FileMtime": "" if mtime is None else str(mtime),
    }


@dataclass
class Plan:
    """What a run has to do, decided before anything is opened for writing.

    kept                finished output rows reused unchanged (input order)
    to_verify           input rows needing detection (input order, limited)
    deferred            previous rows for the rows --limit cut from to_verify
    orphans             previous rows whose key is no longer in the input
    dropped_stale       previous rows discarded because the file was fixed
    dropped_superseded  previous rows discarded because phase 1 relabelled
                        the same file under a different episode
    """

    kept: list[dict]
    to_verify: list[dict]
    deferred: list[dict]
    orphans: list[dict]
    dropped_stale: int
    dropped_superseded: int


def _carry_over(candidates, *, input_keys, consumed, cur_size, cur_mtime,
                retry_errors: bool):
    """The previous verdict for this same file under a different episode
    label, or (None, None).

    Phase 1 relabelling an episode ("S01E01 - Pilot" -> "S01E01 - The Pilot")
    changes the row's key without changing a byte of the media. Re-listening
    to the audio for that would be an hour of CPU spent on a metadata edit,
    so the verdict moves to the new label instead -- but only when the file
    is provably the same one it was verified against: a stored signature,
    equal to the current one, on a row that was actually verified."""
    for pkey, entry in candidates:
        # A candidate the input still lists under its own key belongs to that
        # row, and one already claimed by an earlier input row is spoken for.
        if pkey in input_keys or pkey in consumed:
            continue
        # ERROR_VERDICTS only, deliberately not the wider RETRYABLE_VERDICTS:
        # an error row was never verified against this file, so there is no
        # verdict to move. LOW_CONFIDENCE was earned, so it follows exactly
        # the same retry_errors rule here as it would under its own key --
        # carried when the flag is off, re-verified when it is on, which the
        # resume_decision call below enforces.
        if (entry.get("Verdict", "") or "").strip() in ERROR_VERDICTS:
            continue
        prev_size = (entry.get("FileSize", "") or "").strip()
        prev_mtime = (entry.get("FileMtime", "") or "").strip()
        if not prev_size or not prev_mtime or cur_size is None or cur_mtime is None:
            continue
        if str(cur_size) != prev_size or str(cur_mtime) != prev_mtime:
            continue
        # --retry-errors still wins: a row it would have re-run under its own
        # key must not sneak through as a relabel.
        if resume_decision(entry, cur_size, cur_mtime, retry_errors) != "keep":
            continue
        return pkey, entry
    return None, None


def plan_rows(input_rows, previous, *, retry_errors: bool, limit: int,
              signature=file_signature) -> Plan:
    """Split the input into reuse / re-verify / defer, and sort out the
    previous rows the input no longer mentions.

    Pure apart from `signature`, which is the only way it learns anything
    about the disk -- and is called at most once per distinct path, however
    many rows share it."""
    cache: dict[str, tuple] = {}

    def signature_of(path: str):
        if path not in cache:
            cache[path] = signature(path)
        return cache[path]

    input_keys = {row_key(row) for row in input_rows}
    input_paths = {k[0] for k in input_keys if k[0]}
    # Previous rows grouped by path. A file phase 1 relabelled has no row
    # under its new key, but its verdict is still there under the old one.
    by_path: dict[str, list] = {}
    for pkey, entry in previous.items():
        by_path.setdefault(pkey[0], []).append((pkey, entry))

    kept = []
    pending = []       # (input row, its previous row or None), input order
    consumed = set()   # previous keys claimed by a relabelled input row
    for row in input_rows:
        key = row_key(row)
        if not key[0]:
            # No path at all: not a resume question. The detection loop
            # records it as FILE_NOT_FOUND.
            pending.append((row, None))
            continue
        cur_size, cur_mtime = signature_of(key[0])
        entry = previous.get(key)
        if entry is None:
            pkey, source = _carry_over(
                by_path.get(key[0], ()), input_keys=input_keys, consumed=consumed,
                cur_size=cur_size, cur_mtime=cur_mtime, retry_errors=retry_errors,
            )
            if source is not None:
                # Same file, same signature, new label: the verdict moves to
                # the new row and the old key is dropped as superseded below.
                consumed.add(pkey)
                kept.append(make_row(
                    row,
                    detected=(source.get("DetectedLanguage", "") or ""),
                    confidence=(source.get("Confidence", "") or ""),
                    verdict=(source.get("Verdict", "") or ""),
                    size=cur_size, mtime=cur_mtime,
                ))
                continue
        if resume_decision(entry, cur_size, cur_mtime, retry_errors) == "verify":
            pending.append((row, entry))
            continue
        # A kept error row must not be stamped with a signature it was never
        # verified against, or resume_decision can never retry it again. This
        # is deliberately ERROR_VERDICTS and not the wider RETRYABLE_VERDICTS
        # --retry-errors uses above: a LOW_CONFIDENCE row was really listened
        # to and owns a true signature, so stamping it again is correct and
        # costs it nothing -- only rows that never got that far must stay
        # unstamped, or R3 can never notice their file came back.
        if (entry.get("Verdict", "") or "").strip() in ERROR_VERDICTS:
            kept.append(normalise_previous(entry))
        else:
            kept.append(normalise_previous(entry, cur_size, cur_mtime))

    # --limit caps the work, not the report: a row cut from this run keeps
    # the verdict it already had instead of disappearing from the output.
    cut = pending[limit:] if limit > 0 else []
    to_verify = [row for row, _ in (pending[:limit] if limit > 0 else pending)]
    deferred = [normalise_previous(entry) for _row, entry in cut if entry is not None]

    # Previous verdicts whose file is no longer listed by phase 1. Two cases:
    #  - the file changed on disk (signature differs) and is no longer
    #    flagged: it was fixed, the old verdict is stale -> drop the row so
    #    the report does not keep showing a wrong result.
    #  - anything else (signature still matches, file gone, or a legacy row
    #    with no signature): keep it. A matching signature usually means the
    #    row is "orphaned" only because this scan had a narrower scope
    #    (SKIP_RADARR / SKIP_SONARR, an app that was down), and re-running a
    #    full scan should not cost hours of re-verification.
    orphans = []
    dropped_stale = 0
    dropped_superseded = 0
    for key, entry in previous.items():
        if key in input_keys or key in consumed:
            continue
        if key[0] in input_paths:
            # The input still lists this file, under a different episode
            # label: phase 1 renamed the episode. The row for the new label
            # is handled above (with this verdict carried over when the file
            # is provably unchanged). Keeping this one too would show the
            # same file twice, for ever -- a metadata edit never changes the
            # signature, so nothing would ever clear it.
            dropped_superseded += 1
            continue
        prev_size = (entry.get("FileSize", "") or "").strip()
        prev_mtime = (entry.get("FileMtime", "") or "").strip()
        cur_size, cur_mtime = signature_of(key[0])
        if (prev_size and prev_mtime and cur_size is not None
                and (str(cur_size) != prev_size or str(cur_mtime) != prev_mtime)):
            dropped_stale += 1
            continue
        orphans.append(normalise_previous(entry))

    return Plan(kept=kept, to_verify=to_verify, deferred=deferred,
                orphans=orphans, dropped_stale=dropped_stale,
                dropped_superseded=dropped_superseded)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Verify the real spoken language of suspect media files (phase 2 of arr-language-audit).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Verdicts:\n"
            "  MISTAGGED_IS_ITALIAN   spoken audio is Italian, only the tag was wrong\n"
            "  CONFIRMED_NOT_ITALIAN  really not Italian; redownload or remux needed\n"
            "  LOW_CONFIDENCE         detected below MIN_CONFIDENCE; decides nothing.\n"
            "                         Retry with a bigger model, another offset, or\n"
            "                         --retry-errors\n"
            "  FILE_NOT_FOUND / EXTRACTION_FAILED / DETECTION_FAILED   see script header\n"
            "\n"
            "What is listened to: the default-disposition audio stream (else the first),\n"
            "for SAMPLE_SECONDS from SAMPLE_OFFSET_PCT in. Only that window decides.\n"
            "\n"
            "Exit codes:\n"
            "  0   finished (including 'nothing new to verify')\n"
            "  1   configuration, input, disk or model-load error\n"
            "  2   usage error (argparse)\n"
            "  3   every file this run tried to verify errored\n"
            "  130 interrupted\n"
            "\n"
            "Environment variables:\n"
            "  WHISPER_MODEL      tiny | base | small | medium        (default: small)\n"
            "  WHISPER_THREADS    CPU threads for the model           (default: all cores)\n"
            "  SAMPLE_SECONDS     audio sample length, seconds        (default: 60)\n"
            "  SAMPLE_OFFSET_PCT  sampling start, % of duration       (default: 25)\n"
            "  MIN_CONFIDENCE     floor below which a detection is    (default: 0.6)\n"
            "                     LOW_CONFIDENCE, 0..1\n"
            "  MIN_FREE_SPACE_MB  minimum free space in temp dir, MB  (default: 500)\n"
            "  TEMP_DIR           parent for the run's scratch dir    (default: system temp)\n"
            "                     never deleted; only the 'lang-check-*' directory\n"
            "                     created inside it is removed\n"
        ),
    )
    parser.add_argument("--input", default=DEFAULT_INPUT, help="CSV from find-missing-italian-audio.sh")
    parser.add_argument("--output", default=DEFAULT_OUTPUT, help="Output CSV path")
    parser.add_argument("--limit", type=int, default=0,
                        help="Only (re)verify the first N files that need it (0 = all); "
                             "the rows it cuts keep the verdict they already had")
    parser.add_argument("--retry-errors", action="store_true",
                        help="Also reprocess rows whose previous verdict is retryable "
                             "(FILE_NOT_FOUND, EXTRACTION_FAILED, DETECTION_FAILED, "
                             "LOW_CONFIDENCE)")
    parser.add_argument("--no-resume", action="store_true",
                        help="Ignore any existing output file and start fresh (overwrites it)")
    return parser


def main(argv: list[str] | None = None) -> int:
    check_python_floor()
    args = build_parser().parse_args(argv)

    temp_dir = None
    try:
        # The environment is read only now: a broken SAMPLE_SECONDS must not
        # stop --help from working.
        cfg = Config.from_env()

        if not os.path.isfile(args.input):
            raise WorkerError(
                f"input file '{args.input}' not found.\n"
                "Run verify/verify-audio-language.sh (or the orchestrator) first,\n"
                "or pass --input with the correct path."
            )

        out_dir = os.path.dirname(os.path.abspath(args.output))
        if out_dir:
            try:
                os.makedirs(out_dir, exist_ok=True)
            except OSError as e:
                raise WorkerError(
                    f"cannot create the output directory '{out_dir}': {e}"
                ) from e

        try:
            temp_dir = make_temp_dir(cfg)
        except OSError as e:
            raise WorkerError(f"cannot create a scratch directory: {e}") from e

        return _run(args, cfg, temp_dir)
    except WorkerError as e:
        log(f"ERROR: {e}")
        return EXIT_ERROR
    except KeyboardInterrupt:
        log("\nInterrupted. The results written so far are complete and valid.")
        return EXIT_INTERRUPTED
    finally:
        # Only ever the directory make_temp_dir() created, never TEMP_DIR.
        if temp_dir is not None:
            shutil.rmtree(temp_dir, ignore_errors=True)


def verify_one(row, model, cfg: Config, temp_dir: str, index: int) -> dict:
    """Detect one file's spoken language and return its finished output row.

    Every failure short of "the disk filled up" is a verdict, not an
    exception: one unreadable file must never end the run."""
    path = (row.get("Path", "") or "").strip()
    if not path or not os.path.isfile(path):
        return make_row(row, verdict=VERDICT_FILE_NOT_FOUND)

    cur_size, cur_mtime = file_signature(path)

    check_disk_space(temp_dir, cfg.min_free_space_mb)
    sample_path = os.path.join(temp_dir, f"sample_{index}.wav")

    probe = probe_media(path)
    if not extract_sample(path, sample_path, cfg, probe):
        return make_row(row, verdict=VERDICT_EXTRACTION_FAILED,
                        size=cur_size, mtime=cur_mtime)

    try:
        lang, prob = detect_language(model, sample_path)
    except Exception as e:  # noqa: BLE001
        # Whisper can fail in many ways; each is a DETECTION_FAILED row.
        log(f"  Whisper detection failed: {str(e)[:MAX_ERROR_CHARS]}")
        return make_row(row, verdict=VERDICT_DETECTION_FAILED,
                        size=cur_size, mtime=cur_mtime)
    finally:
        # Always clean up the sample immediately to keep disk usage minimal
        if os.path.exists(sample_path):
            os.remove(sample_path)

    verdict = classify(lang, prob, cfg.min_confidence)
    if verdict == VERDICT_DETECTION_FAILED:
        log("  Whisper detection failed: no language identified.")
        return make_row(row, verdict=verdict, size=cur_size, mtime=cur_mtime)

    # A LOW_CONFIDENCE row keeps the language and probability it was given:
    # they are what the user judges a re-run against.
    declared = row.get("AudioLanguages", "")
    log(f"  -> detected: {lang} ({prob:.0%}) | declared: {declared} | {verdict}")
    return make_row(row, detected=lang, confidence=f"{prob:.2f}", verdict=verdict,
                    size=cur_size, mtime=cur_mtime)


def _log_plan(plan: Plan, total: int) -> None:
    if plan.kept:
        log(f"Reusing {len(plan.kept)} previous verdict(s) for unchanged files.")
    if plan.deferred:
        log(f"Deferring {len(plan.deferred)} row(s) beyond --limit; their previous "
            "verdicts are kept.")
    if plan.orphans:
        log(f"Carrying over {len(plan.orphans)} row(s) whose file is no longer "
            "in the phase 1 CSV.")
    if plan.dropped_stale:
        log(f"Dropped {plan.dropped_stale} stale row(s): file changed and is no longer "
            "flagged by phase 1.")
    if plan.dropped_superseded:
        log(f"Dropped {plan.dropped_superseded} superseded row(s): same file, "
            "relabelled by phase 1.")
    log(f"Loaded {total} suspect file(s) total, "
        f"{len(plan.to_verify)} to (re)verify now.")


def _run(args, cfg: Config, temp_dir: str) -> int:
    check_disk_space(temp_dir, cfg.min_free_space_mb)

    with open(args.input, newline="", encoding="utf-8") as f:
        all_rows = list(csv.DictReader(f))

    previous = {} if args.no_resume else load_previous_rows(args.output)
    plan = plan_rows(all_rows, previous, retry_errors=args.retry_errors,
                     limit=args.limit)
    _log_plan(plan, len(all_rows))

    # The model is loaded BEFORE the output is opened for writing: opening it
    # truncates the previous run's verdicts, and a missing package or a failed
    # model download must not cost hours of already-done work.
    model = None
    if plan.to_verify:
        try:
            model = load_model(cfg)
        except (ImportError, OSError) as e:
            log(f"ERROR: could not load the Whisper model: {e}")
            log("Install faster_whisper (see the launcher script) and run again.")
            log(f"'{args.output}' was left untouched.")
            return EXIT_ERROR

    # Always rewrite the output in full: every row we already have a verdict
    # for goes out first, so a crash during detection still leaves a
    # complete, valid CSV.
    # SIM115: deliberately not a context manager -- the handle lives for the
    # whole detection loop and is flushed after every row, so an abort leaves a
    # complete file behind. It is closed in the finally below.
    try:
        out_f = open(args.output, "w", newline="", encoding="utf-8")  # noqa: SIM115
    except OSError as e:
        raise WorkerError(f"cannot write '{args.output}': {e}") from e
    counts: dict[str, int] = {}
    try:
        writer = csv.DictWriter(out_f, fieldnames=list(PHASE2_COLUMNS))
        writer.writeheader()
        for r in plan.kept + plan.deferred + plan.orphans:
            writer.writerow(r)
        out_f.flush()

        if not plan.to_verify:
            log("Nothing new to verify.")
            return EXIT_OK

        for i, row in enumerate(plan.to_verify, start=1):
            log(f"[{i}/{len(plan.to_verify)}] {row.get('Title', '')} ...")
            out_row = verify_one(row, model, cfg, temp_dir, i)
            writer.writerow(out_row)
            # Flushed after every row so an abort leaves a complete CSV behind.
            out_f.flush()
            counts[out_row["Verdict"]] = counts.get(out_row["Verdict"], 0) + 1
    finally:
        out_f.close()

    error_count = sum(n for v, n in counts.items() if v in ERROR_VERDICTS)
    log("\n--- Summary ---")
    log(f"Reused unchanged:             {len(plan.kept)}")
    log(f"Dropped (fixed, unflagged):   {plan.dropped_stale}")
    log(f"Dropped (relabelled):         {plan.dropped_superseded}")
    log(f"Mistagged (actually Italian): {counts.get(VERDICT_MISTAGGED, 0)}")
    log(f"Confirmed not Italian:        {counts.get(VERDICT_CONFIRMED, 0)}")
    log(f"Low confidence:               {counts.get(VERDICT_LOW_CONFIDENCE, 0)}")
    log(f"Errors this run:              {error_count}")
    log(f"\nFull results written to: {args.output}")

    if error_count == len(plan.to_verify):
        log("ERROR: every file errored this run -- nothing was verified.")
        log("Check that the media paths are mounted and readable.")
        return EXIT_ALL_FAILED
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())

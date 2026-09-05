#!/usr/bin/env python3
"""
Phase 2 worker for arr-language-audit.

Reads the CSV produced by find-missing-italian-audio.sh and, for each file,
extracts a short audio sample and runs local language detection on it using
faster-whisper. Produces a new CSV comparing the DECLARED tag (from Radarr/
Sonarr mediaInfo) against the ACTUALLY DETECTED spoken language.

This does NOT rely on container metadata at all -- it listens to the audio.
No media file is modified; the only output is the verdict CSV.

Normally you run this through verify-audio-language.sh, which performs the
dependency and disk-space checks first. You can also call it directly:

    python3 verify_audio_language.py --input missing-italian-audio.csv \
        --output verified-language-results.csv

By default, if the output CSV already exists, files already verified in it
are reused on subsequent runs, so you can stop and resume a long scan.
A file is re-verified automatically when its size or mtime changed since
the last run (it was replaced, re-encoded or re-downloaded), even though
its path is unchanged. Rows written before this behaviour existed carry no
stored size/mtime and are reused as-is until verified again.

Rows in the output whose path is no longer in the phase 1 CSV: if the file
also changed on disk (it was fixed), the stale verdict is dropped; if its
signature still matches (the scan just had a narrower scope) or the file
is gone, the row is kept. Use the orchestrator's "Reset reports" action to
wipe everything and start over.

    --retry-errors   also reprocess rows that previously failed
                     (FILE_NOT_FOUND, EXTRACTION_FAILED, DETECTION_FAILED)
    --no-resume      ignore any existing output file and start fresh
                     (overwrites it)

Verdicts written to the output CSV:
    MISTAGGED_IS_ITALIAN    spoken language is Italian; only the tag was
                            wrong. Fix the mediaInfo/tag, no redownload.
    CONFIRMED_NOT_ITALIAN   spoken language really is not Italian. Needs a
                            real fix: redownload or remux an Italian track.
    FILE_NOT_FOUND          path from the phase 1 CSV does not exist here.
    EXTRACTION_FAILED       ffmpeg could not produce an audio sample.
    DETECTION_FAILED        faster-whisper raised while analyzing the sample,
                            or could not name a language at all.

Exit codes:
    0   finished (including "nothing new to verify")
    1   usage, configuration, input or disk-space problem, or the model
        could not be loaded (the previous output CSV is left untouched)
    3   every file this run tried to verify errored
    130 interrupted (Ctrl-C); the CSV written so far stays valid

Environment variables (optional):
    WHISPER_MODEL       tiny | base | small | medium (default: small)
    WHISPER_THREADS     CPU threads for the model (default: all cores)
    SAMPLE_SECONDS      length of the audio sample to analyze (default: 60)
    SAMPLE_OFFSET_PCT   where to start sampling, as % of duration (default: 25)
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
    VERDICT_CONFIRMED,
    VERDICT_DETECTION_FAILED,
    VERDICT_EXTRACTION_FAILED,
    VERDICT_FILE_NOT_FOUND,
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
    # Not consulted yet: the low-confidence verdict arrives with the switch to
    # the dedicated detection API. Parsed here so the launcher can already
    # export it and so a typo is reported at start-up rather than later.
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


def get_duration_seconds(file_path: str) -> float | None:
    try:
        result = subprocess.run(
            [
                "ffprobe", "-v", "error",
                "-show_entries", "format=duration",
                "-of", "json",
                file_path,
            ],
            capture_output=True, text=True, timeout=30, check=False,
        )
        data = json.loads(result.stdout)
        return float(data["format"]["duration"])
    except Exception:  # noqa: BLE001
        # Any probe failure means "duration unknown"; the caller falls back.
        return None


def extract_sample(file_path: str, out_wav: str, cfg: Config) -> bool:
    duration = get_duration_seconds(file_path)
    if duration is None or duration <= 0:
        start = 0
    else:
        start = max(0, duration * (cfg.sample_offset_pct / 100.0))
        # don't start so late that there's not enough left to sample
        start = min(start, max(0, duration - cfg.sample_seconds))

    try:
        subprocess.run(
            [
                "ffmpeg",
                "-nostdin",
                "-loglevel", "error",
                "-y",
                "-ss", str(start),
                "-i", file_path,
                "-t", str(cfg.sample_seconds),
                "-vn",
                "-acodec", "pcm_s16le",
                "-ar", "16000",
                "-ac", "1",
                out_wav,
            ],
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
    detector could not name one -- the caller turns that into a verdict."""
    _segments, info = model.transcribe(wav_path, beam_size=1, best_of=1, vad_filter=True)
    # Force generator evaluation is not needed: info.language is populated
    # after the initial language-detection pass, before segment decoding.
    return info.language, float(info.language_probability or 0.0)


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


def load_previous_rows(output_path: str) -> dict:
    """path -> the previous run's output row (dict), for resume decisions.
    Empty when there is no readable previous output."""
    previous = {}
    if not os.path.isfile(output_path):
        return previous
    with open(output_path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            path = (row.get("Path", "") or "").strip()
            if path:
                previous[path] = row
    return previous


def resume_decision(entry, cur_size, cur_mtime, retry_errors: bool) -> str:
    """Decide what to do with an input row we have a previous verdict for.

        entry         previous output row for this path, or None
        cur_size      current file size in bytes, or None if the file is gone
        cur_mtime     current file mtime (epoch seconds), or None if gone
        retry_errors  reprocess rows whose previous verdict was an error

    Returns 'verify' (run detection again and replace the old row) or
    'keep' (reuse the previous verdict unchanged)."""
    if entry is None:
        return "verify"
    if retry_errors and (entry.get("Verdict", "") or "") in ERROR_VERDICTS:
        return "verify"

    prev_size = (entry.get("FileSize", "") or "").strip()
    prev_mtime = (entry.get("FileMtime", "") or "").strip()
    if not prev_size or not prev_mtime:
        # Legacy row from before signatures were recorded: fall back to the
        # old path-only behaviour (keep). It gets a signature stamped on
        # this run, so change detection works for it from now on.
        return "keep"
    if cur_size is None or cur_mtime is None:
        # File not visible right now (unmounted share, transient error):
        # do not churn, keep the previous verdict.
        return "keep"
    if str(cur_size) == prev_size and str(cur_mtime) == prev_mtime:
        return "keep"
    return "verify"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Verify the real spoken language of suspect media files (phase 2 of arr-language-audit).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Verdicts:\n"
            "  MISTAGGED_IS_ITALIAN   spoken audio is Italian, only the tag was wrong\n"
            "  CONFIRMED_NOT_ITALIAN  really not Italian; redownload or remux needed\n"
            "  FILE_NOT_FOUND / EXTRACTION_FAILED / DETECTION_FAILED   see script header\n"
            "\n"
            "Exit codes:\n"
            "  0   finished (including 'nothing new to verify')\n"
            "  1   usage, configuration, input, disk space, or model loading failed\n"
            "  3   every file this run tried to verify errored\n"
            "  130 interrupted\n"
            "\n"
            "Environment variables:\n"
            "  WHISPER_MODEL      tiny | base | small | medium        (default: small)\n"
            "  WHISPER_THREADS    CPU threads for the model           (default: all cores)\n"
            "  SAMPLE_SECONDS     audio sample length, seconds        (default: 60)\n"
            "  SAMPLE_OFFSET_PCT  sampling start, % of duration       (default: 25)\n"
            "  MIN_FREE_SPACE_MB  minimum free space in temp dir, MB  (default: 500)\n"
            "  TEMP_DIR           parent for the run's scratch dir    (default: system temp)\n"
            "                     never deleted; only the 'lang-check-*' directory\n"
            "                     created inside it is removed\n"
        ),
    )
    parser.add_argument("--input", default=DEFAULT_INPUT, help="CSV from find-missing-italian-audio.sh")
    parser.add_argument("--output", default=DEFAULT_OUTPUT, help="Output CSV path")
    parser.add_argument("--limit", type=int, default=0,
                        help="Only (re)verify the first N files that need it (0 = all)")
    parser.add_argument("--retry-errors", action="store_true",
                        help="Also reprocess rows that previously failed "
                             "(FILE_NOT_FOUND, EXTRACTION_FAILED, DETECTION_FAILED)")
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


def _run(args, cfg: Config, temp_dir: str) -> int:
    check_disk_space(temp_dir, cfg.min_free_space_mb)

    fieldnames = list(PHASE2_COLUMNS)

    def norm_prev(row, size=None, mtime=None):
        # A row read back from a previous output CSV, reshaped to the current
        # schema. Missing columns (older CSV) become "". A fresh signature is
        # stamped on when the file is still readable, so legacy rows pick one
        # up without being re-verified.
        out = {k: (row.get(k, "") or "") for k in fieldnames}
        if size is not None:
            out["FileSize"] = str(size)
        if mtime is not None:
            out["FileMtime"] = str(mtime)
        return out

    def make_row(row, *, detected="", confidence="", verdict="", size=None, mtime=None):
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

    with open(args.input, newline="", encoding="utf-8") as f:
        all_rows = list(csv.DictReader(f))

    previous = {} if args.no_resume else load_previous_rows(args.output)
    input_paths = {
        (r.get("Path", "") or "").strip()
        for r in all_rows if (r.get("Path", "") or "").strip()
    }

    # Split the input into "already known, unchanged" (reuse the verdict)
    # and "needs (re)verification" (new file, or size/mtime changed).
    kept_rows = []      # finished output rows, input order
    to_verify = []      # input rows still needing detection, input order
    for row in all_rows:
        path = (row.get("Path", "") or "").strip()
        if not path:
            to_verify.append(row)          # worker will record FILE_NOT_FOUND
            continue
        cur_size, cur_mtime = file_signature(path)
        entry = previous.get(path)
        if resume_decision(entry, cur_size, cur_mtime, args.retry_errors) == "keep":
            kept_rows.append(norm_prev(entry, cur_size, cur_mtime))
        else:
            to_verify.append(row)

    # Previous verdicts whose file is no longer listed by phase 1. Two cases:
    #  - the file changed on disk (signature differs) and is no longer
    #    flagged: it was fixed, the old verdict is stale -> drop the row so
    #    the report does not keep showing a wrong result.
    #  - anything else (signature still matches, file gone, or a legacy row
    #    with no signature): keep it. A matching signature usually means the
    #    row is "orphaned" only because this scan had a narrower scope
    #    (SKIP_RADARR / SKIP_SONARR, an app that was down), and re-running a
    #    full scan should not cost hours of re-verification.
    orphan_rows = []
    dropped_stale = 0
    for p, r in previous.items():
        if p in input_paths:
            continue
        prev_size = (r.get("FileSize", "") or "").strip()
        prev_mtime = (r.get("FileMtime", "") or "").strip()
        cur_size, cur_mtime = file_signature(p)
        if (prev_size and prev_mtime and cur_size is not None
                and (str(cur_size) != prev_size or str(cur_mtime) != prev_mtime)):
            dropped_stale += 1
            continue
        orphan_rows.append(norm_prev(r))

    if args.limit > 0:
        to_verify = to_verify[: args.limit]

    if kept_rows:
        log(f"Reusing {len(kept_rows)} previous verdict(s) for unchanged files.")
    if orphan_rows:
        log(f"Carrying over {len(orphan_rows)} row(s) whose file is no longer "
            "in the phase 1 CSV.")
    if dropped_stale:
        log(f"Dropped {dropped_stale} stale row(s): file changed and is no longer "
            "flagged by phase 1.")
    log(f"Loaded {len(all_rows)} suspect file(s) total, "
        f"{len(to_verify)} to (re)verify now.")

    # The model is loaded BEFORE the output is opened for writing: opening it
    # truncates the previous run's verdicts, and a missing package or a failed
    # model download must not cost hours of already-done work.
    model = None
    if to_verify:
        try:
            model = load_model(cfg)
        except (ImportError, OSError) as e:
            log(f"ERROR: could not load the Whisper model: {e}")
            log("Install faster_whisper (see the launcher script) and run again.")
            log(f"'{args.output}' was left untouched.")
            return EXIT_ERROR

    # Always rewrite the output in full: kept + carried-over rows first, so a
    # crash during detection still leaves a complete, valid CSV.
    # SIM115: deliberately not a context manager -- the handle lives for the
    # whole detection loop and is flushed after every row, so an abort leaves a
    # complete file behind. It is closed in the finally below.
    try:
        out_f = open(args.output, "w", newline="", encoding="utf-8")  # noqa: SIM115
    except OSError as e:
        raise WorkerError(f"cannot write '{args.output}': {e}") from e
    try:
        writer = csv.DictWriter(out_f, fieldnames=fieldnames)
        writer.writeheader()
        for r in kept_rows:
            writer.writerow(r)
        for r in orphan_rows:
            writer.writerow(r)
        out_f.flush()

        if not to_verify:
            log("Nothing new to verify.")
            return EXIT_OK

        mistagged_count = 0
        confirmed_foreign_count = 0
        error_count = 0

        for i, row in enumerate(to_verify, start=1):
            path = (row.get("Path", "") or "").strip()
            title = row.get("Title", "")
            log(f"[{i}/{len(to_verify)}] {title} ...")

            if not path or not os.path.isfile(path):
                writer.writerow(make_row(row, verdict=VERDICT_FILE_NOT_FOUND))
                error_count += 1
                out_f.flush()
                continue

            cur_size, cur_mtime = file_signature(path)

            check_disk_space(temp_dir, cfg.min_free_space_mb)
            sample_path = os.path.join(temp_dir, f"sample_{i}.wav")

            if not extract_sample(path, sample_path, cfg):
                writer.writerow(make_row(row, verdict=VERDICT_EXTRACTION_FAILED,
                                         size=cur_size, mtime=cur_mtime))
                error_count += 1
                out_f.flush()
                continue

            try:
                lang, prob = detect_language(model, sample_path)
            except Exception as e:  # noqa: BLE001
                # Whisper can fail in many ways; each is a DETECTION_FAILED row.
                log(f"  Whisper detection failed: {str(e)[:MAX_ERROR_CHARS]}")
                writer.writerow(make_row(row, verdict=VERDICT_DETECTION_FAILED,
                                         size=cur_size, mtime=cur_mtime))
                error_count += 1
                out_f.flush()
                continue
            finally:
                # Always clean up the sample immediately to keep disk usage minimal
                if os.path.exists(sample_path):
                    os.remove(sample_path)

            if lang is None:
                # Silence, or VAD stripped everything: no language to compare.
                log("  Whisper detection failed: no language identified.")
                writer.writerow(make_row(row, verdict=VERDICT_DETECTION_FAILED,
                                         size=cur_size, mtime=cur_mtime))
                error_count += 1
                out_f.flush()
                continue

            declared = row.get("AudioLanguages", "")
            if is_italian(lang):
                verdict = VERDICT_MISTAGGED
                mistagged_count += 1
            else:
                verdict = VERDICT_CONFIRMED
                confirmed_foreign_count += 1

            log(f"  -> detected: {lang} ({prob:.0%}) | declared: {declared} | {verdict}")

            writer.writerow(make_row(row, detected=lang, confidence=f"{prob:.2f}",
                                     verdict=verdict, size=cur_size, mtime=cur_mtime))
            out_f.flush()
    finally:
        out_f.close()

    log("\n--- Summary ---")
    log(f"Reused unchanged:             {len(kept_rows)}")
    log(f"Dropped (fixed, unflagged):   {dropped_stale}")
    log(f"Mistagged (actually Italian): {mistagged_count}")
    log(f"Confirmed not Italian:        {confirmed_foreign_count}")
    log(f"Errors this run:              {error_count}")
    log(f"\nFull results written to: {args.output}")

    if error_count == len(to_verify):
        log("ERROR: every file errored this run -- nothing was verified.")
        log("Check that the media paths are mounted and readable.")
        return EXIT_ALL_FAILED
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())

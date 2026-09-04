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
    DETECTION_FAILED        faster-whisper raised while analyzing the sample.

Environment variables (optional):
    WHISPER_MODEL       tiny | base | small | medium (default: small)
    SAMPLE_SECONDS      length of the audio sample to analyze (default: 60)
    SAMPLE_OFFSET_PCT   where to start sampling, as % of duration (default: 25)
    MIN_FREE_SPACE_MB   minimum free space required in temp dir (default: 500)
    TEMP_DIR           directory for temporary audio samples (default: mktemp)
"""

import argparse
import csv
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

WHISPER_MODEL = os.environ.get("WHISPER_MODEL", "small")
SAMPLE_SECONDS = int(os.environ.get("SAMPLE_SECONDS", "60"))
SAMPLE_OFFSET_PCT = float(os.environ.get("SAMPLE_OFFSET_PCT", "25"))
MIN_FREE_SPACE_MB = int(os.environ.get("MIN_FREE_SPACE_MB", "500"))

# Default report location: <repo>/reports/ (this file lives in <repo>/verify/).
# Keeps phase 1, phase 2 and the HTML report pointed at the same directory
# regardless of the current working directory.
REPORTS_DIR = Path(__file__).resolve().parent.parent / "reports"
DEFAULT_INPUT = str(REPORTS_DIR / "missing-italian-audio.csv")
DEFAULT_OUTPUT = str(REPORTS_DIR / "verified-language-results.csv")


def check_disk_space(path: str, min_mb: int) -> None:
    usage = shutil.disk_usage(path)
    free_mb = usage.free / (1024 * 1024)
    if free_mb < min_mb:
        print(
            f"ERROR: only {free_mb:.0f} MB free in '{path}', "
            f"need at least {min_mb} MB. Aborting.",
            file=sys.stderr,
        )
        sys.exit(1)


def get_duration_seconds(file_path: str) -> float | None:
    try:
        result = subprocess.run(
            [
                "ffprobe", "-v", "error",
                "-show_entries", "format=duration",
                "-of", "json",
                file_path,
            ],
            capture_output=True, text=True, timeout=30,
        )
        data = json.loads(result.stdout)
        return float(data["format"]["duration"])
    except Exception:
        return None


def extract_sample(file_path: str, out_wav: str) -> bool:
    duration = get_duration_seconds(file_path)
    if duration is None or duration <= 0:
        start = 0
    else:
        start = max(0, duration * (SAMPLE_OFFSET_PCT / 100.0))
        # don't start so late that there's not enough left to sample
        start = min(start, max(0, duration - SAMPLE_SECONDS))

    try:
        subprocess.run(
            [
                "ffmpeg", "-y",
                "-ss", str(start),
                "-i", file_path,
                "-t", str(SAMPLE_SECONDS),
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
        print(f"  ffmpeg failed for '{file_path}': {e.stderr.strip()[:200]}", file=sys.stderr)
        return False
    except Exception as e:
        print(f"  ffmpeg failed for '{file_path}': {e}", file=sys.stderr)
        return False


def load_model():
    from faster_whisper import WhisperModel
    print(f"Loading Whisper model '{WHISPER_MODEL}' (CPU)...", file=sys.stderr)
    return WhisperModel(WHISPER_MODEL, device="cpu", compute_type="int8")


def detect_language(model, wav_path: str) -> tuple[str, float]:
    segments, info = model.transcribe(wav_path, beam_size=1, best_of=1, vad_filter=True)
    # Force generator evaluation is not needed: info.language is populated
    # after the initial language-detection pass, before segment decoding.
    return info.language, info.language_probability


def is_italian(lang_code: str) -> bool:
    return lang_code.lower() in ("it", "ita")


ERROR_VERDICTS = {"FILE_NOT_FOUND", "EXTRACTION_FAILED", "DETECTION_FAILED"}


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


def main():
    parser = argparse.ArgumentParser(
        description="Verify the real spoken language of suspect media files (phase 2 of arr-language-audit).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Verdicts:\n"
            "  MISTAGGED_IS_ITALIAN   spoken audio is Italian, only the tag was wrong\n"
            "  CONFIRMED_NOT_ITALIAN  really not Italian; redownload or remux needed\n"
            "  FILE_NOT_FOUND / EXTRACTION_FAILED / DETECTION_FAILED   see script header\n"
            "\n"
            "Environment variables:\n"
            "  WHISPER_MODEL      tiny | base | small | medium        (default: small)\n"
            "  SAMPLE_SECONDS     audio sample length, seconds        (default: 60)\n"
            "  SAMPLE_OFFSET_PCT  sampling start, % of duration       (default: 25)\n"
            "  MIN_FREE_SPACE_MB  minimum free space in temp dir, MB  (default: 500)\n"
            "  TEMP_DIR          temp dir for audio samples          (default: mktemp)\n"
        ),
    )
    parser.add_argument("--input", default=DEFAULT_INPUT, help="CSV from find-missing-italian-audio.sh")
    parser.add_argument("--output", default=DEFAULT_OUTPUT, help="Output CSV path")
    parser.add_argument("--limit", type=int, default=0,
                        help="Only (re)verify the first N files that need it (0 = all)")
    parser.add_argument("--retry-errors", action="store_true",
                         help="Also reprocess rows that previously failed (FILE_NOT_FOUND, EXTRACTION_FAILED, DETECTION_FAILED)")
    parser.add_argument("--no-resume", action="store_true",
                         help="Ignore any existing output file and start fresh (overwrites it)")
    args = parser.parse_args()

    if not os.path.isfile(args.input):
        print(f"ERROR: input file '{args.input}' not found.", file=sys.stderr)
        print("Run verify/verify-audio-language.sh (or the orchestrator) first,", file=sys.stderr)
        print("or pass --input with the correct path.", file=sys.stderr)
        sys.exit(1)

    out_dir = os.path.dirname(os.path.abspath(args.output))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    temp_dir = os.environ.get("TEMP_DIR") or tempfile.mkdtemp(prefix="lang-check-")
    os.makedirs(temp_dir, exist_ok=True)
    check_disk_space(temp_dir, MIN_FREE_SPACE_MB)

    fieldnames = [
        "App", "Title", "Year", "Episode",
        "DeclaredAudioLanguages", "DetectedLanguage", "Confidence",
        "Verdict", "Path", "FileSize", "FileMtime",
    ]

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

    def make_row(row, detected="", confidence="", verdict="", size=None, mtime=None):
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
        print(f"Reusing {len(kept_rows)} previous verdict(s) for unchanged files.", file=sys.stderr)
    if orphan_rows:
        print(f"Carrying over {len(orphan_rows)} row(s) whose file is no longer in the phase 1 CSV.", file=sys.stderr)
    if dropped_stale:
        print(f"Dropped {dropped_stale} stale row(s): file changed and is no longer flagged by phase 1.", file=sys.stderr)
    print(f"Loaded {len(all_rows)} suspect file(s) total, {len(to_verify)} to (re)verify now.", file=sys.stderr)

    # Always rewrite the output in full: kept + carried-over rows first, so a
    # crash during detection still leaves a complete, valid CSV.
    out_f = open(args.output, "w", newline="", encoding="utf-8")
    writer = csv.DictWriter(out_f, fieldnames=fieldnames)
    writer.writeheader()
    for r in kept_rows:
        writer.writerow(r)
    for r in orphan_rows:
        writer.writerow(r)
    out_f.flush()

    if len(to_verify) == 0:
        out_f.close()
        print("Nothing new to verify.", file=sys.stderr)
        shutil.rmtree(temp_dir, ignore_errors=True)
        return

    model = load_model()

    mistagged_count = 0
    confirmed_foreign_count = 0
    error_count = 0

    try:
        for i, row in enumerate(to_verify, start=1):
            path = (row.get("Path", "") or "").strip()
            title = row.get("Title", "")
            print(f"[{i}/{len(to_verify)}] {title} ...", file=sys.stderr)

            if not path or not os.path.isfile(path):
                writer.writerow(make_row(row, verdict="FILE_NOT_FOUND"))
                error_count += 1
                out_f.flush()
                continue

            cur_size, cur_mtime = file_signature(path)

            check_disk_space(temp_dir, MIN_FREE_SPACE_MB)
            sample_path = os.path.join(temp_dir, f"sample_{i}.wav")

            if not extract_sample(path, sample_path):
                writer.writerow(make_row(row, verdict="EXTRACTION_FAILED",
                                         size=cur_size, mtime=cur_mtime))
                error_count += 1
                out_f.flush()
                continue

            try:
                lang, prob = detect_language(model, sample_path)
            except Exception as e:
                print(f"  Whisper detection failed: {e}", file=sys.stderr)
                writer.writerow(make_row(row, verdict="DETECTION_FAILED",
                                         size=cur_size, mtime=cur_mtime))
                error_count += 1
                out_f.flush()
                continue
            finally:
                # Always clean up the sample immediately to keep disk usage minimal
                if os.path.exists(sample_path):
                    os.remove(sample_path)

            declared = row.get("AudioLanguages", "")
            if is_italian(lang):
                verdict = "MISTAGGED_IS_ITALIAN"
                mistagged_count += 1
            else:
                verdict = "CONFIRMED_NOT_ITALIAN"
                confirmed_foreign_count += 1

            print(f"  -> detected: {lang} ({prob:.0%}) | declared: {declared} | {verdict}", file=sys.stderr)

            writer.writerow(make_row(row, detected=lang, confidence=f"{prob:.2f}",
                                     verdict=verdict, size=cur_size, mtime=cur_mtime))
            out_f.flush()
    finally:
        out_f.close()
        shutil.rmtree(temp_dir, ignore_errors=True)

    print("\n--- Summary ---", file=sys.stderr)
    print(f"Reused unchanged:             {len(kept_rows)}", file=sys.stderr)
    print(f"Dropped (fixed, unflagged):   {dropped_stale}", file=sys.stderr)
    print(f"Mistagged (actually Italian): {mistagged_count}", file=sys.stderr)
    print(f"Confirmed not Italian:        {confirmed_foreign_count}", file=sys.stderr)
    print(f"Errors this run:              {error_count}", file=sys.stderr)
    print(f"\nFull results written to: {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()

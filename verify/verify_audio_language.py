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

By default, if the output CSV already exists, files already listed in it
are SKIPPED on subsequent runs (matched by file path) -- so you can stop
and resume a long scan without re-analyzing files already checked.

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


def load_processed_paths(output_path: str, retry_errors: bool) -> set:
    """Returns the set of file paths already present in a previous run's
    output CSV, so they can be skipped on this run. If retry_errors is True,
    paths whose previous verdict was an error/failure are NOT included in
    the skip set, so they get reprocessed."""
    processed = set()
    if not os.path.isfile(output_path):
        return processed

    error_verdicts = {"FILE_NOT_FOUND", "EXTRACTION_FAILED", "DETECTION_FAILED"}
    with open(output_path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            path = row.get("Path", "").strip()
            verdict = row.get("Verdict", "")
            if not path:
                continue
            if retry_errors and verdict in error_verdicts:
                continue
            processed.add(path)
    return processed


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
    parser.add_argument("--input", default="missing-italian-audio.csv", help="CSV from find-missing-italian-audio.sh")
    parser.add_argument("--output", default="verified-language-results.csv", help="Output CSV path")
    parser.add_argument("--limit", type=int, default=0, help="Only process the first N NEW rows (0 = all)")
    parser.add_argument("--retry-errors", action="store_true",
                         help="Also reprocess rows that previously failed (FILE_NOT_FOUND, EXTRACTION_FAILED, DETECTION_FAILED)")
    parser.add_argument("--no-resume", action="store_true",
                         help="Ignore any existing output file and start fresh (overwrites it)")
    args = parser.parse_args()

    if not os.path.isfile(args.input):
        print(f"ERROR: input file '{args.input}' not found.", file=sys.stderr)
        sys.exit(1)

    temp_dir = os.environ.get("TEMP_DIR") or tempfile.mkdtemp(prefix="lang-check-")
    os.makedirs(temp_dir, exist_ok=True)
    check_disk_space(temp_dir, MIN_FREE_SPACE_MB)

    with open(args.input, newline="", encoding="utf-8") as f:
        all_rows = list(csv.DictReader(f))

    resuming = False
    if args.no_resume:
        processed_paths = set()
    else:
        processed_paths = load_processed_paths(args.output, args.retry_errors)
        resuming = len(processed_paths) > 0

    rows = [r for r in all_rows if r.get("Path", "").strip() not in processed_paths]
    skipped = len(all_rows) - len(rows)

    if args.limit > 0:
        rows = rows[: args.limit]

    if skipped > 0:
        print(f"Skipping {skipped} file(s) already present in '{args.output}' from a previous run.", file=sys.stderr)
    print(f"Loaded {len(all_rows)} suspect file(s) total, {len(rows)} to process now.", file=sys.stderr)

    if len(rows) == 0:
        print("Nothing new to process.", file=sys.stderr)
        shutil.rmtree(temp_dir, ignore_errors=True)
        return

    model = load_model()

    fieldnames = [
        "App", "Title", "Year", "Episode",
        "DeclaredAudioLanguages", "DetectedLanguage", "Confidence",
        "Verdict", "Path",
    ]
    write_header = not (resuming and os.path.isfile(args.output) and os.path.getsize(args.output) > 0)
    out_mode = "a" if (resuming and not write_header) else "w"
    out_f = open(args.output, out_mode, newline="", encoding="utf-8")
    writer = csv.DictWriter(out_f, fieldnames=fieldnames)
    if write_header:
        writer.writeheader()

    mistagged_count = 0
    confirmed_foreign_count = 0
    error_count = 0

    def make_row(row, detected="", confidence="", verdict=""):
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
        }

    try:
        for i, row in enumerate(rows, start=1):
            path = row.get("Path", "").strip()
            title = row.get("Title", "")
            print(f"[{i}/{len(rows)}] {title} ...", file=sys.stderr)

            if not path or not os.path.isfile(path):
                writer.writerow(make_row(row, verdict="FILE_NOT_FOUND"))
                error_count += 1
                continue

            check_disk_space(temp_dir, MIN_FREE_SPACE_MB)
            sample_path = os.path.join(temp_dir, f"sample_{i}.wav")

            if not extract_sample(path, sample_path):
                writer.writerow(make_row(row, verdict="EXTRACTION_FAILED"))
                error_count += 1
                continue

            try:
                lang, prob = detect_language(model, sample_path)
            except Exception as e:
                print(f"  Whisper detection failed: {e}", file=sys.stderr)
                writer.writerow(make_row(row, verdict="DETECTION_FAILED"))
                error_count += 1
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

            writer.writerow(make_row(row, detected=lang, confidence=f"{prob:.2f}", verdict=verdict))
            out_f.flush()
    finally:
        out_f.close()
        shutil.rmtree(temp_dir, ignore_errors=True)

    print("\n--- Summary ---", file=sys.stderr)
    print(f"Mistagged (actually Italian): {mistagged_count}", file=sys.stderr)
    print(f"Confirmed not Italian:        {confirmed_foreign_count}", file=sys.stderr)
    print(f"Errors/skipped:               {error_count}", file=sys.stderr)
    print(f"\nFull results written to: {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()

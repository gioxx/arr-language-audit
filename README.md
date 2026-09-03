# arr-language-audit

A small toolkit to find media files in your **Radarr** / **Sonarr** libraries
that do **not** have an Italian audio track, and then to *verify* the
suspicious ones by actually listening to the audio with a local speech model.

Runs on Linux and macOS (bash + Python). No media file is ever modified: the
scripts only produce CSV reports. Fixing a tag, remuxing, or re-downloading
stays a manual decision.

> The checks are hard-coded to Italian because that is what the author needs.
> The logic is simple enough to adapt to another language (see
> [Adapting to another language](#adapting-to-another-language)).

## Why this exists

Radarr and Sonarr expose a `mediaInfo.audioLanguages` field per file. It is
convenient but **not reliable**:

- it can be **missing** (older imports, files never rescanned);
- it can be **wrong** (mislabelled release, container tag says `ita` but the
  actual audio is English, or vice versa);
- it reflects the **container tag**, not the speech.

So a two-phase approach:

1. **Phase 1 (fast, API only)** trusts the tag as a first filter and lists
   every file whose tag is not explicitly Italian.
2. **Phase 2 (slow, local audio analysis)** takes that list, extracts a short
   audio sample from each file, and runs
   [faster-whisper](https://github.com/SYSTRAN/faster-whisper) locally (CPU,
   no external service) to detect the language **actually spoken**. Each file
   ends up with a verdict:
   - `MISTAGGED_IS_ITALIAN` — false positive; the audio *is* Italian, only the
     tag was wrong. Fix the tag, nothing to download.
   - `CONFIRMED_NOT_ITALIAN` — real problem; redownload or remux an Italian
     track.

## Repository layout

```
arr-language-audit/
├── README.md
├── LICENSE                       MIT
├── .gitignore
├── .env.example                  phase 1 config template (copy to .env)
├── scan/
│   └── find-missing-italian-audio.sh     phase 1 (bash + curl + jq)
└── verify/
    ├── verify-audio-language.sh          phase 2 launcher / pre-flight checks
    └── verify_audio_language.py          phase 2 worker (ffmpeg + faster-whisper)
```

## Requirements

**Phase 1:** `bash`, `curl`, `jq`, and network access to your Radarr/Sonarr
API.

**Phase 2:** everything above plus:

- `ffmpeg` / `ffprobe`
- `python3` with `pip`
- the `faster-whisper` Python package (installed by you — the script never
  installs anything on its own; it prints the exact commands and stops)
- **direct filesystem access to the actual media files.** Phase 2 reads the
  file paths from the phase 1 CSV and opens those files to sample their audio.
  The Radarr/Sonarr API alone is **not enough** for phase 2 — the machine
  running it must see the same paths (same host, or the library mounted at the
  same location, e.g. over NFS/SMB).
- enough free disk space in the temp directory for one short WAV sample at a
  time (default guard: 500 MB).

`faster-whisper` is looked for first in the system `python3`, then in a local
virtual environment at `verify/venv`. On Debian/Ubuntu, where the system
Python is externally managed (PEP 668), the launcher also checks that
`python3 -m venv` actually works and, if `ensurepip` is missing, tells you the
right `pythonX.Y-venv` apt package to install.

## Quickstart

Clone the repo and run both phases from the repo root.

### Phase 1 — list files without an Italian tag

```bash
cd arr-language-audit
./scan/find-missing-italian-audio.sh
```

On the first interactive run with no configuration, a wizard tries to
auto-detect a local Radarr (port 7878) and Sonarr (port 8989) through the
unauthenticated `/ping` endpoint, asks only for the API key when it finds
one, and offers to save everything to a `.env` file in the repo root. If
nothing is detected it asks for the full URL instead.

Prefer to configure it by hand:

```bash
cp .env.example .env
# edit .env: set RADARR_URL / RADARR_API_KEY / SONARR_URL / SONARR_API_KEY
./scan/find-missing-italian-audio.sh
```

Output: `./missing-italian-audio.csv` with columns
`App,Title,Year,Episode,AudioLanguages,Path`. If there are no findings the
file is not left behind.

Stale tags? Force Radarr/Sonarr to re-read every file from disk first:

```bash
FORCE_RESCAN=true ./scan/find-missing-italian-audio.sh
```

### Phase 2 — verify what is actually spoken

```bash
./verify/verify-audio-language.sh
```

Defaults: reads `./missing-italian-audio.csv`, writes
`./verified-language-results.csv` with columns
`App,Title,Year,Episode,DeclaredAudioLanguages,DetectedLanguage,Confidence,Verdict,Path`.

If a dependency is missing the script prints the exact install command and
exits without changing anything. A typical first-time setup on Debian/Ubuntu:

```bash
sudo apt install -y ffmpeg python3-venv
python3 -m venv verify/venv
"verify/venv/bin/pip" install --upgrade pip
"verify/venv/bin/pip" install faster-whisper
./verify/verify-audio-language.sh          # detects and uses verify/venv automatically
```

The run is resumable: stop it any time and run it again — files already in
the output CSV are skipped (matched by path). To retry only the ones that
failed, use `RETRY_ERRORS=true`. To throw the output away and start over, use
`NO_RESUME=true`.

Custom paths:

```bash
./verify/verify-audio-language.sh /path/to/input.csv /path/to/output.csv
```

## Configuration

### Phase 1 environment variables

Read from the environment, or from a `.env` file looked up (in order) in
`scan/`, the repo root, then the current directory — first match wins.

| Variable         | Default                  | Meaning |
|------------------|--------------------------|---------|
| `RADARR_URL`     | `http://localhost:7878`  | Radarr base URL |
| `RADARR_API_KEY` | —                        | Radarr API key |
| `SONARR_URL`     | `http://localhost:8989`  | Sonarr base URL |
| `SONARR_API_KEY` | —                        | Sonarr API key |
| `SKIP_RADARR`    | `false`                  | `true` to skip Radarr entirely |
| `SKIP_SONARR`    | `false`                  | `true` to skip Sonarr entirely |
| `FORCE_RESCAN`   | `false`                  | `true` to run `RescanMovie` / `RescanSeries` before reading `mediaInfo` |
| `RESCAN_TIMEOUT` | `300`                    | Seconds to wait for a rescan command to finish |

The first positional argument overrides the output CSV path:
`./scan/find-missing-italian-audio.sh /tmp/report.csv`.

### Phase 2 environment variables

| Variable            | Default   | Meaning |
|---------------------|-----------|---------|
| `WHISPER_MODEL`     | `small`   | `tiny` \| `base` \| `small` \| `medium` — bigger is more accurate and slower |
| `SAMPLE_SECONDS`    | `60`      | Length of the audio sample analyzed per file |
| `SAMPLE_OFFSET_PCT` | `25`      | Where to start sampling, as a percentage of total duration (skips intros) |
| `MIN_FREE_SPACE_MB` | `500`     | Minimum free space required in the temp directory |
| `TEMP_DIR`          | `mktemp`  | Directory for the temporary WAV samples |
| `LIMIT`             | —         | Only process the first N new files (useful for a test run) |
| `RETRY_ERRORS`      | `false`   | `true` to also reprocess rows whose previous verdict was an error |
| `NO_RESUME`         | `false`   | `true` to ignore an existing output CSV and start fresh |

Both scripts also accept `-h` / `--help`.

## Output verdicts (phase 2)

| Verdict                 | Meaning | Suggested action |
|-------------------------|---------|------------------|
| `MISTAGGED_IS_ITALIAN`  | Audio is Italian; the tag was wrong | Fix the tag / mediaInfo, rescan |
| `CONFIRMED_NOT_ITALIAN` | Audio really is not Italian | Redownload or remux an Italian track |
| `FILE_NOT_FOUND`        | Path from the phase 1 CSV is not visible on this machine | Mount the library, or run phase 2 where the files live |
| `EXTRACTION_FAILED`     | `ffmpeg` could not produce a sample | Inspect the file manually |
| `DETECTION_FAILED`      | `faster-whisper` raised on the sample | Retry with `RETRY_ERRORS=true`, or a larger model |

`DetectedLanguage` is an ISO code (`it`, `en`, `de`, …); `Confidence` is the
model's language-detection probability (`0.00`–`1.00`).

## Notes and limitations

- Language detection runs on a single ~60 s sample. Films that open with a
  long non-dialogue stretch, or that mix languages, can still fool it —
  adjust `SAMPLE_SECONDS` / `SAMPLE_OFFSET_PCT`, or bump `WHISPER_MODEL`.
- Only the **first / default** audio stream in the sample is analyzed. A file
  with an English default track plus a secondary Italian track will be
  reported as `CONFIRMED_NOT_ITALIAN` — which for "the default audio is not
  Italian" is arguably correct, but worth knowing.
- Everything is local: no audio and no metadata leave your machine.

## Adapting to another language

- **Phase 1:** change `ITALIAN_REGEX` in `scan/find-missing-italian-audio.sh`.
- **Phase 2:** change `is_italian()` in `verify/verify_audio_language.py` and
  the verdict strings.

## License

[MIT](LICENSE) © 2026 Giovanni Solone

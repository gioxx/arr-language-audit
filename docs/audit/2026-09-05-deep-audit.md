# Deep audit — quality, simplicity, effectiveness, security, maintainability

Date: 2026-09-05 · Baseline: `main` @ `3c673b0` · Branch: `perf/deep-audit-hardening`

Five independent reviews were run over every source file (security, correctness,
maintainability, performance, test strategy). Findings marked **[repro]** were
reproduced by running code, not inferred. This document is the deduplicated,
severity-ranked result; the implementation plan derived from it is in
`tasks/todo.md`.

Scope of the codebase: `arr-language-audit.sh` (orchestrator, 623 lines),
`scan/find-missing-italian-audio.sh` (phase 1, 547), `verify/verify-audio-language.sh`
(phase 2 launcher, 356), `verify/verify_audio_language.py` (438),
`verify/report.py` (524). Zero tests, no CI workflow, no lint configuration.

## 1. Critical

| # | Finding | Where | Evidence |
|---|---------|-------|----------|
| C1 | **Every untagged file is mis-parsed by phase 1.** `read` with `IFS=$'\t'` collapses consecutive tabs, so when `audioLanguages` is empty (the case the tool exists to find) the path shifts into the language column. Files whose path contains `ita` (e.g. `.ITA.` release tags) are silently treated as Italian; all others are written with an empty `Path` and end up `FILE_NOT_FOUND` in phase 2. Sonarr is masked by an accidental per-file fallback request. | `scan/find-missing-italian-audio.sh:404-416`, `:487-513` | [repro] |
| C2 | **User-supplied `TEMP_DIR` is recursively deleted at exit**, even on the "Nothing new to verify" path. The launcher's own hint tells users to set `TEMP_DIR=/path/with/space`. Contradicts the "only writes reports" promise. | `verify/verify_audio_language.py:254,364,426` | [repro] |

## 2. High

| # | Finding | Where |
|---|---------|-------|
| H1 | **Does not run on macOS stock bash 3.2** although README says it does: `mapfile` (exit 127 under `set -e`), and `"${arr[@]}"` on empty arrays under `set -u` (fatal before bash 4.4) in the launcher default path, the serve action and `ask_yesno`. | `scan:449`, `verify-audio-language.sh:351`, `arr-language-audit.sh:81,113,473` [repro] |
| H2 | **Both Python scripts crash on Python 3.9** (macOS system interpreter): PEP 604 `X \| None` annotations evaluated at `def` time. No Python floor is declared or checked anywhere. | `verify_audio_language.py:89,159`, `report.py:397,410` [repro] |
| H3 | **`FORCE_RESCAN=true` is a no-op for cached Sonarr series**: a rescan refreshes `mediaInfo` but changes neither `episodeFileCount` nor `sizeOnDisk`, so the cache hit re-emits the stale rows. The cache also has no format/regex version key. | `scan:457-469` |
| H4 | **Launcher refuses to run on the documented Debian/Ubuntu path**: it requires *system* `pip` even when faster-whisper lives in the venv; orchestrator's `PHASE2_READY` disagrees with `--check`, so "Verify" is recommended and then fails every time. | `verify-audio-language.sh:205-220,298-302`, `arr-language-audit.sh:236-238` |
| H5 | **Verdict ignores `language_probability`**: a 0.31 "en" on a music/silence window is reported as `CONFIRMED_NOT_ITALIAN` (the "re-download" verdict). Only the first 30 s of the 60 s sample reaches the encoder (`language_detection_segments=1`). | `verify_audio_language.py:145-149,411-417` |
| H6 | **Total API failure destroys the previous phase 1 CSV and reports success**: header is written before any request; on 401/network-down both branches only `warn`, `found_count` stays 0, the CSV is deleted, "No files missing Italian audio were found", exit 0. | `scan:383,398-401,433-436,541-543` |

## 3. Medium

### Security
| # | Finding | Where |
|---|---------|-------|
| S1 | `.env` is `source`d (arbitrary code execution) and the lookup includes `./.env` in the launch directory (often the media share). | `scan:155-166`, `arr-language-audit.sh:206-211` [repro] |
| S2 | `set -a` exports the API keys into every child, including ffmpeg/ffprobe/whisper that parse untrusted media. | `scan:162-165`, `arr-language-audit.sh:207-210` |
| S3 | API key on the `curl` command line (`-H "X-Api-Key: $key"`), readable via `ps`/`/proc` by any local user; six call sites. | `scan:310,325,350`, `arr-language-audit.sh:172,191,200` |
| S4 | Stored XSS: unrecognised `Verdict` values reach `innerHTML` in the summary chips (table cells correctly use `textContent`). | `report.py:212-214,250` [repro] |
| S5 | `AudioLanguages` written to the CSV without quote escaping → row smuggling into phase 2 (`Path` overridden). | `scan:412,506` [repro] |
| S6 | Report server binds `0.0.0.0` by default; `secrets.compare_digest` raises `TypeError` on a non-ASCII `?k=` from any unauthenticated client. | `report.py:499,423` [repro] |
| S7 | `python3 -c "import faster_whisper"` resolves modules from CWD (shadowable); use `-I`. | `arr-language-audit.sh:234,237`, `verify-audio-language.sh:261,263` [repro] |
| S8 | Wizard writes `.env` (with both keys) under the default umask, then `chmod 600`; values unvalidated. | `scan:274-283` |
| S9 | Orchestrator installs `faster-whisper` unpinned, ignoring `verify/requirements.txt` (pin is decorative). | `arr-language-audit.sh:429` |

### Correctness
| # | Finding | Where |
|---|---------|-------|
| R1 | Output CSV truncated before `load_model()` is known to work: an import/download failure loses every row slated for re-verification; the temp dir leaks. | `verify_audio_language.py:352-367` [repro] |
| R2 | Multi-episode files (one path, two episode rows) are corrupted on resume: `previous` is keyed by path only. | `verify_audio_language.py:171-182,304-314` [repro] |
| R3 | `FILE_NOT_FOUND` rows get a real signature stamped once the file appears and are then never auto-retried. | `verify_audio_language.py:200-206,312` [repro] |
| R4 | `--limit` drops the previous verdicts of the rows beyond the limit from the output. | `verify_audio_language.py:339-358` |
| R5 | ffmpeg samples the stream with the **most channels**, not the first/default one the README describes; a file with Italian 2.0 + English 5.1 is judged in English. | `verify_audio_language.py:116-128` |
| R6 | "No findings → delete the CSV" means a clean library can never run phase 2, stale verdicts are never dropped, and the menu recommends "scan" forever. | `scan:543`, `arr-language-audit.sh:290` |
| R7 | Phase 2 exits 0 when 100 % of files errored (e.g. mounts missing); orchestrator then recommends "Build HTML report". | `verify_audio_language.py:428-434` |
| R8 | Launcher aborts with a raw `df` error when `TEMP_DIR` does not exist yet. | `verify-audio-language.sh:314-315` [repro] |
| R9 | Config precedence inverted: `.env` is sourced *after* the environment, so `.env` (`FORCE_RESCAN=false` from the template) overrides `FORCE_RESCAN=true ./scan/…` and the orchestrator's "Force rescan? yes". Three scripts, three different `.env` lookup rules. | `scan:161-184`, `arr-language-audit.sh:206-214` |
| R10 | `./arr-language-audit.sh -h` fails on BSD sed (`extra characters at the end of p command`). | `arr-language-audit.sh:58` [repro] |

### Performance (measured on synthetic data: 2000 movies, 300 series, 15 000 episode files)
| # | Finding | Where | Measured |
|---|---------|-------|----------|
| P1 | Phase 1 spawns ~30 000 processes per run. Sonarr cache-**hit** path parses the ~1 MB `/series` payload twice per series and re-serialises the growing cache per series (O(M²)); cache-miss path runs one `grep` per episode file plus four forks per hit; Radarr loop one `grep` per movie. | `scan:363-380,404-416,449-523` | warm run **28.8 s → <0.5 s**, cold CPU **47.8 s → ~2 s**, Radarr **6.05 s → 0.19 s** with one-pass jq (byte-identical CSV verified) |
| P2 | Orchestrator pre-flight probes Radarr then Sonarr sequentially, 3 attempts × (5 s timeout + 1 s) each → up to **36 s** before the menu appears when an app is down. | `arr-language-audit.sh:171-175` | |
| P3 | Launcher runs `python3 -m pip --version` on every launch and imports faster-whisper on the system interpreter before trying the venv (1–8 s per launch on a NAS). | `verify-audio-language.sh:205-220,261-265` | |
| P4 | `WhisperModel(...)` uses CTranslate2's default 4 intra-op threads regardless of core count. | `verify_audio_language.py:142` | |
| P5 | `transcribe()` is used for detection; `detect_language(..., language_detection_segments=2)` gives the same common-case cost and better accuracy on hard files. | `verify_audio_language.py:146` | |
| P6 | Report page rebuilds the whole `<tbody>` on every keystroke; seconds per character at 15 000 rows. | `report.py:280-356` | 5.2 MB HTML, 0.07 s Python side |

## 4. Low
- `@tsv` doubles backslashes and escapes tabs; `read -r` keeps them literal → Windows-style paths corrupted. (`scan:415,511`) [repro]
- `ITALIAN_REGEX='italian|ita|it-it'` is unanchored ("Occitan" matches). (`scan:204`)
- Series title via plain `jq -r` is not newline-escaped. (`scan:452`)
- Rescan polling `curl` has no `-m`; `aborted`/`cancelled`/`orphaned` command states wait until timeout. (`scan:325`)
- No `${URL%/}` anywhere: trailing slash in `RADARR_URL` yields `//api/v3/...`.
- `.env` with CRLF line endings yields URLs ending in `\r`.
- `report.py` catches `OSError` only (non-UTF-8 CSV, port in use → traceback); non-TTY stdin stops the server immediately.
- Env vars parsed at import time (`int(os.environ.get("SAMPLE_SECONDS", "60"))` raises on empty string before `--help`).
- README: "no external service" omits the one-time Hugging Face model download; `--check` undocumented; four scripts have `-h`, README says two; no Python version stated.
- Whiptail Cancel in `ask_input` is indistinguishable from "blank"; "Run full pipeline" is not unattended.
- Terminal-escape injection via titles in log lines; CSV formula injection (`=`, `+`, `-`, `@`) — document/neutralise.
- `verify/requirements.txt` pins 1.2.1 but nothing installs from it; no git tags so `PROJECT_VERSION` is a bare hash.

## 5. Maintainability
- ~100 duplicated lines across the three bash scripts (log/warn/err ×3, repo-root resolution ×3, `.env` loading ×2 with different rules, faster-whisper detection ×2, venv recipe ×4, 23 raw `command -v`). The orchestrator re-implements the curl retry that `api_get` already has.
- Verdict strings are literals in 5 files / 3 languages (~50 sites), CSV column names at 44 sites, default report filenames at 19 sites. "Adapt to another language" = 15+ edits with no test.
- `verify_audio_language.py:main()` is 219 lines doing eight jobs; the resume/orphan planning (the most intricate logic in the repo) is not callable without I/O.
- Phase 1 is 547 top-level lines with functions interleaved between executable blocks, no `main()`, not sourceable; globals mutated as out-parameters.
- 280-line HTML/CSS/JS string inside `report.py`; the JS duplicates the Python constants.
- Bilingual README in one file: every edit ×2, already drifting.
- shellcheck: 1 warning (unused `attempt`), 10 style. ruff (strict): unused `import html`, blind excepts, `subprocess.run` without `check`, naive `datetime.now()`.

## 6. What is done well (preserve)
- jq: every dynamic value goes through `--arg`/`--argjson`; no filter interpolation.
- curl: `-f` everywhere, `-m` on all but the two poll calls, no `-L`, no `-k`, key in a header.
- Bash: `set -euo pipefail` in the workers, arrays for argv, `rm -f --`, `read -r`, `printf -v`, no `eval`; the 3.2-safe `${arr[@]+"${arr[@]}"}` idiom is already used in two places.
- Python: no `shell=True`; `isfile()` gate before ffmpeg defeats protocol tricks; timeouts on both subprocesses; incremental CSV writes with `flush()` so Ctrl-C leaves a valid file; size+mtime re-verification; the orphan rule (drop only when the file provably changed).
- Report: cells via `textContent`, `</` neutralised in the JSON blob, no external resources, one in-memory payload (no traversal), 128-bit token with constant-time compare, token stripped from logs, clean shutdown.
- Phase 2 pipeline: model loaded once and lazily, detection-only (`transcribe()` generator never consumed), int8, VAD, `-ss` before `-i`, 16 kHz mono.
- `.gitignore` covers every secret/output path (verified with `git check-ignore`); no secrets in history.

## 7. Decisions taken for the remediation
1. **Compatibility floors: bash ≥ 3.2 and Python ≥ 3.9.** The README promises macOS, and stock macOS ships exactly those. CI runs the bats suite under `/bin/bash` on `macos-latest` to enforce it. No associative arrays, no `mapfile`, no `${var,,}`; `from __future__ import annotations` in every Python module.
2. **Shared code lives in `lib/common.sh` (bash) and `verify/audit_common.py` (Python).** One `.env` loader with the precedence `flag > environment > .env > default`, one logger, one `arr_get` curl wrapper (key via stdin), one faster-whisper detector. Constants (verdicts, CSV columns, default paths) defined once per language with a drift test asserting bash == Python.
3. **Phase 1 becomes a single jq pass per payload**, emitting CSV rows and cache entries directly from jq (custom quoting def, not `@csv`, to keep the exact current row format). Output goes to a temp file and is renamed at the end.
4. **Phase 2 gets a pure planning function** (`plan_rows(...)`) separated from I/O, keyed on `(path, episode)`, with a `LOW_CONFIDENCE` verdict below `MIN_CONFIDENCE` (default 0.6), `-map 0:a:0`, `detect_language` API, `cpu_threads = os.cpu_count()`.
5. **Tests: bats-core for bash, pytest for Python**, no network, no ffmpeg, no whisper: PATH shims for `curl`/`ffmpeg`/`ffprobe`, a fixture-driven fake Radarr/Sonarr HTTP server, and a stub `faster_whisper` package on `PYTHONPATH`. CI matrix: ubuntu + macOS, Python 3.9 + 3.12, shellcheck + ruff.

Out of scope for this branch (flagged, not done): splitting the bilingual README into two files, carrying `mediaInfo.runTime` from phase 1 to drop ffprobe, parallel `curl -Z` for Sonarr cache misses, a sample-prefetch thread in phase 2. Each is a separate PR.

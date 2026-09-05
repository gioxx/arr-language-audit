# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project has no released versions yet, so everything lives under
Unreleased.

## [Unreleased]

### Added

- A contract test executes the pinned faster-whisper decoder, feature extractor
  and detection method without model weights. `scripts/test.sh contract` and
  Linux CI on Python 3.9/3.12 keep the fake-backed tests honest.

- Report interaction tests execute the generated JavaScript in jsdom: keyboard
  controls, filtering, sorting, clipboard failures and the large-report cap.
  `scripts/test.sh ui` and a Linux CI job run the test-only Node.js environment.

- `lib/common.sh`: one shared implementation of the `.env` loader, the logger,
  the `curl` wrapper for the Radarr/Sonarr API and the phase 2 interpreter
  discovery, used by all three shell entry points.
- `verify/audit_common.py`: the verdict names, CSV columns and default paths
  defined once for the Python side, with a test asserting the bash and Python
  copies have not drifted apart.
- `verify/verify_audio_language.py`: new `LOW_CONFIDENCE` verdict for a
  detection whose probability is below `MIN_CONFIDENCE` (default `0.6`), so a
  low-confidence guess no longer masquerades as `CONFIRMED_NOT_ITALIAN`.
- `verify/verify_audio_language.py`: `WHISPER_THREADS` sets the model's CPU
  threads; it defaults to every core instead of faster-whisper's own default.
- `verify/verify-audio-language.sh`: `PYTHON_BIN` names the interpreter to run
  phase 2 with; one that cannot import `faster_whisper` is reported and
  ignored rather than used silently.
- `verify/verify-audio-language.sh`: `--check` verifies the environment and
  exits without verifying any file, and is accepted in any argument position.
- `arr-language-audit.sh`: `ARR_PLAIN_MENU` forces the plain numbered menu
  even when `whiptail` is installed.
- `verify/verify_audio_language.py`: exit code `3` when every file this run
  tried to verify errored, and `130` on Ctrl-C; the launcher passes both
  through, and the orchestrator reports the `3` on screen instead of letting
  it pass unnoticed.
- `verify/report.py`: the table renders at most 2000 rows and offers a
  *Show all N rows* button for the rest, so a large library still opens.
- `scan/find-missing-italian-audio.sh`, `lib/common.sh`: `ALA_DOTENV_FILE`
  replaces the `.env` search with the file it names.
- `scan/find-missing-italian-audio.sh`: `RESCAN_POLL_INTERVAL` (default `5`)
  sets how often a queued rescan is polled.
- Test suite and CI: bats-core for the shell scripts and pytest for the Python
  modules, both hermetic; `scripts/test.sh {lint|py|bats|ui|contract|all}` is the single
  entry point locally, and `.github/workflows/ci.yml` runs lint through it and
  the two suites directly, on Linux and macOS, across Python 3.9, 3.12 and
  3.13.
- `CHANGELOG.md` and `docs/adr/` (compatibility floors, test harness, phase 1
  single pass and cache v2).

### Changed

- `scan/find-missing-italian-audio.sh`: with zero findings the report is still
  written, with its header row and nothing else, instead of being left absent.
- `scan/find-missing-italian-audio.sh`: exit `2` when an enabled app could not
  be listed after retries; the temporary file is discarded so a previous
  report survives untouched.
- `scan/find-missing-italian-audio.sh`: `FORCE_RESCAN=true` now implies
  `REFRESH=true` — a rescan can change the tags without changing a series'
  signature, and a cache hit would hide exactly what the rescan was for.
- `scan/find-missing-italian-audio.sh`: `RESCAN_TIMEOUT` default raised from
  `300` to `900` seconds; a rescan reporting failed, aborted, cancelled or
  orphaned is no longer waited out at all.
- `scan/find-missing-italian-audio.sh`: each API payload is now processed in a
  single `jq` pass that emits CSV rows and cache entries directly, with a US
  (`\x1f`) field separator between jq and bash.
- `scan/find-missing-italian-audio.sh`: the Sonarr cache is at schema
  version 3: its metadata includes the source Sonarr URL and regex, and entries
  include series identity and original media paths. Missing statistics or
  malformed cache records force a refresh. Switching instances or renaming a
  series can no longer reuse unrelated rows.
- `scan/find-missing-italian-audio.sh`: the report is written to
  `<OUTPUT_CSV>.tmp.<random>` using `mktemp` and renamed into place, so a
  reader never sees a partial file. Report and cache retain private `0600` modes.
- `verify/verify_audio_language.py`: resume is keyed on `(path, episode)`
  rather than on the path alone, so a file holding a double episode keeps one
  verdict per row; an episode phase 1 relabels carries its verdict over, and
  the superseded row is dropped.
- `verify/verify_audio_language.py`: the rows `--limit` cuts keep the verdict
  they already had, so a limited run no longer empties out the report.
- `verify/verify_audio_language.py`: `--retry-errors` also retries
  `LOW_CONFIDENCE` rows.
- `verify/verify_audio_language.py`: the audio stream the container marks as
  default is sampled (else the first one), rather than whatever ffmpeg
  happened to pick.
- `verify/verify_audio_language.py`: language detection uses faster-whisper's
  `detect_language` API with the VAD filter and up to two windows, falling
  back to `transcribe()` on a package too old for it — previously only the
  first 30 s of a 60 s sample reached the decision.
- `verify/verify_audio_language.py`, `verify/verify-audio-language.sh`:
  `TEMP_DIR` is the **parent** of the run's scratch directory; a private
  `lang-check-*` directory is created inside it and only that one is removed.
- `verify/verify-audio-language.sh`: the phase 2 interpreter is chosen
  venv-first — `PYTHON_BIN`, then `verify/venv/bin/python`, then the system
  `python3` — and must be Python 3.9 or newer, checked in the pre-flight
  rather than halfway through a run.
- `verify/report.py`: `--serve` binds `127.0.0.1` by default instead of
  `0.0.0.0`; `--host 0.0.0.0` exposes the report on the LAN, and the
  orchestrator asks before doing so.
- `README.md`, `.env.example`: documented the `.env` lookup order and
  precedence, the new variables and verdict, the exit codes of every script,
  and a Development section covering the test harness and CI.

### Fixed

- The faster-whisper 1.2.1 detection API receives a decoded 16 kHz float32
  waveform instead of a WAV filename. Passing the path directly failed with
  the real package while the earlier fake silently accepted it.

- Phase 1 treats failed episode/file requests and invalid response schemas as
  incomplete scans, preserving previous reports and cache. Rescan status-polling
  calls and sleeps use the remaining timeout; the initial POST uses
  `ARR_TIMEOUT`. Decimal limits are validated.
- The pipeline stops after a failed or cancelled stage. Preflight rejects
  non-status HTTP responses; reconfiguration edits the active dotenv file;
  report generation preserves its real exit status.
- Worker CSV inputs and resume files are validated before publication; invalid
  numbers, probabilities and detector results fail explicitly. Pending previous
  verdicts survive controlled interrupts, including relabels deferred by LIMIT.
  New file signatures preserve subsecond precision without inventing precision
  for legacy results. Failed extractions immediately remove partial samples.
- The report substitutes template placeholders once, preserving identical text
  in titles and paths. Unknown verdicts named `__proto__` or `constructor` render
  normally. Invalid CSV and port arguments fail before replacing HTML.
- Report filters and sorting are keyboard-operable buttons with announced state.
  Copy uses the current filter even during debounce, removes duplicate paths,
  includes filtered rows beyond the display cap, and offers selected text for
  manual copying if clipboard access is absent or denied.

- `verify/report.py`: a CSV that the `csv` module cannot parse is reported
  with a clean `could not parse` message and exit 1 instead of a traceback.
- `scan/find-missing-italian-audio.sh`: an empty `audioLanguages` value no
  longer shifts the file path into the language column of the CSV.
- `scan/find-missing-italian-audio.sh`: the wizard validates what it is given
  — the URL must be `http://` or `https://` with no whitespace and the API key
  letters and digits only — instead of writing an unusable `.env`.
- `verify/verify_audio_language.py`: an error row carrying no file signature
  (typically `FILE_NOT_FOUND` from a run where the share was not mounted) is
  retried as soon as the file is visible again, and is never stamped with a
  signature it was not verified against.
- `verify/verify_audio_language.py`: the model is loaded before the output CSV
  is opened, so a missing package or a failed model download no longer
  truncates the previous run's verdicts.
- `arr-language-audit.sh`, `scan/find-missing-italian-audio.sh`,
  `verify/verify-audio-language.sh`: bash 3.2 compatibility, so the scripts
  run under the `/bin/bash` that stock macOS ships.
- `arr-language-audit.sh`: whether phase 2 can run is decided by
  `verify-audio-language.sh --check` alone, so the menu and the launcher can
  no longer disagree.
- `arr-language-audit.sh`: the pre-flight queries Radarr and Sonarr in
  parallel with a single attempt each, so two unreachable apps no longer add
  minutes to startup.

### Security

- API requests ignore `.curlrc` to prevent extra destinations from inheriting
  API keys; keys containing CR/LF are refused. Interpreter probes and setup
  subprocesses run without Arr credentials, as do directly invoked media tools.
- Temporary report paths are unpredictable; output guards reject destinations
  aliasing input CSV or enumerated media, including symlinks, hardlinks and
  filenames containing whitespace. HTML and initial worker snapshots are
  published atomically, preserving prior output when preparation fails.

- `verify/report.py`: every `<` inside the JSON embedded in the page is
  written as `\u003c`, so a title containing `<!--` or `<script` can neither
  break the page nor close the script block.
- `verify/report.py`: the access token is compared in constant time with
  `hmac.compare_digest` on bytes; a non-ASCII `?k=` now gets a 403 instead of
  a server-side exception.
- `lib/common.sh`: the `.env` file is parsed, never sourced or `eval`'d, and
  only allow-listed keys are set — a `.env` can no longer reach `PATH`,
  `LD_PRELOAD` or `IFS`, nor execute anything. Values are not shell-expanded.
- `lib/common.sh`: the working directory is no longer searched for a `.env`,
  so running the audit from a directory someone else can write cannot change
  its configuration.
- `lib/common.sh`: the Radarr/Sonarr API key reaches `curl` through a
  `--config` file on stdin instead of on argv, where `ps` exposed it to every
  user on the machine for the duration of the request.
- `arr-language-audit.sh`, `verify/verify-audio-language.sh`:
  `RADARR_API_KEY` and `SONARR_API_KEY` are removed from the environment of
  `ffmpeg`, whisper and the report, which have no use for them.
- `scan/find-missing-italian-audio.sh`: values crossing the jq/bash boundary
  are scrubbed of the US separator and of the whitespace bytes that break a
  line-oriented reader, so no title, path or language tag can forge a field
  boundary; a malformed `.env` line is reported by line number only, never by
  content.
- `verify/report.py`: served responses carry `Cache-Control: no-store`,
  `Referrer-Policy: no-referrer` and `X-Content-Type-Options: nosniff`.

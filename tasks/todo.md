# Deep-audit remediation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the audit findings in `docs/audit/2026-09-05-deep-audit.md` into shipped fixes, with a real test suite and CI, on branch `perf/deep-audit-hardening`, ending in a draft PR.

**Architecture:** Shared code moves into `lib/common.sh` (bash) and `verify/audit_common.py` (Python). Phase 1 becomes one jq pass per API payload with a US (`\x1f`) field separator. Phase 2 separates a pure planning function from I/O. Tests are bats-core (bash, black-box against a fake Radarr/Sonarr HTTP server and PATH shims) and pytest (Python, with a stub `faster_whisper` package). CI runs on ubuntu + macOS and forces `/bin/bash` 3.2 on macOS.

**Tech Stack:** bash ≥ 3.2, jq ≥ 1.6, curl, Python ≥ 3.9 (stdlib only in product code), faster-whisper 1.2.1 (runtime only), bats-core 1.x + bats-support/bats-assert, pytest via `uvx`, ruff via `uvx`, shellcheck, GitHub Actions.

**Spec:** `docs/audit/2026-09-05-deep-audit.md` (findings + decisions) and `docs/audit/2026-09-05-test-strategy.md` (test IDs S*, V*, Y*, R*, O*, L*; seams; harness). Test IDs in this plan refer to that document; the one-line assertion is repeated here so a task can be executed without opening it.

## Global Constraints

- **bash ≥ 3.2**: no `mapfile`/`readarray`, no `declare -A`, no `${var,,}`/`${var^^}`, no `|&`, no `&>>`, no `local -n`. Every possibly-empty array expands as `${arr[@]+"${arr[@]}"}`. All bats tests run scripts with `"$BASH_UNDER_TEST"` (default `/bin/bash`).
- **Python ≥ 3.9**: every module starts with `from __future__ import annotations`; no `match`, no `X | Y` outside annotations, no `zip(strict=)`. `pyproject.toml` sets `target-version = "py39"`.
- **No new runtime dependencies.** Product Python is stdlib only. Nothing is `pip install`ed or `npm install`ed by the plan; test tooling comes from `uvx` and Homebrew/apt (`bats`, `shellcheck`).
- **No network in tests**, no ffmpeg, no whisper model. Fakes only. Fixtures are synthetic (invented titles, `/media/...` paths, dummy keys).
- **Behaviour contracts to keep**: phase 1 CSV header `App,Title,Year,Episode,AudioLanguages,Path`; row shapes `Radarr,"T",Y,,"AL","P"` and `Sonarr,"T",,"S01E02 - t","AL","P"` (quote doubling in every quoted field, `Year`/`Episode` empty slots unquoted); phase 2 CSV columns `App,Title,Year,Episode,DeclaredAudioLanguages,DetectedLanguage,Confidence,Verdict,Path,FileSize,FileMtime`; existing verdict names unchanged; stdout of phase 1 carries only `[Radarr] …`/`[Sonarr] …` hit lines, diagnostics on stderr.
- **Behaviour changes decided** (document in README, both languages): phase 1 keeps a header-only CSV on zero findings (was: deleted); phase 1 exit code 2 when an enabled app failed to fetch (old CSV preserved); `FORCE_RESCAN=true` implies `REFRESH=true`; `.env` is parsed, never sourced, looked up in `<repo>/.env` then `<repo>/scan/.env` (CWD dropped), precedence `CLI flag > environment > .env > default`; new verdict `LOW_CONFIDENCE` (below `MIN_CONFIDENCE`, default `0.6`); `report.py --serve` binds `127.0.0.1` by default; phase 2 exit code 3 when every file this run errored; `TEMP_DIR` is the *parent* of a private `lang-check-*` directory.
- **Repo language**: everything committed is English. Commits: `type(scope): imperative subject` ≤ 72 chars, one logical change each. No `composer`/`npm`.
- **Done means**: `scripts/test.sh all` green (shellcheck, ruff, bats under `/bin/bash`, pytest on 3.9 and 3.12), output shown.
- **Parallel tasks do not run `git commit`**; the lead commits after review. Sequential tasks may commit as written.

---

## Dependency graph

```
T1 harness ──┬─► T2 report.py ──────────────────────────┐
             ├─► T3 verify worker: safety ─► T4 resume ─► T5 detection quality ─┤
             └─► T6 lib/common.sh ─┬─► T7 phase 1 rewrite ─► T8 phase 1 robustness ─┤
                                   ├─► T9 launcher ────────────────────────────────┤
                                   └─► T10 orchestrator (after T9) ────────────────┤
                                                                                   ▼
                                                              T11 docs + ADRs ─► T12 verify all, fork, draft PR
```
T2, T3→T4→T5, T6→T7→T8, T9 can run in parallel (disjoint files). T10 needs T6 and T9. T11 needs everything.

---

### Task 1: Test harness, lint gates, fakes, CI

**Files:**
- Create: `tests/bats/helpers/common.bash`, `tests/bats/helpers/fake_arr.bash`, `tests/bats/helpers/shims.bash`
- Create: `tests/bats/fakes/bin/{ffmpeg,ffprobe,python3,df,uname,whiptail,apt,recorder}` (executable, bash 3.2-safe)
- Create: `tests/fakes/fake_arr_server.py`, `tests/fakes/pypath/faster_whisper/__init__.py`
- Create: `tests/bats/fixtures/radarr/{system_status.json,movies.json,movies_all_italian.json,movies_edge_cases.json,rootfolder.json,health.json}`, `tests/bats/fixtures/sonarr/{system_status.json,series.json,series_changed_size.json,episodes_1.json,episodes_2.json,episodefile_77.json}`
- Create: `tests/bats/harness.bats` (smoke tests for the fakes), `tests/bats/lint.bats` (L3, L4, L6)
- Create: `tests/python/conftest.py`, `tests/python/test_harness.py`
- Create: `verify/audit_common.py`
- Create: `pyproject.toml`, `.shellcheckrc`, `scripts/test.sh`, `.github/workflows/ci.yml`
- Modify: `.gitignore` (add `.pytest_cache/`, `.ruff_cache/`, and un-ignore fixtures: `!tests/**/*.csv`, `!tests/**/*.html`), `.github/dependabot.yml` (no change needed — `github-actions` entry already exists; verify)
- Modify: `arr-language-audit.sh:171` (`attempt` → `_attempt` so SC2034 goes away), `:199` (SC2015 → `if … then … else … fi`), `verify/report.py:41` (remove unused `import html`), `:385` (`datetime.datetime.now(datetime.timezone.utc).astimezone()`), `verify/verify_audio_language.py:91-99` (`check=False` explicit)

**Interfaces produced (used by every later task):**
- `tests/bats/helpers/common.bash`: sets `ROOT` (repo root), `BASH_UNDER_TEST="${BASH_UNDER_TEST:-/bin/bash}"`, loads `bats-support` + `bats-assert` from `$BATS_LIB_PATH` or Homebrew `$(brew --prefix)/lib`, defines `make_bin` (creates `$BATS_TEST_TMPDIR/bin`, sets `PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin"`), `wait_for_file <path> [seconds]`, `write_csv <path> <lines...>` (CRLF line endings, like `csv.DictWriter`).
- `tests/bats/helpers/fake_arr.bash`: `start_fake_arr <fixture-dir>` (exports `FAKE_ARR_PORT`, `RADARR_URL=http://127.0.0.1:$PORT/radarr`, `SONARR_URL=…/sonarr`, `RADARR_API_KEY=radarr-key`, `SONARR_API_KEY=sonarr-key`, `FAKE_ARR_LOG`, `FAKE_ARR_CONTROL`), `stop_fake_arr`, `arr_requests <jq-filter>` (prints matching JSONL log entries), `arr_request_count <path-substring>`, `arr_control <json>` (overwrites the control file).
- `tests/bats/helpers/shims.bash`: `install_shim <name>...` copies from `tests/bats/fakes/bin/` into `$BATS_TEST_TMPDIR/bin`; `install_recorder <target-path>` installs the generic recorder at an arbitrary path (used as fake `SCAN_SH`/`VERIFY_SH`).
- Fake server routes and control file exactly as `docs/audit/2026-09-05-test-strategy.md` §3.3: `X-Api-Key` must match `FAKE_RADARR_KEY`/`FAKE_SONARR_KEY` (defaults `radarr-key`/`sonarr-key`) else 401; `/ping` unauthenticated `{"status":"OK"}`; `GET /<app>/api/v3/{system/status,movie,series,rootfolder,health}` → fixture file; `GET /<app>/api/v3/episode?seriesId=N&includeEpisodeFile=true` → `episodes_N.json`; `GET /<app>/api/v3/episodefile/N` → `episodefile_N.json`; `POST /<app>/api/v3/command` → `{"id":42,"status":"queued"}`; `GET /<app>/api/v3/command/42` → `{"id":42,"status":<next of control.command_status, last repeats>}`; control `fail_count` map path→remaining 500s; control `crlf: true` appends `\r\n` to bodies; log JSONL `{"method","path","query","key_ok","body"}` appended per request; port written to `$FAKE_ARR_PORTFILE`.
- Shim contracts exactly as §3.4 (`FAKE_DURATIONS`, `FAKE_FFMPEG_FAIL`, `FAKE_FFMPEG_LOG`, `FAKE_PY_VERSION`, `FAKE_PY_HAS_PIP`, `FAKE_PY_VENV_OK`, `FAKE_PY_HAS_FW`, `FAKE_PY_ARGLOG`, `FAKE_PY_EXIT`, `FAKE_DF_AVAIL_MB`, `FAKE_UNAME`, `FAKE_WT_OUT`, `FAKE_WT_RC`, `FAKE_WT_LOG`, `RECORDER_LOG`). The `ffmpeg` shim writes a valid 44-byte RIFF/WAVE header (16 kHz mono s16le) followed by `FAKEWAV:<input path>\n` to its last argument. The `python3` shim must also answer `-I -c "import faster_whisper"` (the `-I` flag is added in T6/T9) and `-c 'import sys; print(...)'` version probes: any `-c` argument containing `version_info` prints `${FAKE_PY_VERSION%.*}` for major.minor probes and `Python $FAKE_PY_VERSION` for `--version`; any `-c` containing `sys.version_info >= (3, 9)` exits 0 iff `FAKE_PY_VERSION` ≥ 3.9.
- Fake `faster_whisper.WhisperModel` exactly as §3.5 **plus** `detect_language(self, audio=None, vad_filter=False, language_detection_segments=1, language_detection_threshold=0.5, **kw)` returning `(language, probability, [])` using the same script lookup (`FAKE_WHISPER_SCRIPT` JSON: `{"<media path>": ["it", 0.97] | "RAISE", "*": ["en", 0.9]}`; a scripted `[null, 0.0]` returns `(None, 0.0)`). Class attributes `instances` and `calls` record constructor args and media paths.
- `verify/audit_common.py`:
  ```python
  from __future__ import annotations
  import sys
  from pathlib import Path
  MIN_PYTHON = (3, 9)
  REPO_ROOT = Path(__file__).resolve().parent.parent
  REPORTS_DIR = REPO_ROOT / "reports"
  PHASE1_CSV = REPORTS_DIR / "missing-italian-audio.csv"
  PHASE2_CSV = REPORTS_DIR / "verified-language-results.csv"
  REPORT_HTML = REPORTS_DIR / "verified-language-results.html"
  PHASE1_COLUMNS = ["App", "Title", "Year", "Episode", "AudioLanguages", "Path"]
  PHASE2_COLUMNS = ["App", "Title", "Year", "Episode", "DeclaredAudioLanguages", "DetectedLanguage", "Confidence", "Verdict", "Path", "FileSize", "FileMtime"]
  VERDICT_MISTAGGED = "MISTAGGED_IS_ITALIAN"
  VERDICT_CONFIRMED = "CONFIRMED_NOT_ITALIAN"
  VERDICT_LOW_CONFIDENCE = "LOW_CONFIDENCE"
  VERDICT_FILE_NOT_FOUND = "FILE_NOT_FOUND"
  VERDICT_EXTRACTION_FAILED = "EXTRACTION_FAILED"
  VERDICT_DETECTION_FAILED = "DETECTION_FAILED"
  ERROR_VERDICTS = frozenset({VERDICT_FILE_NOT_FOUND, VERDICT_EXTRACTION_FAILED, VERDICT_DETECTION_FAILED})
  RETRYABLE_VERDICTS = ERROR_VERDICTS | {VERDICT_LOW_CONFIDENCE}
  ALL_VERDICTS = [VERDICT_MISTAGGED, VERDICT_CONFIRMED, VERDICT_LOW_CONFIDENCE, VERDICT_FILE_NOT_FOUND, VERDICT_EXTRACTION_FAILED, VERDICT_DETECTION_FAILED]
  # label + css class used by report.py; the JS reads this as JSON
  VERDICT_META = {
      VERDICT_MISTAGGED: {"cls": "badge-ok", "label": "Mistagged (is Italian)"},
      VERDICT_CONFIRMED: {"cls": "badge-bad", "label": "Confirmed not Italian"},
      VERDICT_LOW_CONFIDENCE: {"cls": "badge-warn", "label": "Low confidence"},
      VERDICT_FILE_NOT_FOUND: {"cls": "badge-warn", "label": "File not found"},
      VERDICT_EXTRACTION_FAILED: {"cls": "badge-warn", "label": "Extraction failed"},
      VERDICT_DETECTION_FAILED: {"cls": "badge-warn", "label": "Detection failed"},
  }
  def log(msg: str) -> None:
      print(msg, file=sys.stderr)
  def check_python_floor() -> None:
      if sys.version_info < MIN_PYTHON:
          log(f"ERROR: Python {MIN_PYTHON[0]}.{MIN_PYTHON[1]}+ is required, found {sys.version.split()[0]}.")
          sys.exit(1)
  ```
- `pyproject.toml`: `[tool.ruff] target-version = "py39"`, `line-length = 110`, `[tool.ruff.lint] select = ["E","F","W","I","UP","B","SIM","PL","RUF","DTZ","BLE","S"]`, `ignore = ["PLR0913","PLR0912","PLR0915","PLR2004","S603","S607","S310"]`, per-file `tests/**: ["S101","S108","PLR2004","BLE001"]`; `[tool.pytest.ini_options] testpaths = ["tests/python"]`, `pythonpath = ["verify", "tests/python", "tests/fakes/pypath"]`.
- `.shellcheckrc`: `shell=bash`, `external-sources=true`, `source-path=SCRIPTDIR`, `source-path=SCRIPTDIR/..`, `disable=SC1090,SC1091`.
- `scripts/test.sh {lint|bats|py|all}`: `lint` = `shellcheck -S warning arr-language-audit.sh scan/*.sh verify/*.sh lib/*.sh tests/bats/fakes/bin/* tests/bats/helpers/*.bash` + `uvx ruff check .`; `bats` = `PATH="/bin:/usr/bin:$PATH" BASH_UNDER_TEST=/bin/bash bats -r tests/bats`; `py` = `uvx --python 3.12 pytest -q` then `uvx --python 3.9 pytest -q` (skip 3.9 with a warning if `uv python find 3.9` fails); `all` = lint, py, bats. Exit non-zero on the first failure; print a summary line per stage.
- `.github/workflows/ci.yml` as §3.6 with these corrections: pytest matrix `python: ["3.9", "3.12", "3.13"]`; bats job uses `bats-core/bats-action@3.0.1` on both OSes and runs `PATH="/bin:/usr/bin:$PATH" bats -r tests/bats` with `BASH_UNDER_TEST=/bin/bash`; lint job runs `shellcheck` from apt and `uvx ruff check .`; on macOS install `jq` only if missing.

- [ ] **Step 1: Write the harness smoke tests first** (`tests/bats/harness.bats`): (a) `start_fake_arr` then `curl -sf -H 'X-Api-Key: radarr-key' "$RADARR_URL/api/v3/system/status"` returns the fixture JSON and the log has one entry with `key_ok: true`; (b) wrong key → HTTP 401 (`curl -s -o /dev/null -w '%{http_code}'`); (c) `arr_control '{"fail_count":{"/radarr/api/v3/movie":1}}'` → first GET 500, second 200; (d) `install_shim ffmpeg` then `ffmpeg -y -ss 0 -i /media/x.mkv -t 60 -vn out.wav` writes a file whose first 4 bytes are `RIFF` and which contains `FAKEWAV:/media/x.mkv`; (e) `install_shim python3` with `FAKE_PY_VERSION=3.9.6` → `python3 --version` prints `Python 3.9.6`; (f) `install_shim df` with `FAKE_DF_AVAIL_MB=42` → `df -Pm /x | tail -1 | awk '{print $4}'` prints 42. `tests/python/test_harness.py`: (g) `import faster_whisper; m = faster_whisper.WhisperModel("small", device="cpu", compute_type="int8"); m.detect_language(audio=<fake wav written by hand>)` returns the scripted tuple; `m.transcribe(wav)[1].language` too; the segments generator raises if iterated; (h) `import audit_common` and `len(audit_common.PHASE2_COLUMNS) == 11`.
- [ ] **Step 2: Write `tests/bats/lint.bats`**: L3 `no bash 4 builtins in product scripts` — `grep -nE 'mapfile|readarray|declare -A|\$\{[A-Za-z_]+(,,|\^\^)|\|&|&>>|local -n' arr-language-audit.sh scan/*.sh verify/*.sh lib/*.sh` (lib may not exist yet: use `2>/dev/null`) finds nothing — **this is RED until Task 7**; mark it `skip "fixed in Task 7"` for now and un-skip in Task 7. L4 `bats runs under bash 3 on macOS` — `[[ "${RUNNER_OS:-}" != "macOS" ]] || [[ ${BASH_VERSINFO[0]} -eq 3 ]]`. L6 `--help exits 0 and prints Usage for scan and launcher` (orchestrator `-h` is RED until T10: skip it here with a note).
- [ ] **Step 3: Run the smoke tests, expect failures** (`bats tests/bats/harness.bats`; `uvx --python 3.12 pytest tests/python/test_harness.py`): helpers/fakes missing.
- [ ] **Step 4: Implement** helpers, fake server, shims, fake whisper, fixtures, `audit_common.py`, `pyproject.toml`, `.shellcheckrc`, `scripts/test.sh`, CI workflow, `.gitignore` changes. Fixture content: `movies.json` = 6 movies covering `Italian`, `ita`, `it-IT`, `English / Italian`, `English`, `Japanese / English`; `movies_edge_cases.json` = `audioLanguages: null` with path `/media/Italian Movies/null-tag.mkv`, missing `year`, `hasFile: false`, missing `mediaInfo`, title `Hello, "World"` with path `/m/a, "b".mkv`, path `\\nas\share\a.mkv`, title `A\tB\nC`, tag `Occitan`; `movies_all_italian.json` = 2 Italian movies; `series.json` = series 1 (`statistics.episodeFileCount: 10, sizeOnDisk: 123456`) and series 2; `series_changed_size.json` = same with series 1 `sizeOnDisk: 999999`; `episodes_1.json` = 4 episodes: Italian tag, English tag, `title: ""` + `audioLanguages: ""`, `hasFile: true` with `episodeFileId: 77` and no `episodeFile`; `episodes_2.json` = one English episode; `episodefile_77.json` = `{"id":77,"path":"/tv/s/S01E04.mkv","mediaInfo":{"audioLanguages":"German"}}`; `system_status.json` = `{"version":"4.0.0.1234","instanceName":"Radarr"}` / Sonarr; `rootfolder.json`, `health.json` small.
- [ ] **Step 5: Fix the four existing lint findings** listed under Files so `shellcheck -S warning` and `uvx ruff check .` are clean (add `# noqa` only where the rule is wrong for this code, with a reason).
- [ ] **Step 6: Run** `scripts/test.sh lint && bats tests/bats/harness.bats tests/bats/lint.bats && uvx --python 3.12 pytest -q && uvx --python 3.9 pytest -q` — all green (L3 and orchestrator `-h` skipped).
- [ ] **Step 7: Commit** (`chore(tests): add bats/pytest harness, fakes, lint gates and CI`).

---

### Task 2: `verify/report.py` hardening

**Files:**
- Modify: `verify/report.py`
- Test: `tests/python/test_report.py`

**Interfaces:**
- Consumes: `audit_common.{PHASE2_COLUMNS, VERDICT_META, ALL_VERDICTS, log, check_python_floor, PHASE2_CSV}`.
- Produces: `read_rows(csv_path) -> list[dict]` (raises `ReportError(msg)` instead of `sys.exit`; `main` maps it to exit 1), `build_html(rows, csv_path, generated=None) -> str`, `make_handler(payload: bytes, token: str | None)`, `serve(html_text, host, port, use_token) -> None`, `main(argv: list[str] | None = None) -> int`. Template constants: `__DATA_JSON__`, `__SRC_JSON__`, `__GEN_JSON__`, `__VERDICT_META_JSON__` (new), `__COLUMNS_JSON__` (new: the display columns = `PHASE2_COLUMNS` minus `FileSize`, `FileMtime`).

- [ ] **Step 1: Write RED tests** R1 (`</script>` in a title → `html.count("</script>") == 1` and `<\/script>` present and `DATA` blob `json.loads` == rows), R2 (unicode/escape round-trip incl. ` `, `è` literal), R3 (static: `"innerHTML" not in HTML_TEMPLATE`; the chips are built with `textContent` and a child `<span class="n">`), R4 (column normalisation with a CRLF CSV), R5 (`read_rows` on a missing file → `ReportError`; `main([missing])` returns 1 and prints `input CSV not found`), R6 (`main([csv])` writes `x.html`; `-o` honoured), R7 (handler: `/`→403, `/?k=wrong`→403, `/?k=<token>`→200 with body == payload, `Content-Length`, `Content-Type: text/html; charset=utf-8`, `Cache-Control: no-store`, `Referrer-Policy: no-referrer`, `/anything?k=<token>`→200), R8 (`/?k=%C3%A9` → 403, no `Traceback` in stderr), R9 (`token=None` serves without `k`), R10 (`/favicon.ico`, `/robots.txt` → 204 without token), R11 (`log_message` never echoes the token), R12 (`serve(html, "127.0.0.1", 0, True)` returns when `input` yields `""` and the port is free again), R13 (stderr contains `http://127.0.0.1:<port>/?k=` and `treat the URL as sensitive`), R14 (no `<script src=`, `<link `, `http://`/`https://` in `<head>`), plus new: R15 `main(["--serve"])` default host is `127.0.0.1` (assert via `argparse` defaults: `build_parser().get_default("host") == "127.0.0.1"`), R16 non-UTF-8 CSV → `ReportError` mentioning encoding, R17 port already in use → `main` returns 1 with a message (bind a socket first), R18 unknown verdict in CSV renders (build_html succeeds) and the verdict meta JSON injected equals `VERDICT_META`.
- [ ] **Step 2: Run** `uvx --python 3.12 pytest tests/python/test_report.py -q` → failures.
- [ ] **Step 3: Implement**: `from __future__ import annotations`; import constants from `audit_common`; `ReportError`; `read_rows` catches `OSError` and `UnicodeDecodeError`; `build_html(rows, csv_path, generated=None)` uses `datetime.datetime.now(datetime.timezone.utc).astimezone().strftime(...)` when `generated is None`; inject `VERDICT_META` and display columns as JSON (same `js()` neutraliser); JS: `const VERDICTS = __VERDICT_META_JSON__; const COLS = __COLUMNS_JSON__.map(...)` keeping the same labels (`App, Title, Year, Episode, Declared, Detected, Confidence, Verdict, Path`), chips built with `document.createElement("span")` + `textContent` (label) + child span `.n` (count) — **no `innerHTML` anywhere**; token check `hmac.compare_digest(got.encode("utf-8"), token.encode("utf-8"))`; add headers `Cache-Control: no-store`, `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`; `--host` default `127.0.0.1` and help text `use 0.0.0.0 to expose on the LAN`; `serve` wraps the bind in `try/except OSError` → `ReportError(f"could not bind {host}:{port}: {e}")`; `main(argv=None) -> int` calls `check_python_floor()`, returns 0/1, `if __name__ == "__main__": sys.exit(main())`.
- [ ] **Step 4: Report page performance (P6)** in the same file, separate commit: precompute `r._hay = (Title+" "+Path+" "+Episode+" "+DetectedLanguage+" "+DeclaredAudioLanguages).toLowerCase()` once at load; one `new Intl.Collator(undefined, {numeric: true})` reused in the sort comparator; debounce the search input (150 ms); render at most `ROW_CAP = 2000` rows with a "Show all N rows" button that removes the cap; delegate the copy-button click to `tbody` (one listener, `data-path` attribute → `dataset.path`); keep the `textContent`-only rule. Add static test R19: `HTML_TEMPLATE` contains `Intl.Collator` and `ROW_CAP` and `addEventListener("click"` appears at most 4 times.
- [ ] **Step 5: Run** `uvx --python 3.12 pytest tests/python/test_report.py -q && uvx --python 3.9 pytest tests/python/test_report.py -q && uvx ruff check verify tests` → green.
- [ ] **Step 6: Commits**: `fix(report): python 3.9 floor, safe chips, hmac token compare, localhost default` then `perf(report): debounce, precomputed search haystack, row cap`.

---

### Task 3: Phase 2 worker — safety and crash correctness

**Files:**
- Modify: `verify/verify_audio_language.py`
- Test: `tests/python/test_verify.py`

**Interfaces:**
- Consumes: `audit_common.*` constants, fake `faster_whisper` (`FAKE_WHISPER_SCRIPT`), `ffmpeg`/`ffprobe` shims via `monkeypatch.setenv("PATH", ...)`.
- Produces: module-level `@dataclass(frozen=True) class Config` with fields `whisper_model: str = "small"`, `sample_seconds: int = 60`, `sample_offset_pct: float = 25.0`, `min_free_space_mb: int = 500`, `temp_parent: str | None = None`, `min_confidence: float = 0.6`, `whisper_threads: int = 0`, and `Config.from_env(env: Mapping[str, str] | None = None) -> Config` (empty string == unset; invalid value → `ConfigError(msg)`); `check_disk_space(path, min_mb) -> None` raising `DiskSpaceError`; `get_duration_seconds(path) -> float | None`; `extract_sample(path, out_wav, cfg) -> bool`; `load_model(cfg)`; `detect_language(model, wav_path) -> tuple[str | None, float]`; `is_italian(lang: str | None) -> bool` (None → False); `file_signature(path)`; `load_previous_rows(path)`; `resume_decision(...)` unchanged signature; `make_temp_dir(cfg) -> str` (always `tempfile.mkdtemp(prefix="lang-check-", dir=cfg.temp_parent)`); `main(argv=None) -> int` with exit codes 0 ok, 1 usage/config/disk/input, 3 every file errored.

- [ ] **Step 1: Write RED tests**: Y23 (`TEMP_DIR=<dir with marker.txt>` → after `main([...])` the dir exists, marker intact, no `sample_*.wav` and no `lang-check-*` left inside), Y24 (default temp dir removed on both the nothing-to-verify and normal paths), Y2 (`is_italian(None) is False`; `it/IT/ita` True; `en/ita-x/""` False), Y13 (fake model scripted `[null, 0.0]` → row `DETECTION_FAILED`, run completes, return 0 when other rows succeed), Y4 (offset math: duration 100 → `-ss 25.0`; 50 → `-ss 0`; 200 → `-ss 50.0`; ffprobe None → `-ss 0`; argv contains `-nostdin -loglevel error -y`, `-vn -acodec pcm_s16le -ar 16000 -ac 1`, output last), Y5–Y8, Y9 (`load_model(Config(whisper_model="tiny"))` constructs `WhisperModel("tiny", device="cpu", compute_type="int8", cpu_threads=<expected>)`), Y11 (fresh run writes all verdicts, header == 11 columns, `Confidence == "0.97"`, `DeclaredAudioLanguages` copied from `AudioLanguages`, order preserved, `FileSize/FileMtime` empty for `FILE_NOT_FOUND`, stamped for `EXTRACTION_FAILED`), Y12, Y22 (fake model raises `KeyboardInterrupt` on first call → output has header + kept rows; temp dir gone; return code non-zero), Y25 (`check_disk_space` raises `DiskSpaceError`; `main` → 1 with `need at least`), Y26 (missing input → 1), Y28, Y29, new Y30 (`Config.from_env({"SAMPLE_SECONDS": ""})` uses default 60; `{"SAMPLE_SECONDS": "abc"}` → `ConfigError`; `main` prints the error and returns 1 **after** `--help` still works: `main(["--help"])` raises `SystemExit(0)` even with a bad env), new Y31 (**R1**: when `load_model` raises `ImportError`, the previous output CSV is byte-identical afterwards and `main` returns 1), new Y32 (**R7**: all rows `FILE_NOT_FOUND` → return 3; stderr `every file errored`).
- [ ] **Step 2: Run** → failures.
- [ ] **Step 3: Implement** (behaviour otherwise unchanged): `from __future__ import annotations`; `Config` + `from_env` parsed inside `main` after `parse_args`; `make_temp_dir`; `is_italian(None)`; `detect_language` returns `(info.language, float(info.language_probability or 0.0))` and the caller treats `lang is None` as `DETECTION_FAILED`; ffmpeg argv `["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-ss", str(start), "-i", path, "-t", str(cfg.sample_seconds), "-vn", "-acodec", "pcm_s16le", "-ar", "16000", "-ac", "1", out_wav]` (the `-map` choice is Task 5); `load_model(cfg)` passes `cpu_threads=cfg.whisper_threads or os.cpu_count() or 4`; **order in `main`**: read input → plan → if `to_verify`: `model = load_model(cfg)` (ImportError/OSError → message + return 1) → only then open output for writing; `ffprobe` call uses `check=False`; exit code 3 when `error_count == len(to_verify) > 0`; `if __name__ == "__main__": sys.exit(main())`; the launcher-facing CLI (`--input --output --limit --retry-errors --no-resume`) unchanged; `check_python_floor()` first thing in `main`.
- [ ] **Step 4: Run** on 3.12 and 3.9 + ruff → green.
- [ ] **Step 5: Commit** `fix(verify): never delete TEMP_DIR, survive None language, load model before truncating output`.

---

### Task 4: Phase 2 worker — pure resume planning keyed on (path, episode)

**Files:**
- Modify: `verify/verify_audio_language.py`
- Test: `tests/python/test_resume.py`

**Interfaces:**
- Produces:
  ```python
  @dataclass
  class Plan:
      kept: list[dict]          # normalised output rows reused unchanged (input order)
      to_verify: list[dict]     # input rows needing detection (input order, already limited)
      deferred: list[dict]      # previous output rows for to_verify rows cut by --limit
      orphans: list[dict]       # previous rows whose key is no longer in the input
      dropped_stale: int
  def row_key(row: Mapping[str, str]) -> tuple[str, str]:  # ((row["Path"] or "").strip(), (row["Episode"] or "").strip())
  def load_previous_rows(output_path) -> dict[tuple[str, str], dict]
  def plan_rows(input_rows, previous, *, retry_errors: bool, limit: int, signature=file_signature) -> Plan
  def normalise_previous(row, size=None, mtime=None) -> dict   # was the norm_prev closure
  def make_row(row, detected="", confidence="", verdict="", size=None, mtime=None) -> dict
  ```
  `plan_rows` never touches the output file; `signature` is injectable for tests. Rules: `resume_decision` as today except **R3**: a previous row with an error verdict and no stored signature whose file is now visible → `verify` (never stamp a signature on an unverified error row); **R2**: keys are `(path, episode)`; **R4**: rows beyond `limit` that have a previous row go to `deferred` and are written unchanged.

- [ ] **Step 1: Write RED tests**: Y1 (9 `resume_decision` cases incl. the new R3 case), Y14 (run 1 three files; append a byte to B; run 2 → fake model called only for B, `Reusing 2 previous verdict(s)`), Y15 (mtime-only change re-verifies), Y16 (legacy 9-column previous CSV kept and stamped **only for non-error verdicts**), Y17 (`--retry-errors` reprocesses only error rows; `LOW_CONFIDENCE` rows too), Y18 (orphans ×4: changed → dropped with `Dropped 1 stale row(s)`; unchanged → kept; gone → kept; legacy → kept), Y19 (`--no-resume`), Y20 (`--limit 2` verifies first two in input order), Y21 (**R4**: previous verdict for C, C changed, `--limit 1` verifies A → C's old row still present), new Y33 (**R2**: two input rows with the same path and `Episode` `S01E01 - A` / `S01E02 - B`; after run 1 both verified; run 2 unchanged → both kept with their own Episode values; the model is called twice in run 1 and zero times in run 2), new Y34 (**R3**: previous `FILE_NOT_FOUND` with empty signature, file now exists → re-verified without `--retry-errors`), Y27 (literal phase 1 line `Radarr,"Hello, ""World""",2003,,"","/m/a, ""b"".mkv"` round-trips), plus direct `plan_rows` unit tests with an injected `signature` (no filesystem): 6 cases covering kept/verify/deferred/orphan/dropped/limit.
- [ ] **Step 2: Run** → failures.
- [ ] **Step 3: Implement** `Plan`, `row_key`, `plan_rows`, hoist `normalise_previous`/`make_row` to module level, `main` becomes: parse → config → read input → `previous = {} if no_resume else load_previous_rows(...)` → `plan = plan_rows(...)` → log counts → load model if needed → write header, `plan.kept`, `plan.deferred`, `plan.orphans` → detection loop over `plan.to_verify` → summary. Output written rows: kept + deferred + orphans + newly verified (input order within each group).
- [ ] **Step 4: Run** all Python tests on 3.12 and 3.9 + ruff → green.
- [ ] **Step 5: Commit** `fix(verify): key resume on (path, episode), retry unstamped errors, keep verdicts beyond --limit`.

---

### Task 5: Phase 2 worker — detection quality

**Files:**
- Modify: `verify/verify_audio_language.py`; `tests/bats/fakes/bin/ffprobe` (gains `-show_streams`/`-select_streams a` support: prints `{"format":{"duration":...},"streams":[{"index":1,"codec_type":"audio","disposition":{"default":0}},{"index":2,"codec_type":"audio","disposition":{"default":1}}]}` when `FAKE_STREAMS` JSON is set, else a single default stream)
- Test: `tests/python/test_detection.py`

**Interfaces:**
- Produces: `probe_media(path) -> MediaProbe` with `@dataclass class MediaProbe: duration: float | None; audio_stream: int | None` (index **within audio streams** of the stream with `disposition.default == 1`, else `0` when any audio stream exists, else `None`); `extract_sample(path, out_wav, cfg, probe)` adds `-map 0:a:<audio_stream>` when `audio_stream is not None`; `classify(lang: str | None, prob: float, min_confidence: float) -> str` returning `VERDICT_DETECTION_FAILED` for `None`, `VERDICT_LOW_CONFIDENCE` when `prob < min_confidence`, else `VERDICT_MISTAGGED`/`VERDICT_CONFIRMED`; `detect_language(model, wav_path)` uses `model.detect_language(audio=wav_path, vad_filter=True, language_detection_segments=2, language_detection_threshold=0.5)` when the attribute exists, falling back to `transcribe(...)`; env `MIN_CONFIDENCE` (default `0.6`), `WHISPER_THREADS` (default `os.cpu_count()`).

- [ ] **Step 1: Write RED tests**: `classify` parametrised (it/0.97 → MISTAGGED; en/0.9 → CONFIRMED; en/0.31 → LOW_CONFIDENCE; it/0.4 → LOW_CONFIDENCE; None → DETECTION_FAILED; threshold boundary `prob == min_confidence` → not low); `probe_media` with `FAKE_STREAMS` picking the default-disposition stream (index 1 within audio streams) and `0` otherwise; `extract_sample` argv contains `-map 0:a:1` in the first case and `-map 0:a:0` in the second and no `-map` when the probe failed; `detect_language` prefers `detect_language()` on the fake (assert `WhisperModel.calls` grew and `transcribe` was not called — add a `transcribe_calls` counter to the fake) and falls back when the attribute is deleted; e2e: `MIN_CONFIDENCE=0.8` with a scripted `["en", 0.7]` → row `LOW_CONFIDENCE`, summary line `Low confidence:` present, `--retry-errors` re-verifies it next run; summary counts.
- [ ] **Step 2: Run** → failures.
- [ ] **Step 3: Implement** as specified; update the module docstring and `--help` epilog (verdicts, `MIN_CONFIDENCE`, `WHISPER_THREADS`, "only the sampled window decides; default-disposition audio stream, else the first").
- [ ] **Step 4: Run** all Python tests (3.12, 3.9) + ruff → green.
- [ ] **Step 5: Commit** `feat(verify): LOW_CONFIDENCE verdict, default audio stream selection, detect_language API, all CPU threads`.

---

### Task 6: `lib/common.sh`

**Files:**
- Create: `lib/common.sh`
- Test: `tests/bats/lib_common.bats`

**Interfaces produced (bash 3.2, shellcheck-clean, idempotent under repeated `source`):**
```bash
# guard
[[ -n "${ALA_COMMON_LOADED:-}" ]] && return 0; ALA_COMMON_LOADED=1
ALA_LIB_DIR / ALA_ROOT (repo root) / ALA_REPORTS_DIR="$ALA_ROOT/reports"
ALA_PHASE1_CSV="$ALA_REPORTS_DIR/missing-italian-audio.csv"
ALA_PHASE2_CSV="$ALA_REPORTS_DIR/verified-language-results.csv"
ALA_REPORT_HTML="$ALA_REPORTS_DIR/verified-language-results.html"
ALA_ENV_FILE="$ALA_ROOT/.env"
ALA_MIN_PYTHON="3.9"
log() warn() err()           # stderr; WARN:/ERROR: prefixes as today
die [code] msg...            # err + exit (default code 1)
have CMD                     # command -v … >/dev/null 2>&1
require CMD...               # die 1 "X is required but not installed." on the first missing one
is_true VAL                  # [[ "$VAL" == "true" ]] (case-insensitive via [[ =~ ^[Tt][Rr][Uu][Ee]$ ]])
strip_cr VAR_NAME            # removes \r from the named variable
normalize_url URL            # echoes URL without trailing slashes
find_dotenv                  # echoes first existing of "$ALA_ROOT/.env" "$ALA_ROOT/scan/.env"; rc 1 if none
load_dotenv FILE             # strict KEY=value parser, see below
arr_curl KEY curl-args...    # curl -sf --compressed -K - "$@"  with  "header = \"X-Api-Key: $KEY\""  on stdin (key never on argv)
arr_get URL KEY [TRIES]      # GET with -m "${ARR_TIMEOUT:-120}", retries TRIES (default 3) with sleep "${ARR_RETRY_DELAY:-2}" between; echoes body; rc 1 after last failure
arr_post URL KEY JSON        # POST -H 'Content-Type: application/json' -d "$JSON" -m "${ARR_TIMEOUT:-120}"
python_meets_floor BIN       # "$BIN" -I -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'
python_has_faster_whisper BIN# "$BIN" -I -c 'import faster_whisper' >/dev/null 2>&1
find_phase2_python           # echoes "$ALA_ROOT/verify/venv/bin/python" if executable and has faster_whisper, else "python3" if it has it, else rc 1; honours PYTHON_BIN override first
```
`load_dotenv` rules: skip blank and `#` lines; accept only `^[A-Za-z_][A-Za-z0-9_]*=`; strip a trailing `\r`; strip one pair of matching surrounding quotes; **allow-list** keys `RADARR_URL RADARR_API_KEY SKIP_RADARR SONARR_URL SONARR_API_KEY SKIP_SONARR FORCE_RESCAN RESCAN_TIMEOUT REFRESH WHISPER_MODEL SAMPLE_SECONDS SAMPLE_OFFSET_PCT MIN_FREE_SPACE_MB MIN_CONFIDENCE WHISPER_THREADS TEMP_DIR LIMIT RETRY_ERRORS NO_RESUME PYTHON_BIN` (others → `warn "…: ignoring unknown key K"`); **never override a variable already set in the environment** (`declare -p "$k" >/dev/null 2>&1` → skip); set with `printf -v "$k" '%s' "$v"`; never `source`, never `eval` on values; does **not** export. `RADARR_URL`/`SONARR_URL` are normalised with `normalize_url` after loading.

- [ ] **Step 1: Write RED tests** (`tests/bats/lib_common.bats`, sourcing the lib under `"$BASH_UNDER_TEST"` via `run "$BASH_UNDER_TEST" -c 'source lib/common.sh; …'`): `.env` with `RADARR_API_KEY=$(echo INJECTED >&2; echo k)` → stderr lacks `INJECTED` and the variable equals the literal text; value with spaces kept; `KEY="quoted"` → `quoted`; CRLF line → no `\r`; unknown key → warning + not set; environment wins over file (`FORCE_RESCAN=true` in env, `false` in file → `true`); `normalize_url http://h:7878/// ` → `http://h:7878`; `find_dotenv` order (root before scan/, CWD ignored); `arr_get` against the fake server: body returned, request log `key_ok: true`, **`ps`-free check**: the shim approach — install a `curl` wrapper shim that logs `"$@"` then execs `/usr/bin/curl` and assert the logged argv does not contain the key; `arr_get` with `fail_count` 2 succeeds on the 3rd attempt with `ARR_RETRY_DELAY=0`; `fail_count` 99 → rc 1 and exactly 3 requests; `find_phase2_python` with the `python3` shim (`FAKE_PY_HAS_FW=0`) and a venv shim (`FAKE_PY_HAS_FW=1`) → venv path; `PYTHON_BIN` override wins; `python_meets_floor` with `FAKE_PY_VERSION=3.8.10` → rc 1; every helper works when sourced twice; `shellcheck -S warning lib/common.sh` clean.
- [ ] **Step 2: Run** → failures.
- [ ] **Step 3: Implement** `lib/common.sh`.
- [ ] **Step 4: Run** `bats tests/bats/lib_common.bats` under `/bin/bash` + `shellcheck` → green.
- [ ] **Step 5: Commit** `feat(lib): shared bash library — safe .env parser, arr_curl, phase-2 python discovery`.

---

### Task 7: Phase 1 rewrite — one jq pass, US separator, bash 3.2

**Files:**
- Modify: `scan/find-missing-italian-audio.sh` (restructure into functions + `main`, sourcing `lib/common.sh`)
- Test: `tests/bats/scan.bats` (part 1), un-skip L3 in `tests/bats/lint.bats`

**Interfaces:**
- Consumes: `lib/common.sh` (`log warn err die require is_true find_dotenv load_dotenv normalize_url arr_get arr_post`).
- Produces (functions inside the script, guarded by `if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi`): `italian_regex` constant `ITALIAN_REGEX='(^|[^a-z])(italian|ita|it-it)([^a-z]|$)'` used only inside jq via `test($re; "i")`; `jq_csvq_def` = `def csvq: "\"" + (tostring | gsub("[\r\n\t]"; " ") | gsub("\""; "\"\"")) + "\"";`; `scan_radarr` and `scan_sonarr` append to `$OUT_TMP`, echo hit lines to stdout, increment `found_count`, set `radarr_failed`/`sonarr_failed`; cache file v2 schema `{"__meta": {"version": 2, "regex": "<ITALIAN_REGEX>"}, "<seriesId>": {"sig": "<count>:<size>", "rows": ["csv line", ...]}}` — a cache without `__meta.version == 2` or with a different regex is ignored with `warn "cache format changed, rebuilding"`; `US=$'\x1f'` as the only in-band separator between jq and bash (`IFS="$US" read -r …`); no `mapfile`; no `${var,,}`.
- Performance constraints (P1): Radarr = exactly 1 jq for the whole payload; Sonarr hit path = O(1) jq calls total (one join of `series_json` with the cache emitting `id US title US sig US HIT|MISS` per series; one jq emitting all cached rows for the hit ids; carried entries merged in one jq at the end); Sonarr miss path ≤ 2 jq per series (one filter+format producing `csvrow US hitline` lines, one building the cache entry from the collected rows) plus the `arr_get`; final cache = one `jq -s` over a JSONL of `{"id":…, "entry":…}` fragments plus carried ids. Cache rows written from jq output verbatim.
- Row format: Radarr `"Radarr," + (.title|csvq) + "," + ((.year // "")|tostring) + ",," + ($al|csvq) + "," + ((.movieFile.path // "")|csvq)`; Sonarr `"Sonarr," + ($title|csvq) + ",," + (("S%02dE%02d - %s" formatted as ("S" + (.seasonNumber|tostring|pad2) + "E" + (.episodeNumber|tostring|pad2) + " - " + (.title // ""))) | csvq) + "," + ($al|csvq) + "," + ((.episodeFile.path // "")|csvq)` where `def pad2: if length < 2 then "0" + . else . end;`. Hit line `"[Radarr] \(.title) (\(.year // "")) -> audio: \(if $al == "" then "<none>" else $al end)"` / `"[Sonarr] \($title) - \(label) -> audio: …"`, with `[\r\n\t]` replaced by spaces and control characters (`\u0001`-`\u001f`, `\u007f`) stripped from log lines.
- Sonarr fallback (`hasFile` without embedded `episodeFile`) preserved: jq emits `NEEDFILE US <episodeFileId> US <label>` lines; bash fetches `/episodefile/<id>` with `arr_get … 2` and formats that single row with one small jq.

- [ ] **Step 1: Write RED tests** (`tests/bats/scan.bats` part 1, each using `start_fake_arr` + `run --separate-stderr "$BASH_UNDER_TEST" "$ROOT/scan/find-missing-italian-audio.sh" "$OUT"`): S1 (null tag → exact row `Radarr,"Null Tag",2003,,"","/media/Italian Movies/null-tag.mkv"`), S2 (null year → `Radarr,"No Year",,,"English","/media/noyear.mkv"`), S3 (empty title + empty tag episode → `Sonarr,"Series One",,"S01E02 - ","","/tv/s/S01E02.mkv"`), S4 (variants: `Italian`, `ita`, `it-IT`, `English / Italian`, `italian` absent; `English`, `Japanese / English`, `""`, `Occitan` present — compare the sorted CSV body to an expected heredoc), S5 (`"Hello, ""World"""` and `"/m/a, ""b"".mkv"`; `python3 -c 'import csv…'` reads them back), S6 (path `\\nas\share\a.mkv` single backslashes), S7 (title `A\tB\nC` → one row, `A B C`), S8 (`hasFile:false` absent; missing `mediaInfo` flagged with `""`), S12 (`SKIP_RADARR=true` → zero `/radarr/` requests; twin), S13 (all-Italian → **header-only CSV exists**, stderr `No files missing Italian audio were found.`, exit 0), S14 (cache written with `__meta.version == 2`, `."1".sig == "10:123456"`; second run: no `/episode?seriesId=1` request, CSV byte-identical, stderr `[cache]`), S15 (sig change ×2 → refetch), S16 (`--refresh` and `REFRESH=true`), S17 (removed series drops from cache), S18 (malformed cache → warn + rebuild), S19 (`/series` 500×3 → cache byte-identical, `Sonarr scan failed`, exit 2), S20 (episode fetch failure: cached series re-emitted, uncached skipped, both warnings), S21 (fallback `/episodefile/77` → row with `German` and path from it), S30 (stdout lines all match `^\[(Radarr|Sonarr)\] `), new S34 (**perf**: install a `jq` counting wrapper shim (logs one line per invocation then execs the real jq found via `command -v -p jq` captured before PATH change); with `series.json` extended to 30 series all cached (run twice) → the second run invokes jq at most 12 times; a cold run over 30 series with 1 episode each invokes jq at most `2*30 + 12` times), new S35 (old v1 cache file without `__meta` → warning `cache format changed`, full refetch, cache rewritten with `__meta`). Un-skip L3.
- [ ] **Step 2: Run** → failures (many).
- [ ] **Step 3: Implement** the rewrite: keep the CLI (`[OUTPUT_CSV] [--refresh] [-h]`), `set -euo pipefail`, `usage()` heredoc updated (exit codes 0/1/2, header-only CSV, `FORCE_RESCAN ⇒ REFRESH`, `.env` lookup/precedence), source `lib/common.sh` via `SCRIPT_DIR/../lib/common.sh`, config loading order: env snapshot → `load_dotenv "$(find_dotenv)"` (skips already-set vars) → CLI flag `--refresh` → defaults. Write to `OUT_TMP="$OUTPUT_CSV.tmp.$$"` and `mv -f` at the end; on the failed-fetch path (see Task 8 for exit code semantics) still write what was scanned. The wizard block moves into `run_wizard` (unchanged logic; the `.env` write is hardened in Task 8).
- [ ] **Step 4: Run** `bats tests/bats/scan.bats tests/bats/lint.bats` under `/bin/bash` + `shellcheck` → green.
- [ ] **Step 5: Commit** `perf(scan): one jq pass per payload, US separator, bash 3.2, cache v2` — the commit message body must state the C1 fix explicitly ("empty audioLanguages no longer shifts the path into the language column").

---

### Task 8: Phase 1 robustness — exit codes, atomic output, rescan, wizard

**Files:**
- Modify: `scan/find-missing-italian-audio.sh`
- Test: `tests/bats/scan.bats` (part 2)

**Interfaces:**
- Exit codes: `0` completed; `1` usage/deps; `2` completed but at least one *enabled* app failed to fetch its list (`radarr_failed`/`sonarr_failed`); on `2` the previous `OUTPUT_CSV` is left untouched (temp file removed) and stderr says `scan incomplete: <apps> unreachable; previous report kept` — never `No files missing Italian audio were found.`
- `FORCE_RESCAN=true` sets `REFRESH=true` (log line `FORCE_RESCAN implies --refresh`). `wait_for_command` polls with `arr_get … 1` (so `-m` applies), treats `completed` as success and `failed|aborted|cancelled|orphaned` as failure, and on timeout returns 1 with the existing warning; `RESCAN_TIMEOUT` default becomes `900`.
- Wizard `.env` write: `(umask 077; { …; } > "$ENV_FILE")`, values validated (`URL` must match `^https?://[^[:space:]]+$`, key `^[A-Za-z0-9]+$`, otherwise re-prompt once then abort the save with a warning); `.env` written with `KEY=value` lines only; wizard gated by `is_interactive` which honours `ARR_ASSUME_TTY=1`; `probe_local_port` uses `${ARR_LOCALHOST:-localhost}`.

- [ ] **Step 1: Write RED tests**: S9 (401 on Radarr with a valid Sonarr → exit 2, stderr `Radarr scan failed`, no `No files missing…`, CSV contains the Sonarr rows), S10 (persistent 500 → exactly 3 attempts, exit 2, previous CSV byte-identical when one existed, no `.tmp` left), S11 (transient 500 then 200 → success, 3 requests logged), S22 (`FORCE_RESCAN=true` → `POST /command` body `{"name":"RescanMovie"}`, ≥1 `GET /command/42`, `RescanMovie completed.`, **and** `/episode?seriesId=1` requested despite an unchanged cached sig), S23 (`RESCAN_TIMEOUT=0` → `did not complete within 0s`, CSV produced, < 2 s), S24 (`failed` status → warning, scan continues), new S36 (`aborted` status → warning, scan continues), S25 (`.env` = `.env.example` with real fake URLs/keys and `FORCE_RESCAN=false`; env `FORCE_RESCAN=true` → `POST /command` present), S26 (`.env` code injection is inert; the key arrives literally in the request log), S27 (`<repo>/.env` beats `<repo>/scan/.env`; a `./.env` in CWD is ignored — test by running from a temp CWD containing a `.env` with a wrong key), S28 (`--bogus` → exit 1 `unknown option`; `-- --weird.csv` writes `--weird.csv`), S29 (no config, stdin `</dev/null` → no prompt, exit 2 within `timeout 30`), S31 (`crlf: true` control → no `\r` in cache keys/sig/paths), S32 (custom `OUTPUT_CSV` in a new dir, cache beside it), S33 (wizard: `ARR_ASSUME_TTY=1`, `ARR_LOCALHOST=127.0.0.1` cannot match the fake's port so answer the URL prompt explicitly; scripted stdin → `.env` written, mode `600` via `stat -f %Lp` or `stat -c %a`, contains `RADARR_URL=` and `RADARR_API_KEY=radarr-key`), new S37 (wizard rejects `RADARR_URL=http://x/#$(id)`… actually a URL with a space → warning, `.env` not written).
- [ ] **Step 2: Run** → failures.
- [ ] **Step 3: Implement**.
- [ ] **Step 4: Run** `bats tests/bats/scan.bats` under `/bin/bash` + `shellcheck` → green.
- [ ] **Step 5: Commit** `fix(scan): exit 2 on failed fetch, keep previous CSV, FORCE_RESCAN implies refresh, harden wizard`.

---

### Task 9: Phase 2 launcher

**Files:**
- Modify: `verify/verify-audio-language.sh`
- Test: `tests/bats/verify_launcher.bats`

**Interfaces:**
- Consumes: `lib/common.sh` (`log warn err die have find_phase2_python python_meets_floor python_has_faster_whisper ALA_PHASE1_CSV ALA_PHASE2_CSV find_dotenv load_dotenv`).
- Produces: CLI `[INPUT_CSV] [OUTPUT_CSV]`, `--check` accepted in any position, `-h|--help`; env `PYTHON_BIN` override; decision order: (1) input CSV exists unless `--check`; (2) ffmpeg/ffprobe present (OS hint); (3) `PYTHON_BIN=$(find_phase2_python)` — venv first, then `python3`; if found, `python_meets_floor "$PYTHON_BIN"` else `die 1 "Python 3.9+ required (found X)"`; (4) **only if nothing was found**: report `python3` presence, `pip` presence, venv capability, and print the install recipe (using `pip install -r "$REPO_ROOT/verify/requirements.txt"`); (5) disk space: `mkdir -p "$TEMP_CHECK_DIR"` (when `TEMP_DIR` set) before `df`, then the existing check; (6) exec `"$PYTHON_BIN" "$PYTHON_SCRIPT" --input … --output … ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}` with the process environment stripped of `RADARR_API_KEY`/`SONARR_API_KEY` (`env -u RADARR_API_KEY -u SONARR_API_KEY "$PYTHON_BIN" …`); `--check` prints `[OK] phase 2 environment is ready (python via: <path>)` and exits 0, or the recipe and exits 1. The launcher loads `.env` (phase 2 keys only matter) so `WHISPER_MODEL` etc. in `.env` work without the orchestrator.

- [ ] **Step 1: Write RED tests**: V1 (default env → arglog `…verify_audio_language.py --input IN --output OUT`, exit 0 — RED on macOS today), V2 (`LIMIT=3 RETRY_ERRORS=true NO_RESUME=true` → flags), V3 (`--check` with system faster-whisper → exit 0, `ready (python via: python3)`, no arglog, no input needed), V4 (`--check`, no faster-whisper, venv-capable → recipe with `python3 -m venv` and `pip install -r`, exit 1, no `verify/venv` created), V5 (venv shim has the package, system does not → venv shim's arglog written, stderr `venv`), V6 (venv without package → `venv/bin/pip" install -r`), V7 (venv-incapable → `sudo apt install -y python3.12-venv`), V8 (missing input → exit 1), V9 (missing ffmpeg → OS hints; python never invoked), V10 (missing pip only matters when faster-whisper is missing: `FAKE_PY_HAS_PIP=0 FAKE_PY_HAS_FW=1` → runs fine; `HAS_PIP=0 HAS_FW=0` → hint), V11 (disk guard both ways), V12 (`TEMP_DIR` is what `df` is asked about **and** is created first — nonexistent `TEMP_DIR` no longer aborts with a raw `df` error), V13 (`FAKE_PY_VERSION=3.8.10` with the package → exit 1 naming `3.9`), V14 (python exit 3 → launcher exit 3), V15 (`in.csv out.csv --check` works), new V16 (arglog's captured env has no `RADARR_API_KEY` although it was exported to the launcher), new V17 (`PYTHON_BIN=<explicit shim>` is used as-is when it has the package), new V18 (`WHISPER_MODEL=tiny` in `<repo>/.env` reaches the python env; env var still wins).
- [ ] **Step 2: Run** → failures.
- [ ] **Step 3: Implement**; keep the helpful install hints and `check_venv_capability` (only in the missing branch); collapse the duplicated recipe blocks into one `print_venv_recipe`.
- [ ] **Step 4: Run** `bats tests/bats/verify_launcher.bats` under `/bin/bash` + `shellcheck` → green.
- [ ] **Step 5: Commit** `fix(verify-launcher): bash 3.2, venv-first python discovery, floor check, no key leakage to ffmpeg`.

---

### Task 10: Orchestrator

**Files:**
- Modify: `arr-language-audit.sh`
- Test: `tests/bats/orchestrator.bats`, un-skip the orchestrator `-h` case in `lint.bats`

**Interfaces:**
- Consumes: `lib/common.sh`, launcher `--check` (Task 9), `find_phase2_python`.
- Produces: `if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi` guard (the `-h` case, `mkdir -p`, `git describe` move into `main`/lazy helpers so sourcing has no side effects); `HAVE_WHIPTAIL=false` when `ARR_PLAIN_MENU` is set; `-h` via `usage()` heredoc; every possibly-empty array expansion guarded (`:81 flag`, `:113 pre`, `:473 extra`); `.env` via `load_dotenv` (no `source`, no `set -a`); `run_preflight` probes Radarr and Sonarr **concurrently** (`probe_app … > "$tmp/radarr" & … & wait`) with **one** attempt and `-m 3` (retries stay in the scan script), and derives `PHASE2_READY`/`PHASE2_NOTE` from `"$VERIFY_SH" --check` output (single source of truth; capture the `python via:` path into `PHASE2_PYTHON`); `probe_app`/`app_rootfolders`/`app_health_count` use `arr_curl` (key off argv); phase 2 and report are launched with `env -u RADARR_API_KEY -u SONARR_API_KEY`; `action_report`/`action_serve` run `"$PHASE2_PYTHON"` (fallback `python3`) so the venv interpreter is used; `action_setup_phase2` installs with `"$venv/bin/pip" install -r "$ROOT/verify/requirements.txt"`; `ask_input` returns rc 1 on whiptail Cancel and callers abort the action; `action_scan` handles exit 2 with `err "phase 1 finished with an unreachable app; previous report kept"`; `verdict_summary` counts `LOW_CONFIDENCE` as `… / N low confidence / …`; `recommended_action` unchanged logic but header-only CSV counts as "scanned".

- [ ] **Step 1: Write RED tests** (sourced under `/bin/bash` with `ARR_PLAIN_MENU=1`, globals reassigned to `$BATS_TEST_TMPDIR`): O1 (7-state `recommended_action`), O2, O3 (`verdict_summary` on a CRLF CSV incl. a `LOW_CONFIDENCE` row → `2 mistagged / 1 confirmed not Italian / 1 low confidence / 3 errors`; zero file; missing → `not run yet`), O4, O5 (`probe_app`: placeholder → `not configured`; fake → `OK   v4.0.0.1234   [Radarr]   <url>`; wrong key → `UNREACHABLE` **and exactly 1 request**; `\r` stripped; the `curl` wrapper shim shows no key on argv), O6 (`run_preflight` sets `*_OK`, `ENV_READY`, `SKIP_SONARR` text, `PHASE2_NOTE` from a `VERIFY_SH` recorder that prints `[OK] phase 2 environment is ready (python via: /x/python)` → `PHASE2_READY=true`, `PHASE2_PYTHON=/x/python`; recorder exit 1 → false), new O18 (preflight with both apps `UNREACHABLE` completes in < 8 s), O7 (`.env` injection inert), O8, O9 (whiptail shim on bash 3.2: `ask_yesno q yes` → `--yesno` without `--defaultno`; `ask_menu "" title 1 a` runs), O10, new O19 (`ask_input` with whiptail shim `FAKE_WT_RC=1` → rc 1 and empty output), O11 (`action_scan` forwards `FORCE_RESCAN=true` + `--refresh`; recorder exit 2 → stderr `previous report kept`), O12, O13 (`action_serve` blank port → `--serve` only; `8080` → `--serve --port 8080`; invoked via `PHASE2_PYTHON`), new O20 (recorder for `VERIFY_SH`/`REPORT_PY` sees no `RADARR_API_KEY` in its env), O14, O15, O16 (`main` with stdin `x\n0\n` → `unknown choice: x`, `Bye.`, under `timeout 30`), O17 (`-h` exit 0 with `interactive orchestrator`, no `reports/` created — run from a temp copy of the repo). Un-skip the `-h` case in `lint.bats`.
- [ ] **Step 2: Run** → failures.
- [ ] **Step 3: Implement**.
- [ ] **Step 4: Run** `bats tests/bats/orchestrator.bats tests/bats/lint.bats` under `/bin/bash` + `shellcheck` → green; then the whole suite `scripts/test.sh all`.
- [ ] **Step 5: Commit** `fix(orchestrator): bash 3.2, parallel single-shot preflight, --check as source of truth, no key leakage`.

---

### Task 11: Documentation and ADRs

**Files:**
- Modify: `README.md` (both language sections), `.env.example`, `verify/requirements.txt` (add a comment: installed by the orchestrator/launcher recipe), `.github/dependabot.yml` (no change; confirm `github-actions` entry exists)
- Create: `CHANGELOG.md` (Keep a Changelog format, `## [Unreleased]`), `docs/adr/0001-compatibility-floors.md`, `docs/adr/0002-test-harness.md`, `docs/adr/0003-phase1-single-pass-and-cache-v2.md` (MADR format: Context, Decision, Consequences; invoke the `oltrematica-skills:adr-management` skill to draft them if available, otherwise write MADR by hand)

- [ ] **Step 1: README updates** (Italian and English, same content): prerequisites state `bash ≥ 3.2 (stock macOS works), Python ≥ 3.9, jq ≥ 1.6`; phase 1 section: header-only CSV on zero findings, exit codes 0/1/2, `FORCE_RESCAN` implies `--refresh`, `RESCAN_TIMEOUT` default 900, cache v2 note; configuration: `.env` lookup (`<repo>/.env`, then `<repo>/scan/.env`; CWD no longer read), precedence `flag > environment > .env > default`, `.env` is parsed not executed (no `$(...)`), new variables `MIN_CONFIDENCE` (0.6), `WHISPER_THREADS` (all cores), `PYTHON_BIN`; phase 2: `TEMP_DIR` is the parent of a private `lang-check-*` dir, verdict table gains `LOW_CONFIDENCE` (row: "detection below `MIN_CONFIDENCE`; re-run with a bigger model or different `SAMPLE_OFFSET_PCT`, or `--retry-errors`"), exit code 3, `--retry-errors` also retries `LOW_CONFIDENCE`; report: `--serve` binds `127.0.0.1` by default, `--host 0.0.0.0` to expose; notes: the default-disposition audio stream (else the first) is sampled; only the sampled window decides; first run downloads the model from Hugging Face (one-time, offline afterwards); `--check` documented; "all four scripts accept -h"; layout tree gains `lib/`, `tests/`, `docs/`, `scripts/`; a **Development** section: `scripts/test.sh all`, prerequisites (`bats`, `shellcheck`, `uv`), CI matrix.
- [ ] **Step 2: `.env.example`**: add `MIN_CONFIDENCE`, `WHISPER_THREADS` (commented), `RESCAN_TIMEOUT=900`, note on precedence and that values are not shell-expanded.
- [ ] **Step 3: CHANGELOG + ADRs** as above; ADR 0001 records bash 3.2 / Python 3.9 and why (README promise, stock macOS); ADR 0002 records bats+pytest, fakes over real tools, `/bin/bash` in CI; ADR 0003 records the one-pass jq design, the US separator, cache v2 with `__meta`.
- [ ] **Step 4: Verify** every flag/variable/file named in README exists (`grep` each against the code) and both language sections list the same variables.
- [ ] **Step 5: Commit** `docs: floors, exit codes, LOW_CONFIDENCE, .env precedence, ADRs, changelog`.

---

### Task 12: Final verification, fork, draft PR

- [ ] **Step 1:** `scripts/test.sh all` — paste the output (lint, pytest 3.9 + 3.12, bats under `/bin/bash`).
- [ ] **Step 2:** Manual smoke against the fake server end-to-end through the orchestrator in plain mode: `ARR_PLAIN_MENU=1 ./arr-language-audit.sh` with a temp `.env` pointing at the fake, choose `1` then `0`; show the phase 1 CSV produced. Run `verify/verify_audio_language.py` with `PYTHONPATH=tests/fakes/pypath` and the shims on `PATH` over that CSV; run `report.py` on the result; show the summary lines.
- [ ] **Step 3:** `git log --oneline main..HEAD`; check every commit message format; `git status` clean.
- [ ] **Step 4:** No push access to `gioxx/arr-language-audit`: `gh repo fork --remote=false` (or reuse an existing fork), add remote `fork`, `git push -u fork perf/deep-audit-hardening`.
- [ ] **Step 5:** `gh pr create --draft --repo gioxx/arr-language-audit --base main --head amargiovanni:perf/deep-audit-hardening` with a body containing: what changed (grouped: critical fixes, security, performance with the measured numbers, tests/CI, docs), why (link to `docs/audit/2026-09-05-deep-audit.md`), how to test (`scripts/test.sh all`), behaviour changes (the list in Global Constraints), and the footer `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
- [ ] **Step 6:** Report the PR URL.

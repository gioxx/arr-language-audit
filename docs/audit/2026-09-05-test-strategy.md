> Decisions taken by the lead on the three open questions in §4: **Python floor 3.9** (`from __future__ import annotations`, CI matrix 3.9/3.12/3.13, ruff `target-version = "py39"`); **`--limit` carries the previous verdicts of deferred rows**; **phase 1 exits 2** when an enabled app failed to fetch (previous CSV preserved). Where this document says 3.10, read 3.9. Test IDs below are referenced from `tasks/todo.md`.

# Test strategy — `arr-language-audit`

Branch `perf/deep-audit-hardening` (HEAD 3c673b0), 0 tests, no CI. Every source file was read end to end
(`arr-language-audit.sh` 623 lines, `scan/find-missing-italian-audio.sh` 547, `verify/verify-audio-language.sh` 356,
`verify/verify_audio_language.py` 438, `verify/report.py` 524, `README.md`, `.env.example`). Every claim below was
checked against the code; those marked **verified** were reproduced on the dev machine (bash 3.2.57 at `/bin/bash`,
system python 3.9.6, python3.12 via Homebrew, jq 1.6, shellcheck 0.11.0, ruff via `uvx`, bats 1.14.0).

Contents: §0 defects found while reading · §1 seam analysis · §2 test plan · §3 harness layout · §4 order of work.

---

## 0. Defects found while reading (these become the first red tests)

Ordered by severity. Each maps to a test ID in §2.

| # | Where | Defect | Status |
|---|---|---|---|
| **D1** | `scan/find-missing-italian-audio.sh:404`, `:487` | `IFS=$'\t' read -r title year audioLangs path` — TAB is IFS *whitespace*, so consecutive tabs collapse into one delimiter. When `audioLanguages` is **null/empty** (the primary case this tool exists to catch), `audioLangs` receives the **path** and `Path` is empty. Consequences: every null-tagged Radarr file is written with `Path=""` → phase 2 `FILE_NOT_FOUND`; and if the path contains `ita` (e.g. `/media/Italian Movies/…`, `…/Digital/…`) the file is **silently not flagged**, because `grep -qiE "$ITALIAN_REGEX"` at `:407` is then run against the path. Same collapse when `year` is null (`year` gets the next field) and in the Sonarr loop (`:487`, six fields) for an empty episode title or empty tag. | **verified** — reproduced: `title=[…] year=[2003] audioLangs=[/media/movies/a.mkv] path=[]` |
| **D2** | `scan:415-416`, `:511-513` | `@tsv` escapes `\`→`\\` and TAB→`\t`, NL→`\n`; `read -r` does not unescape. Titles containing a backslash and Windows/SMB paths (`\\nas\share\a.mkv`) land in the CSV with doubled backslashes → phase 2 `FILE_NOT_FOUND`. | **verified** — jq emits `C:\\tv\\a.mkv` |
| **D3** | `scan:449` | `mapfile` is bash ≥ 4. On stock macOS bash 3.2 → `mapfile: command not found` (rc 127) → `set -e` aborts phase 1 entirely. README (both languages) claims macOS support. | **verified** |
| **D4** | `verify/verify-audio-language.sh:351`; `arr-language-audit.sh:81`, `:113`, `:473` | `"${arr[@]}"` on an **empty** array under `set -u` is "unbound variable" on bash < 4.4. `:351` fires in the **default** configuration (no `LIMIT`/`RETRY_ERRORS`/`NO_RESUME`) → the phase 2 launcher aborts on macOS *after* every pre-flight check has passed. `:81` fires for `ask_yesno … yes` under whiptail, `:113` for an empty default tag, `:473` for "Serve HTML report" with a blank port. The scan script already guards its arrays correctly (`:143`, `:451`). | **verified** — all four reproduced under `/bin/bash` |
| **D5** | `verify/verify_audio_language.py:89`, `:145`, `:159`; `verify/report.py:397`, `:410` | PEP 604 `float \| None` in function signatures is evaluated at def time → `TypeError` at **import** on Python 3.9 (macOS `/usr/bin/python3`). The launcher only checks that `python3` exists (`:193-200`), so on a Mac without Homebrew python it passes pre-flight and crashes. No Python floor is declared anywhere (README, requirements.txt, code). | **verified** |
| **D6** | `verify_audio_language.py:254`, `:364`, `:426` | `temp_dir = os.environ.get("TEMP_DIR") or tempfile.mkdtemp(...)` and later `shutil.rmtree(temp_dir, ignore_errors=True)` — a **user-supplied `TEMP_DIR` is deleted wholesale** at the end of the run (`TEMP_DIR=/tmp`, or a scratch share). The launcher actively advertises `TEMP_DIR=/path/with/space ./verify/verify-audio-language.sh` (`verify-audio-language.sh:326`). Destructive. | by reading |
| **D7** | `scan:164` (`source "$ENV_FILE"`), `arr-language-audit.sh:209` (`. "$ENV_FILE"`) | `.env` is executed as shell. A value containing `$(…)` runs; a URL with a space fails with `command not found`. The file is chmod 600 and user-authored, so exposure is low, but it is a code-execution path from a config file and contradicts the documented "KEY=value, no quotes" contract (`.env.example:7`). Reported here per CLAUDE.md rather than silently patched. | **verified** — `INJECTED` printed |
| **D8** | `verify_audio_language.py:412`, `:419` | `is_italian(lang)` and `f"{prob:.0%}"` sit **outside** the `try` at `:397-405`. If the detector yields `language=None` / a non-numeric probability (silence, VAD stripping everything), the whole run dies with a traceback instead of `DETECTION_FAILED`. Because the output is rewritten from scratch (`:352-359`), previous verdicts for rows still in `to_verify` are gone at that point. | by reading |
| **D9** | `report.py:423` | `secrets.compare_digest(got, token)` raises `TypeError` for non-ASCII `?k=`. The handler exception → client gets a dropped connection and a traceback on stderr, instead of 403. | **verified** |
| **D10** | `scan:398-401`, `:430-436`, `:541-543` | A 401 / unreachable app is a `WARN` and the script continues. With both apps failing `found_count=0` → "No files missing Italian audio were found", CSV deleted, **exit 0**. A broken key is indistinguishable from a clean library; the orchestrator's `\|\| err` at `arr:347` never fires; cron users see success. Exit-code contract (`:55-57`) only defines 0/1. | by reading |
| **D11** | `arr-language-audit.sh:347` + `scan:164` + `.env.example:31` + `arr:560` | `.env` is sourced **after** the environment, so `.env` wins over env vars. "Reconfigure (.env)" copies `.env.example`, which contains `FORCE_RESCAN=false`; therefore the menu's "Force rescan? **yes**" (`FORCE_RESCAN=true "$SCAN_SH"`) is silently overridden to `false`. `--refresh` is deliberately re-applied after the `.env` (`scan:184`); `FORCE_RESCAN` is not. | by reading |
| **D12** | `verify_audio_language.py:339-340` | `--limit N` truncates `to_verify`; rows beyond N are **not written** to the output, including rows that had a previous verdict but were scheduled for re-verification (changed file, or `--retry-errors`). A "quick test" with `LIMIT=5` on an existing report drops those verdicts. | by reading |
| **D13** | shellcheck / ruff | shellcheck: SC2034 `arr:171` (`attempt` unused), SC2015 `arr:199`; infos SC2016/SC2001 in scan (jq single quotes, `sed` vs `${//}`). ruff (defaults + a sane selection): 9 findings — `report.py:41` unused `import html`, `I001`, `DTZ005 :385`; `verify_audio_language.py:91` `PLW1510` (`subprocess.run` without `check`), `:146 RUF059`, `:352 SIM115`, `BLE001` ×3. | **verified** |
| **D14** | `verify-audio-language.sh:112` | `--check` is only recognised as `$1`; `verify-audio-language.sh in.csv --check` treats `--check` as `OUTPUT_CSV`. Minor. | by reading |
| **D15** | `report.py:213`, `:250` | Docstring `:93-95` says nothing from the CSV is interpreted as markup. Rows use `textContent` (`:319-329`), but the chip bar does `c.innerHTML = meta.label + …` where `verdictMeta(v)` returns `label: v` for an **unknown** verdict — i.e. the CSV `Verdict` column reaches `innerHTML`. Today the CSV is produced by our own script, so it is a self-XSS on a local report; still a false safety claim and one edit away from a real one. | by reading |

Fix sketches (so the tests can be written against an agreed target):
D1+D2 — one change: `jq -r '… \| map(tostring \| gsub("[\r\n]";" ")) \| join("\u001f")'` and `IFS=$'\x1f' read -r …` (US is not IFS whitespace, so empty fields survive, and `join` does no escaping).
D3 — `while IFS= read -r id; do series_ids+=("$id"); done < <(…)`.
D4 — `${arr[@]+"${arr[@]}"}` as the scan script already does.
D5 — decide a floor; either `from __future__ import annotations` (keeps 3.9) or floor 3.10 + `sys.version_info` guard in both `.py` and a `python3 -c` check in the launcher.
D6 — only delete `sample_*.wav` you created; `rmtree` only the directory `mkdtemp` created.
D7 — parse `KEY=value` lines with `while IFS= read -r line` + `[[ $line =~ ^[A-Z_]+= ]]` and `printf -v`; never `source`.
D10 — track `fetch_failed`; exit 2 when any *enabled* app failed to fetch; do not print "No files … found" in that case.
D11 — capture `FORCE_RESCAN`/`SKIP_*` from the environment before sourcing and restore after (same pattern as `--refresh`).
D12 — for `to_verify[N:]` rows that have a `previous` entry, carry the previous row into the output.
D15 — build the chip with `textContent` + a child `<span class="n">`.

---

## 1. Seam analysis

### 1.1 `arr-language-audit.sh` (orchestrator)

**What blocks testing today**
- `main` is called unconditionally at `:623` — sourcing the file runs the menu loop. `mkdir -p "$REPORTS_DIR"` (`:44`) and `git describe` (`:49`) also run at source time, and the `-h` `case` (`:56-61`) calls `exit`.
- `HAVE_WHIPTAIL` is auto-detected at `:64`; `ubuntu-latest` **has** whiptail, so tests would block on an ncurses dialog.
- `REPORTS_DIR`, `CSV`, `VERIFIED_CSV`, `HTML`, `ENV_FILE`, `SCAN_SH`, `VERIFY_SH`, `REPORT_PY` are derived from `$ROOT` (`:33-42`). They are plain globals read at call time by the action functions, so a test that sources the file can simply reassign them after sourcing. No refactor needed for those.

**Minimal refactor (behaviour-preserving)**
1. `:623` → `if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi`; move the `-h` `case` and `mkdir -p` into `main`.
2. `:64` → `HAVE_WHIPTAIL=false; if [[ -z "${ARR_PLAIN_MENU:-}" ]] && command -v whiptail >/dev/null 2>&1; then HAVE_WHIPTAIL=true; fi`.
3. Fix D4 at `:81`, `:113`, `:473`.

**Seams after that** (sourced in bats, under `/bin/bash` on macOS):

| Function | Kind | How to drive / fake |
|---|---|---|
| `recommended_hint` `:298-308` | pure | call directly |
| `recommended_action` `:288-295` | globals `ENV_READY`, `PHASE2_READY` + existence/mtime of `CSV`/`VERIFIED_CSV`/`HTML` | set globals, create files in `$BATS_TEST_TMPDIR`, order mtimes with `touch -t YYYYMMDDhhmm` (portable GNU/BSD) |
| `csv_row_count` `:267-274`, `verdict_summary` `:276-283` | file I/O (`wc -l`, `grep -c`) | write fixture CSVs; **use CRLF** — `csv.DictWriter` emits `\r\n` (verified), that is the real phase-2 format |
| `probe_app` `:162-185`, `app_rootfolders` `:188-194`, `app_health_count` `:197-202` | curl + jq | fake *arr HTTP server (§3.3); `sleep 1` ×2 on failure is acceptable (≈2 s) |
| `run_preflight` `:204-261` | sources `.env`, `command -v`, python probes, `probe_app` | `ENV_FILE` → temp file; PATH shims for `python3` (exit 0/1 on `-c "import faster_whisper"`), `ffmpeg`, `ffprobe`; `ROOT` → temp copy for the `verify/venv/bin/python` branch (`:236`) |
| `ask_yesno`/`ask_input`/`ask_menu`/`info_box`/`pause` `:75-146` | interactive `read -r -p` | plain mode via `ARR_PLAIN_MENU=1` + piped stdin; whiptail branch via a `whiptail` PATH shim that logs argv and exits 0/1 — the only way to hit D4 at `:81`/`:113` |
| `action_scan` `:333-349`, `action_verify` `:351-393`, `action_report` `:442-454`, `action_serve` `:456-475` | spawn child scripts | reassign `SCAN_SH`/`VERIFY_SH`/`REPORT_PY` to recorder shims that dump `env` + `"$@"`; drive prompts via stdin |
| `action_reset` `:531-556` | `rm` on globs | `REPORTS_DIR` → temp dir |
| `action_configure` `:558-577` | `cp .env.example`, `$EDITOR` | `ENV_FILE` → temp; `EDITOR=true` (no-op) |
| `action_setup_phase2` `:395-440` | `python3 -m venv`, `pip install` | `python3` shim; only exercise the "already ready" (`:403-408`) and "declined" (`:411-412`) branches — a test must never reach real pip |
| `main` `:583-621` | loop | stdin `"0\n"`; needs the guard + `ARR_PLAIN_MENU` |

### 1.2 `scan/find-missing-italian-audio.sh` (phase 1)

**What blocks testing today**
- Entirely procedural: CLI parse `:132-143`, `.env` load `:154-168`, dependency `exit 1` `:206-207`, wizard `:260-287`, then both scan blocks at top level. The functions `wait_for_command` `:304`, `api_get` `:346`, `emit_cached_rows` `:363`, `carry_cache_entry` `:375` exist but cannot be sourced without running the scan.
- Wizard is gated by `is_interactive() { [[ -t 0 && -t 1 ]]; }` `:213`. bats has no TTY, so the wizard **never** runs in tests (good: no hang) but is untestable without a TTY override.
- `probe_local_port` hardcodes `http://localhost:$port` `:219`.
- Timing: `api_get` sleeps 2 s between retries `:354` (a 401 test costs ≈4 s per app). `wait_for_command` polls every 5 s `:322` — but `RESCAN_TIMEOUT=0` makes the loop body never run (`:323`), so the timeout path is testable in 0 s **without** a refactor, and a fixture whose first poll returns `completed`/`failed` never sleeps.

**Recommendation: test phase 1 black-box** against the fake server. It is 400 lines of glue whose value is exactly the integration (jq filter → `read` → CSV → cache). Unit-sourcing it buys little. **No refactor is required for the P0 set.** Optional, cheap knobs:
- `API_RETRY_DELAY="${API_RETRY_DELAY:-2}"` at `:354` (saves ≈6 s per suite run).
- `ARR_ASSUME_TTY=1` short-circuit in `is_interactive` and `ARR_LOCALHOST` in `probe_local_port` — only if the wizard (P2) is to be tested.

**Contracts worth pinning** (each maps to a test in §2.2): CSV header `App,Title,Year,Episode,AudioLanguages,Path` `:383`; quoting via `sed 's/"/""/g'` `:410-412`, `:503-506` — Title/Episode/Path quoted, `Year` and `AudioLanguages` written raw (`:412`, `:506`); `ITALIAN_REGEX='italian|ita|it-it'` with `grep -qiE` `:204`, `:407`, `:500`; `hasFile == true` filter `:415`, `:511`; `episodeFileId` 0/empty skipped `:488`; fallback to `/episodefile/{id}` when `path` empty `:492-498`; cache schema `{ "<seriesId>": {sig:"<episodeFileCount>:<sizeOnDisk>", rows:[csv lines]} }` `:522-523`; cache hit condition `:462`; cache not rewritten if the series list fetch failed `:528`; malformed cache ignored with warning `:441-446`; CSV deleted when zero findings `:543`; stdout = hit lines only, stderr = diagnostics `:64-65`; `--refresh` beats `.env` `:184`; `.env` lookup order `scan/`, repo root, `./` `:155`.

### 1.3 `verify/verify-audio-language.sh` (phase 2 launcher)

Pure pre-flight: no network, no state; every decision goes through `command -v`, a `python3 …` probe, `uname`, or `df`. **Fully black-box testable with PATH shims; no refactor needed.**

| Line(s) | Decision | Fake |
|---|---|---|
| `:139-143` | input CSV exists (skipped in `--check`) | temp file |
| `:145-149` | companion `.py` present | `cp -R verify "$BATS_TEST_TMPDIR/verify"` — also makes `VENV_DIR="$SCRIPT_DIR/venv"` (`:225`) writable per test without touching the repo |
| `:155-163` | `uname` → `Darwin` ⇒ `brew`; else `command -v apt/dnf/pacman` | `uname` shim; `apt`/`dnf` shims present or absent from the test PATH |
| `:181-188` | ffmpeg/ffprobe present | include / omit shims |
| `:193-220` | `python3 --version`, `python3 -m pip --version` | `python3` shim honouring `FAKE_PY_VERSION`, `FAKE_PY_HAS_PIP` |
| `:231-259` | `check_venv_capability` really runs `python3 -m venv` in a mktemp dir | shim: `-m venv DIR` creates `DIR/bin/pip` iff `FAKE_PY_VENV_OK=1` |
| `:261-296` | `python3 -c "import faster_whisper"` → system; else `$VENV_DIR/bin/python` | shim honours `FAKE_PY_HAS_FW`; the venv path gets its own shim file |
| `:314-330` | `df -Pm "$TEMP_CHECK_DIR" \| tail -1 \| awk '{print $4}'` | `df` shim printing a 2-line table with `$FAKE_DF_AVAIL_MB` in column 4 (GNU and BSD `df -Pm` share that layout) |
| `:340-351` | env → `--limit/--retry-errors/--no-resume`; exec `"$PYTHON_BIN" "$PYTHON_SCRIPT" --input … --output …` | the `python3` shim, when an argument ends in `verify_audio_language.py`, appends `"$@"` to `$FAKE_PY_ARGLOG` and exits `${FAKE_PY_EXIT:-0}` |

### 1.4 `verify/verify_audio_language.py` (phase 2 worker)

**Already good seams.** `faster_whisper` is imported **lazily inside `load_model()`** (`:139-142`) — the module imports cleanly without the package (verified on 3.12). `detect_language(model, wav)` takes the model as a parameter (`:145`). `resume_decision(entry, cur_size, cur_mtime, retry_errors)` (`:185-213`), `is_italian` (`:152`), `file_signature` (`:159`), `load_previous_rows` (`:171`), `get_duration_seconds` (`:89`), `extract_sample` (`:106`) are directly callable.

**What blocks / what to open**
- `main()` reads `sys.argv` (`:242`) → `def main(argv=None)` + `parser.parse_args(argv)`. One line, no behaviour change.
- Module-level env constants `WHISPER_MODEL`, `SAMPLE_SECONDS`, `SAMPLE_OFFSET_PCT`, `MIN_FREE_SPACE_MB` (`:64-67`) are read at import → `monkeypatch.setattr(vam, "SAMPLE_SECONDS", 60)`. Fine as-is.
- `norm_prev`/`make_row`/`fieldnames` are closures inside `main` (`:258-289`) → not unit-testable; test through `main()` on temp CSVs (small; not worth hoisting).
- `check_disk_space` → `sys.exit(1)` (`:86`) → `pytest.raises(SystemExit)`; monkeypatch `shutil.disk_usage`.
- `ffprobe`/`ffmpeg` via `subprocess.run` with argv lists (`:91`, `:116`) → either PATH shims (shared with bats; `monkeypatch.setenv("PATH", …)`) or `monkeypatch.setattr(subprocess, "run", recorder)` for argv-precision tests.
- Fake model: `monkeypatch.setattr(vam, "load_model", lambda: FakeModel(script))`. To script a verdict *per media file* although the model only sees `sample_{i}.wav` (`:388`), have the `ffmpeg` shim write the **source path into the fake WAV** (RIFF header + `FAKEWAV:<input path>`); `FakeModel.transcribe` reads it back and looks up the scripted `(lang, prob)` / `RAISE`. One mechanism serves pytest and bats.
- D5: pick a floor; if 3.10, the pytest matrix must include 3.10.

### 1.5 `verify/report.py`

**Seams:** `read_rows(csv_path)` (`:71-87`; `sys.exit(1)` on missing), `build_html(rows, csv_path)` (`:378-391`; pure except `datetime.now()`), `make_handler(payload, token)` (`:410-441`; returns a handler class — start it on `ThreadingHTTPServer(("127.0.0.1", 0), …)` in a thread; no need to call `serve`), `local_ipv4()` (`:397`; socket-based, no traffic, skip). `serve()` (`:444-481`) blocks on `input()` → `monkeypatch.setattr("builtins.input", lambda *_: "")`. `main()` → `main(argv=None)`.

**XSS contract to pin:** DATA is injected as JSON at `:197` with `</` → `<\/` (`:383`); rows are built with `textContent` (`:319-329`); the two `innerHTML` uses (`:242`, `:250`) interpolate numbers and `meta.label`, where `label` is the raw verdict for unknown verdicts (`:213`) — see D15.

---

## 2. Test plan

Priority: **P0** = ships with the harness and gates CI, **P1** = same sprint, **P2** = optional. **RED** = fails on current code (documents a defect from §0). Parametrised cases count as one test ID.

Totals: **P0 57 · P1 46 · P2 11 = 114 test IDs** (the 40-80 target is exceeded because §0 turned up 15 defects that each want a pinning test; every P2 can be dropped without weakening the gate).

### 2.1 Lint & portability (CI job `lint` + static bats)

| ID | P | Test | Asserts | Catches |
|---|---|---|---|---|
| L1 | P0 | `shellcheck -S warning` on the three scripts (with `.shellcheckrc`) | exit 0 | D13 (SC2034 `arr:171`, SC2015 `arr:199`), future quoting bugs |
| L2 | P0 | `ruff check verify/ tests/python` | exit 0 | D13 (unused `import html`, `subprocess.run` without `check`, …) |
| L3 | P0 | `test_no_bash4_builtins` (bats, static) | `grep -nE 'mapfile\|readarray\|declare -A\|\$\{[A-Za-z_]+(,,\|\^\^)\|\|&\|&>>\|local -n'` over the three scripts finds nothing | D3, any future `${x,,}` |
| L4 | P0 | run **every bats suite under `/bin/bash` on `macos-latest`** (see §3.6 gotcha) + self-check `[[ ${BASH_VERSINFO[0]} -eq 3 ]]` when `RUNNER_OS=macOS` | suite green; self-check proves it really ran on 3.2 | D3, D4 — the only reliable detector of empty-array-under-`set -u` |
| L5 | P0 | `test_import_on_python_floor`: pytest matrix includes the declared floor; `python -W error -c "import verify_audio_language, report"` | imports | D5 regression |
| L6 | P2 | `--help` for all three scripts exits 0, prints `Usage`; orchestrator `-h` does not create `reports/` first | — | `arr:44` runs before `:56` |

### 2.2 `scan/find-missing-italian-audio.sh` — bats + fake server (`tests/bats/scan.bats`)

Each test: `setup` starts the fake server with a fixture dir, exports `RADARR_URL=http://127.0.0.1:$PORT/radarr`, `RADARR_API_KEY`, same for Sonarr, and runs `run --separate-stderr "$BASH_UNDER_TEST" "$SCAN_SH" "$OUT"`.

| ID | P | Test | Asserts | Fakes / fixture | Catches |
|---|---|---|---|---|---|
| S1 | **P0 RED** | `radarr null audioLanguages is flagged with empty tag and intact path` | CSV row exactly `Radarr,"Null Tag",2003,,"","/media/Italian Movies/null-tag.mkv"`; Path non-empty | `movies.json` with `mediaInfo.audioLanguages: null` and a path **containing** `Italian`, proving the collapse would also unflag | **D1** |
| S2 | **P0 RED** | `radarr null year keeps columns aligned` | `Year` empty, `AudioLanguages`/`Path` correct | movie without `year` | D1 |
| S3 | **P0 RED** | `sonarr episode with empty tag and empty title keeps columns aligned` | `Episode="S01E02 - "`, `AudioLanguages=""`, Path correct | `episodes_1.json` row with `title:""`, `audioLanguages:""` | D1 (Sonarr `:487`) |
| S4 | P0 | `italian tag variants are not flagged, others are` | rows for `Italian`, `ita`, `it-IT`, `English / Italian`, `italian` absent; `English`, `Japanese / English`, `""` present — exact CSV body compare | one movie per case | regex regression, `grep -i` on BSD |
| S5 | P0 | `title and path with comma and double quote round-trip` | CSV field `"Hello, ""World"""`; `python3 -c 'csv.DictReader'` returns `Hello, "World"` and `/m/a, "b".mkv` | fixture title `Hello, "World"` | `:410-412` quoting; pairs with Y27 |
| S6 | **P0 RED** | `backslash in path/title survives` | CSV contains `\\nas\share\a.mkv` with single backslashes | Windows-style path | **D2** |
| S7 | P1 | `tab or newline in title yields one CSV row with intact path` | `wc -l` == 2 (header + 1); Path exact | title `A\tB\nC` | D2 family; pins whichever fix is chosen |
| S8 | P0 | `hasFile false and missing movieFile.mediaInfo are handled` | `hasFile:false` movie absent; `hasFile:true` with no `mediaInfo` flagged with `""` | fixture | `:415` filter, `// ""` default |
| S9 | **P0 RED** | `401 on radarr is an error, not an empty success` | stderr has `Radarr scan failed`; exit ≠ 0 (propose 2); stderr does **not** say `No files missing Italian audio were found` | fake server returns 401 for a wrong key | **D10** |
| S10 | P0 | `persistent 500: exactly 3 attempts, non-zero exit, no CSV left` | request log has exactly 3 `GET /radarr/api/v3/movie`; CSV absent; exit ≠ 0 | control `fail_count: 99` | `:346-358` retry contract, D10 |
| S11 | P1 | `transient 500 then 200 succeeds` | CSV written; log shows 3 requests | `fail_count: 2` | retry logic |
| S12 | P0 | `SKIP_RADARR=true makes zero radarr requests` (+ Sonarr twin) | no `/radarr/` entries in the log; the other app is scanned | env | `:390`, `:422` |
| S13 | P0 | `zero findings removes the CSV and exits 0` | file absent; stderr `No files missing Italian audio were found.` | all-Italian fixture | `:541-543` |
| S14 | P0 | `sonarr cache is written and reused when statistics unchanged` | run 1: `<out>.cache.json` exists, `jq -r '."1".sig'` == `10:123456`, `rows` == the flagged lines; run 2 (log cleared): **no** `/episode?seriesId=1` request, CSV byte-identical, stderr contains `[cache]` | `series.json` statistics | `:449-524`, commit f6c628d |
| S15 | P0 | `cache invalidates when sizeOnDisk changes` (+ twin for `episodeFileCount`) | run 2 requests `/episode?seriesId=1`; CSV reflects the new fixture; cache `sig` updated | swap fixture between runs | `:457-462` |
| S16 | P0 | `--refresh and REFRESH=true bypass the cache` | `/episode` requested despite unchanged sig; cache rewritten | — | `:184`, `:439`, `:462` |
| S17 | P1 | `series removed from Sonarr drops out of cache and CSV` | cache lacks key `"2"`; no rows for it | `series.json` minus one | `:522` rebuild semantics |
| S18 | P1 | `malformed cache is ignored with a warning and rewritten` | stderr `is unreadable, ignoring it`; full fetch; cache valid JSON after | write `not json` | `:441-446` |
| S19 | P1 | `series list fetch failure preserves the cache file` | cache byte-identical (`cmp`); stderr `Sonarr scan failed` | `/series` → 500 ×3 | `:526-534` |
| S20 | P1 | `episode fetch failure: cached series re-emitted, uncached series skipped` | rows for series 1 (cached) present; series 2 absent; both `warn` texts; other series still processed | `/episode?seriesId=*` → 500 | `:475-484` |
| S21 | P1 | `hasFile without embedded episodeFile falls back to /episodefile/{id}` | log has `/episodefile/77`; Path taken from it | episode `episodeFileId:77`, no `episodeFile` | `:492-498` |
| S22 | P1 | `FORCE_RESCAN posts RescanMovie/RescanSeries and waits for completed` | log: `POST /command` body `{"name":"RescanMovie"}`; ≥1 `GET /command/42`; stderr `RescanMovie completed.`; scan continues | control `command_status: ["completed"]` | `:304-341` |
| S23 | P1 | `rescan timeout continues the scan` | `RESCAN_TIMEOUT=0` → stderr `did not complete within 0s, continuing anyway`; CSV produced; runs in < 1 s | `command_status: ["started"]` | `:323`, `:339` |
| S24 | P1 | `rescan status failed does not abort` | stderr `reported status 'failed'`; CSV produced | `command_status: ["failed"]` | `set -e` vs `\|\| true` at `:393` |
| S25 | **P0 RED** | `environment FORCE_RESCAN beats .env FORCE_RESCAN=false` | `.env` = `.env.example` + valid URLs/keys; `FORCE_RESCAN=true` in env → `POST /command` present | — | **D11** (orchestrator rescan choice ignored) |
| S26 | **P0 RED** | `.env values are data, not code` | `.env` with `RADARR_API_KEY=$(echo INJECTED >&2; echo k)` and `RADARR_URL=http://127.0.0.1:PORT/radarr x` → stderr lacks `INJECTED`; request log shows the key literally | — | **D7** |
| S27 | P1 | `.env lookup order: scan/.env beats repo/.env beats ./.env` | three `.env` files with three different keys; log shows which arrived | temp copy of repo layout | `:155-160` |
| S28 | P1 | `unknown option exits 1; -- terminates options` | `--bogus` → exit 1 `unknown option`; `-- --weird.csv` writes `--weird.csv` | — | `:134-143` |
| S29 | P1 | `non-interactive run with no config never prompts or hangs` | under `timeout 30`, stdin `</dev/null`: no `--- Radarr setup ---` on stdout; exits per D10 rules | no `.env`, no env | `:213`, `:260` |
| S30 | P1 | `stdout carries only hit lines` | every stdout line matches `^\[(Radarr\|Sonarr)\] `; diagnostics only on stderr | `--separate-stderr` | `:64-65` (cron pipelines) |
| S31 | P2 | `CRLF from jq is stripped` | `jq` wrapper shim appends `\r` → cache keys, sig, paths contain no `\r` | `jq-crlf` shim | `jqr` `:74` |
| S32 | P2 | `custom OUTPUT_CSV in a new directory` | dir created; cache is `<name>.cache.json` beside it | — | `:189-198` |
| S33 | P2 | wizard: `ARR_ASSUME_TTY=1` + scripted stdin writes `.env` mode 600 | content + `stat -f %Lp` / `stat -c %a` == 600 | needs two overrides (§1.2) | `:260-287` |

### 2.3 `verify/verify-audio-language.sh` — bats + PATH shims (`tests/bats/verify_launcher.bats`)

`setup`: `cp -R verify "$BATS_TEST_TMPDIR/verify"`; build `$BATS_TEST_TMPDIR/bin` from `tests/bats/fakes/bin/` selectively; `PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin"` (excludes Homebrew so `apt`, `whiptail`, a real `ffmpeg` cannot leak in).

| ID | P | Test | Asserts | Shims | Catches |
|---|---|---|---|---|---|
| V1 | **P0 RED (macOS)** | `default env runs the python script with only --input/--output` | arglog == `…verify_audio_language.py --input IN --output OUT`; exit 0 | happy set: `ffmpeg ffprobe python3 df` | **D4 `:351`** |
| V2 | P0 | `LIMIT/RETRY_ERRORS/NO_RESUME map to flags` | arglog ends `--limit 3 --retry-errors --no-resume` | same | `:340-349` |
| V3 | P0 | `--check with system faster_whisper exits 0 and runs nothing` | exit 0; stderr `phase 2 environment is ready (python via: python3)`; arglog absent; no input CSV needed | `FAKE_PY_HAS_FW=1` | `:305-309`, `:139` |
| V4 | P0 | `--check without faster_whisper and venv-capable python prints venv recipe, exits 1, leaves no venv` | exit 1; stderr has `python3 -m venv` and `pip install faster-whisper`; `verify/venv` absent | `FAKE_PY_HAS_FW=0 FAKE_PY_VENV_OK=1` | `:275-285`, mktemp cleanup `:240` |
| V5 | P0 | `venv python is used when system python lacks the package` | arglog written by the **venv** shim (`$tmp/verify/venv/bin/python`); stderr `found (venv:` | system shim `HAS_FW=0`, venv shim `HAS_FW=1` | `:263-265`, `:351` |
| V6 | P1 | `existing venv without the package gets the pip-into-venv hint` | stderr `"…/venv/bin/pip" install faster-whisper`; exit 1 | venv shim `HAS_FW=0` | `:269-274` |
| V7 | P1 | `venv-incapable python gets the pythonX.Y-venv apt hint` | stderr `sudo apt install -y python3.12-venv` | `uname`→Linux, `apt` shim present, `FAKE_PY_VENV_OK=0`, `FAKE_PY_VERSION=3.12.1` | `:242-256` |
| V8 | P0 | `missing input CSV exits 1 (not in --check)` | exit 1 `Input CSV not found` | — | `:139-143` |
| V9 | P0 | `missing ffmpeg: OS-specific hint` | Darwin → `brew install ffmpeg`; Linux+apt → `sudo apt update && sudo apt install -y ffmpeg`; exit 1; python never invoked | `uname` shim; omit `ffmpeg` | `:154-188` |
| V10 | P1 | `missing pip` | exit 1 `pip for python3 not found`; brew hint `python3 -m ensurepip` | `FAKE_PY_HAS_PIP=0` | `:205-220` |
| V11 | P0 | `disk space guard` | `FAKE_DF_AVAIL_MB=100 MIN_FREE_SPACE_MB=500` → exit 1, stderr `TEMP_DIR=/path/with/space`; `=10000` → proceeds | `df` shim | `:314-330` |
| V12 | P1 | `TEMP_DIR is the directory df is asked about` | df shim arglog contains `$TEMP_DIR` | — | `:314-315` |
| V13 | **P1 RED** | `python older than the floor is refused before running` | `FAKE_PY_VERSION=3.9.6` → exit 1 with a message naming the floor | — | **D5** (after the floor decision) |
| V14 | P1 | `python exit status propagates` | shim exit 3 → launcher exit 3 (`set -e`) | `FAKE_PY_EXIT=3` | `arr:391` depends on it |
| V15 | P2 | `--check accepted after positional args` | pins the D14 fix (or documents current behaviour) | — | D14 |

### 2.4 `verify/verify_audio_language.py` — pytest (`tests/python/test_verify.py`, `test_resume.py`)

| ID | P | Test | Asserts | Fakes | Catches |
|---|---|---|---|---|---|
| Y1 | P0 | `test_resume_decision` (parametrised, 9 cases) | `None`→verify; retry+`FILE_NOT_FOUND`→verify; retry+`MISTAGGED…`→keep; legacy row (no size) + changed file→**keep**; cur `(None,None)`→keep; equal→keep; size differs→verify; mtime differs→verify; retry=False + error verdict→keep | none | `:185-213` — the resume contract of a5701d4 |
| Y2 | P0 (+**RED** case) | `test_is_italian` | `it`,`IT`,`ita`→True; `en`,`ita-x`,`""`→False; **`None` → no exception** (after D8: caller maps to `DETECTION_FAILED`) | — | `:152-153`, D8 |
| Y3 | P1 | `test_file_signature` | existing → `(int,int)`; missing → `(None,None)` | tmp_path | `:159-168` |
| Y4 | P0 | `test_extract_sample_offset_math` (parametrised) | duration 100→`-ss 25.0`; 50 (< 60)→`-ss 0`; 200→`-ss 50.0`; ffprobe None→`-ss 0`; argv has `-y`, `-vn -acodec pcm_s16le -ar 16000 -ac 1`, output last | recorder on `subprocess.run` (writes 1 byte to out) | `:106-130` |
| Y5 | P1 | `test_extract_sample_zero_byte_output_is_failure` | False | recorder writes empty file | `:130` |
| Y6 | P1 | `test_extract_sample_ffmpeg_error_logs_truncated_stderr` | False; stderr line ≤ ~220 chars, contains the path | raise `CalledProcessError` with 1 KB stderr | `:131-133` |
| Y7 | P1 | `test_extract_sample_timeout_is_failure` | False, no exception | raise `TimeoutExpired` | `:134` |
| Y8 | P2 | `test_get_duration_bad_json_is_none` | None | ffprobe shim prints garbage | `:100-103` |
| Y9 | P0 | `test_load_model_uses_env_model_and_cpu_int8` | `FakeWhisperModel` constructed with `("tiny", device="cpu", compute_type="int8")` | `sys.modules["faster_whisper"] = fake`; `monkeypatch.setattr(vam, "WHISPER_MODEL", "tiny")` | `:139-142`; proves the module imports without the real package |
| Y10 | P2 | `test_detect_language_does_not_iterate_segments` | a generator that raises on `__next__` is never consumed | fake model | `:145-149` — consuming segments would run full transcription |
| Y11 | P0 | `test_e2e_fresh_run_writes_all_verdicts` | 4 input rows → `MISTAGGED_IS_ITALIAN` (it, 0.97 → `Confidence="0.97"`), `CONFIRMED_NOT_ITALIAN` (en), `FILE_NOT_FOUND` (path absent; `FileSize`/`FileMtime` empty), `EXTRACTION_FAILED` (ffmpeg shim fails for that path; signature **stamped**); header == 11 fieldnames; `DeclaredAudioLanguages` == input `AudioLanguages`; input order preserved; summary counts on stderr | ffmpeg/ffprobe shims on PATH + `FakeModel` via `load_model` | `:258-289`, `:373-423` |
| Y12 | P0 | `test_e2e_detector_exception_marks_row_and_continues` | row 2 `DETECTION_FAILED`, row 3 still verified; `sample_*.wav` removed | FakeModel raises for one path | `:397-409` |
| Y13 | **P0 RED** | `test_detector_returning_none_language_is_detection_failed` | no traceback; row `DETECTION_FAILED`; run completes | FakeModel returns `(None, 0.0)` | **D8** |
| Y14 | P0 | `test_resume_keeps_unchanged_and_reverifies_changed_size` | run 1 (3 files) → append a byte to B → run 2: FakeModel called **only** for B; 3 rows out; stderr `Reusing 2 previous verdict(s)`; A's signature unchanged | — | `:304-314` |
| Y15 | P0 | `test_resume_reverifies_on_mtime_only_change` | `os.utime` +100 s → re-verified | — | `:211` |
| Y16 | P1 | `test_legacy_rows_are_kept_and_stamped` | previous CSV in the 9-column schema → kept without detection, stamped with the current signature | hand-written old CSV | `:200-206`, `:264-274`, docstring `:23-24` |
| Y17 | P0 | `test_retry_errors_reprocesses_only_error_rows` | prev: 1 `FILE_NOT_FOUND` (file now present), 1 `MISTAGGED` → only the error row hits FakeModel | `--retry-errors` | `:197-198` |
| Y18 | P0 | `test_orphan_rows` (parametrised 4) | prev row not in input & file changed → **dropped**, stderr `Dropped 1 stale row(s)`; unchanged → kept; file gone → kept; legacy (no sig) → kept | — | `:325-337`, commit 3c673b0 |
| Y19 | P1 | `test_no_resume_ignores_previous_output` | all rows re-verified; orphans not carried | `--no-resume` | `:294` |
| Y20 | P1 | `test_limit_verifies_first_n_only` | FakeModel called N times, input order | `--limit 2` | `:339` |
| Y21 | **P1 RED** | `test_limit_does_not_lose_previous_verdicts_of_deferred_rows` | prev has verdict for C; C changed; `--limit 1` verifies A → C's **old** row still in output | — | **D12** (needs a decision) |
| Y22 | P1 | `test_output_has_header_and_kept_rows_even_if_detection_crashes` | FakeModel raises `KeyboardInterrupt` on first call → output exists with header + kept rows; temp dir gone | — | `:350-359`, `:424-426` |
| Y23 | **P0 RED** | `test_user_temp_dir_survives_run` | `TEMP_DIR=<tmp_path/keep>` containing `marker.txt` → after the run the dir exists, marker intact, no `sample_*.wav` left | — | **D6** |
| Y24 | P1 | `test_default_temp_dir_removed` | mkdtemp dir removed on both the "nothing to verify" (`:364`) and normal (`:426`) paths | — | cleanup |
| Y25 | P1 | `test_check_disk_space_exits_1_with_message` | `SystemExit(1)`; stderr `need at least` | monkeypatch `shutil.disk_usage` | `:77-86` |
| Y26 | P1 | `test_missing_input_exits_1` | `SystemExit(1)` | — | `:244-248` |
| Y27 | P0 | `test_phase1_csv_literal_roundtrip` | feed the **literal line phase 1 writes** `Radarr,"Hello, ""World""",2003,,"","/m/a, ""b"".mkv"` → output `Title`/`Path` exact | — | cross-phase contract; pairs with S5 |
| Y28 | P1 | `test_empty_path_row_is_file_not_found` | — | — | `:305-307`, `:379` |
| Y29 | P2 | `test_output_directory_created` | nested dir | — | `:250-252` |

### 2.5 `verify/report.py` — pytest (`tests/python/test_report.py`)

| ID | P | Test | Asserts | Fakes | Catches |
|---|---|---|---|---|---|
| R1 | P0 | `test_build_html_neutralises_script_close` | Title `</script><script>alert(1)</script>` → `html.count("</script>") == 1`; contains `<\/script>`; extracted `const DATA = …;` blob `json.loads` == rows | — | `:381-383` |
| R2 | P0 | `test_build_html_data_roundtrip_unicode_and_escapes` | rows with `è`, `"`, `\`, `\u2028`, `<`, `&` round-trip exactly; `ensure_ascii=False` preserved (`è` literal) | — | `:383` |
| R3 | **P0 RED** | `test_unknown_verdict_is_not_interpolated_as_markup` | template contains no `innerHTML = meta.label` (static); after fix, chips built with `textContent` | static on `HTML_TEMPLATE` | **D15** |
| R4 | P0 | `test_read_rows_normalises_columns` | extra `FileSize` dropped; missing `Confidence` → `""`; values `.strip()`ped; row count | tmp CSV (CRLF) | `:71-87` |
| R5 | P1 | `test_read_rows_missing_file_exit_1` | `SystemExit(1)`; stderr `input CSV not found` | — | `:72-75` |
| R6 | P1 | `test_main_default_output_is_csv_with_html_ext` (+ `-o`) | `x.csv`→`x.html`; stderr `Wrote … (N row(s))` | `main(argv)` | `:509-517` |
| R7 | P0 | `test_handler_requires_token` | `/`→403; `/?k=wrong`→403; `/?k=<token>`→200, body == payload, `Content-Length` == len, `Content-Type: text/html; charset=utf-8`; `/anything?k=<token>`→200 | `ThreadingHTTPServer(("127.0.0.1",0), make_handler(...))` in a thread; `http.client` | `:410-434` |
| R8 | **P0 RED** | `test_handler_non_ascii_token_gets_403` | `/?k=%C3%A9` → 403; no `Traceback` in captured stderr | — | **D9** |
| R9 | P1 | `test_handler_no_token_mode_serves_everything` | `token=None` → 200 without `k` | — | `:421` |
| R10 | P1 | `test_favicon_and_robots_204_without_token` | 204 both | — | `:416-419` |
| R11 | P1 | `test_log_message_never_echoes_token` | after a 200 request, captured stderr contains the path but **not** the token | capsys | `:436-439` |
| R12 | P1 | `test_serve_returns_on_enter_and_releases_port` | `serve(html, "127.0.0.1", 0, True)` returns; the printed port binds again immediately | `builtins.input` → `""` | `:444-481` |
| R13 | P2 | `test_serve_prints_token_url_and_warning` | stderr `http://127.0.0.1:<port>/?k=` and `treat the URL as sensitive` | — | `:453-468` |
| R14 | P2 | `test_html_is_self_contained` | no `<script src=`, `<link `, `http(s)://` in `<head>` | — | `:6`, `:11` contract |

### 2.6 `arr-language-audit.sh` — bats, sourced (`tests/bats/orchestrator.bats`)

`setup`: `export ARR_PLAIN_MENU=1`; `source "$ROOT/arr-language-audit.sh"` (needs the `BASH_SOURCE` guard); then reassign `REPORTS_DIR CSV VERIFIED_CSV HTML ENV_FILE SCAN_SH VERIFY_SH REPORT_PY` into `$BATS_TEST_TMPDIR`.

| ID | P | Test | Asserts | Fakes | Catches |
|---|---|---|---|---|---|
| O1 | P0 | `recommended_action state machine` (7 cases) | `ENV_READY=false`→8; no CSV→1; `PHASE2_READY=false`→6; no verified→2; CSV newer than verified→2; verified newer than HTML→3; all fresh→4 | `touch -t 202001010000` ordering | `:288-295` (commit 93c3add) |
| O2 | P1 | `recommended_hint wording` | 1/2/3/4/6/8 → documented strings; unknown → `""` | — | `:298-308` |
| O3 | P0 | `verdict_summary counts a real CRLF phase-2 CSV` | `2 mistagged / 1 confirmed not Italian / 3 errors`; all-zero file → `0 mistagged / 0 … / 0 errors` (BSD `grep -c` prints `0` with rc 1 — verified); missing → `not run yet` | CSV written with `python3 -c csv` | `:276-283` |
| O4 | P1 | `csv_row_count` | missing→`-`; header only→`0`; header+3→`3` | — | `:267-274` |
| O5 | P0 | `probe_app` | placeholder key → `not configured` rc 1; fake server → `OK   v4.0.0.1234   [Radarr]   <url>` rc 0; wrong key → `UNREACHABLE` rc 1 **and** exactly 3 requests logged; `\r` in body stripped | fake server | `:162-185` |
| O6 | P0 | `run_preflight` | sets `RADARR_OK`/`SONARR_OK`/`ENV_READY`; `SKIP_SONARR=true` → `skipped (SKIP_SONARR=true)`; `PHASE2_NOTE` for system python / venv / missing | `python3` shim; temp `.env` | `:204-261` |
| O7 | **P0 RED** | `run_preflight does not execute .env` | `.env` with `$(echo INJECTED >&2)` → stderr lacks `INJECTED` | — | **D7** (orchestrator copy) |
| O8 | P0 | `ask_yesno plain: Enter honours default; y/n override` | `ask_yesno q yes <<< ""` rc 0; `<<< "n"` rc 1; default no + `""` rc 1 | — | `:84-89` |
| O9 | **P0 RED (macOS)** | `ask_yesno/ask_menu under whiptail shim on bash 3.2` | `HAVE_WHIPTAIL=true`; `ask_yesno q yes` → shim arglog has `--yesno` and **no** `--defaultno`, rc from shim; `ask_menu "" title 1 a` runs | `whiptail` shim logging `"$@"`, exit `${FAKE_WT_RC:-0}` | **D4 `:81`, `:113`** |
| O10 | P1 | `ask_menu plain: empty → default tag, explicit → chosen` | — | stdin | `:104-126` |
| O11 | P0 | `action_scan forwards FORCE_RESCAN and --refresh` | answers `y y` → shim env log `FORCE_RESCAN=true`, args `<CSV> --refresh`; `n n` → `FORCE_RESCAN=false`, no `--refresh` | `SCAN_SH` recorder shim; `ENV_READY=true` | `:338-347` → pairs with S25 |
| O12 | P0 | `action_verify forwards model/limit/retry and guards preconditions` | no CSV → `No phase 1 CSV yet`, shim not called; `PHASE2_READY=false` → `faster-whisper is not installed`; happy path: env log `WHISPER_MODEL=tiny LIMIT=5 RETRY_ERRORS=true`, args `<CSV> <VERIFIED_CSV>` | `VERIFY_SH` shim; stdin `tiny\n5\ny\n\n` | `:351-393` |
| O13 | **P1 RED (macOS)** | `action_serve blank port passes only --serve` | args `<VERIFIED_CSV> --serve`; port `8080` → `--serve --port 8080` | `python3` shim (invoked as `python3 "$REPORT_PY"`) | **D4 `:473`** |
| O14 | P1 | `action_reset deletes only csv/html/cache.json after confirmation` | `y` → those gone, `notes.txt` stays, stderr `Removed 3 file(s)`; `n` → nothing removed; empty dir → `Nothing to reset` | — | `:531-556` (a5701d4) |
| O15 | P1 | `action_configure creates .env from example with mode 600` | exists; perms 600; content == `.env.example`; `EDITOR=true` | — | `:558-563` |
| O16 | P1 | `main exits on 0 and reports unknown choices` | stdin `x\n0\n` → stderr `unknown choice: x` then `Bye.`; finishes under `timeout 30` | `.env` absent → probes say `not configured` (fast) | `:583-621` |
| O17 | P2 | `-h prints the header comment` | exit 0; stdout contains `interactive orchestrator` | — | `:56-61` |

RED on current code: S1 S2 S3 S6 S9 S25 S26 · V1 V13 · Y2(None) Y13 Y21 Y23 · R3 R8 · O7 O9 O13 · L1 L2 (lint).

---

## 3. Harness layout

### 3.1 Tree

```
tests/
├── bats/
│   ├── lint.bats                      # L3 static grep, L4 bash-version self-check, L6 --help
│   ├── scan.bats
│   ├── verify_launcher.bats
│   ├── orchestrator.bats
│   ├── helpers/
│   │   ├── common.bash                # loads bats-support/bats-assert; ROOT; BASH_UNDER_TEST=${BASH_UNDER_TEST:-/bin/bash}; make_bin(); wait_for_file()
│   │   ├── fake_arr.bash              # start_fake_arr <fixture-dir> / stop_fake_arr / arr_requests <jq-filter> / arr_control <json>
│   │   └── shims.bash                 # install_shim ffmpeg|ffprobe|python3|df|uname|whiptail|apt|recorder → $BATS_TEST_TMPDIR/bin
│   ├── fakes/bin/                     # the shims (bash 3.2-safe, executable)
│   │   ├── ffmpeg  ffprobe  python3  df  uname  whiptail  apt  jq-crlf  recorder
│   └── fixtures/
│       ├── radarr/{system_status.json, movies.json, movies_all_italian.json, movies_edge_cases.json, rootfolder.json, health.json}
│       └── sonarr/{system_status.json, series.json, series_changed_size.json, episodes_1.json, episodes_2.json, episodefile_77.json}
├── fakes/
│   ├── fake_arr_server.py             # stdlib http.server; see 3.3
│   └── pypath/faster_whisper/__init__.py   # fake WhisperModel; see 3.5
└── python/
    ├── conftest.py                    # sys.path += verify/; fixtures: fake_model, shim_path, phase1_csv(), prev_csv(), media_file()
    ├── test_verify.py  test_resume.py  test_report.py
pyproject.toml     # [tool.ruff] target-version="py310" line-length=110 select=[E,F,W,I,UP,B,SIM,PL,RUF,DTZ,BLE]
                   # [tool.pytest.ini_options] testpaths=["tests/python"] pythonpath=["verify","tests/python","tests/fakes/pypath"]
.shellcheckrc      # shell=bash  external-sources=true  source-path=SCRIPTDIR  disable=SC1090,SC1091
scripts/test.sh    # lint | bats | py | all
.github/workflows/ci.yml
```

No `__init__.py` anywhere; `verify/` stays a plain directory. `.gitignore` gains `.venv/ .pytest_cache/ .ruff_cache/`. Fixtures are **synthetic** (invented titles, `/media/movies/...` paths, dummy keys): the real reports contain filesystem paths and API keys — never copy a real one into a fixture.

### 3.2 Running locally

```
scripts/test.sh lint   → shellcheck -S warning arr-language-audit.sh scan/*.sh verify/*.sh
                         uvx ruff check verify tests/python
scripts/test.sh py     → uvx --python 3.12 pytest -q ; uvx --python 3.10 pytest -q   (floor)
scripts/test.sh bats   → PATH="/bin:/usr/bin:$PATH" bats -r tests/bats               (forces /bin/bash on macOS; §3.6)
```

Nothing is installed into the project: `uvx` resolves pytest/ruff into its own cache and `conftest.py` is stdlib-only. `pytest` still picks up `pyproject.toml` from the rootdir when launched via `uvx`.

### 3.3 Fake Radarr/Sonarr server (`tests/fakes/fake_arr_server.py`)

- Stdlib `http.server.ThreadingHTTPServer`, binds `127.0.0.1:0`, writes the bound port to `$FAKE_ARR_PORTFILE` after `server_bind` (bats polls the file ≤ 5 s).
- **One process serves both apps** under URL-base prefixes: `RADARR_URL=http://127.0.0.1:$PORT/radarr`, `SONARR_URL=…/sonarr`. The scripts build `"$RADARR_URL/api/v3/…"` and real *arr supports a URL base, so this is in-contract.
- Routes → fixture files under `<fixture-dir>/<app>/`: `/api/v3/system/status`, `/movie`, `/series`, `/episode?seriesId=N&includeEpisodeFile=true` → `episodes_N.json`, `/episodefile/N` → `episodefile_N.json`, `/rootfolder`, `/health`, `/ping` (no auth, `{"status":"OK"}`), `POST /command` → `{"id":42}`, `GET /command/42` → next element of `command_status` (last value repeats).
- Auth: header `X-Api-Key` must equal `FAKE_RADARR_KEY` / `FAKE_SONARR_KEY`, else **401** (which `curl -f` turns into a failure, exactly like the real thing).
- Control file `$FAKE_ARR_CONTROL` (JSON, re-read on every request, edited by tests with `jq`):
  `{"fail_count": {"/sonarr/api/v3/series": 2}, "command_status": ["queued","completed"], "crlf": false}`.
- Request log `$FAKE_ARR_LOG` (JSONL): `{"method","path","query","key_ok","body"}`. Tests assert "endpoint X was / was not called" with `jq -c 'select(.path=="…")' | wc -l`.
- bats: `setup()` → `start_fake_arr "$FIXTURES"` (background `python3 …&`, `FAKE_ARR_PID=$!`); `teardown()` → `kill "$FAKE_ARR_PID"`. Per-test start is ≈150 ms; per-test isolation beats `setup_file` + log clearing.

### 3.4 PATH shims (`tests/bats/fakes/bin/`)

- `ffprobe` — prints `{"format":{"duration":"<d>"}}`, `d` from `FAKE_DURATIONS` (JSON map path→seconds; default 600). bash + jq so the same file serves pytest and bats.
- `ffmpeg` — parses `-i <in>`; if `<in>` matches `FAKE_FFMPEG_FAIL` (substring) → `echo "Invalid data found when processing input" >&2; exit 1`; else writes a **valid 44-byte RIFF/WAVE header** (16 kHz mono s16le, via `printf` byte escapes) followed by `FAKEWAV:<in>\n` to the last argument, and appends argv to `$FAKE_FFMPEG_LOG`.
- `python3` — dispatch on argv: `--version` → `Python ${FAKE_PY_VERSION:-3.12.0}`; `-m pip --version` → exit `!FAKE_PY_HAS_PIP`; `-m venv DIR` → `mkdir -p DIR/bin`, and iff `FAKE_PY_VENV_OK=1` create executable `DIR/bin/pip`; `-c *faster_whisper*` → exit `!FAKE_PY_HAS_FW`; `-c *version_info*` → echo `${FAKE_PY_VERSION%.*}`; an argument ending in `.py` → append `"$@"` + `env | grep -E '^(WHISPER_MODEL|LIMIT|RETRY_ERRORS|NO_RESUME|SAMPLE_)'` to `$FAKE_PY_ARGLOG`, exit `${FAKE_PY_EXIT:-0}`. (Y-tests use the real interpreter, not this shim.)
- `df` — `printf 'Filesystem 1M-blocks Used Available Capacity Mounted on\nfake 100000 1 %s 1%% /\n' "$FAKE_DF_AVAIL_MB"` + arglog.
- `uname` → `${FAKE_UNAME:-Linux}`; `apt` → exit 0 (presence only); `whiptail` → arglog, prints `${FAKE_WT_OUT:-}` on fd 1 (the script reads the result through `3>&1 1>&2 2>&3`), exit `${FAKE_WT_RC:-0}`.
- `recorder` — generic: appends `$0 "$@"` and selected env to `$RECORDER_LOG`; symlinked as the fake `SCAN_SH` / `VERIFY_SH` in orchestrator tests.
- Test PATH is always `"$BATS_TEST_TMPDIR/bin:/usr/bin:/bin"` — never the developer's PATH (Homebrew `ffmpeg`, `whiptail`, or Ubuntu's `apt` would leak in).

### 3.5 Fake faster-whisper (`tests/fakes/pypath/faster_whisper/__init__.py`)

```python
import json, os

class _Info:
    def __init__(self, language, prob):
        self.language, self.language_probability = language, prob

def _source_of(wav_path):            # "FAKEWAV:<media path>" written by the ffmpeg shim
    with open(wav_path, "rb") as f:
        data = f.read()
    marker = data.rfind(b"FAKEWAV:")
    return data[marker + 8:].decode().strip() if marker >= 0 else ""

def _script():                        # FAKE_WHISPER_SCRIPT = path to JSON {"<media path>": ["it", 0.97] | "RAISE", "*": ["en", 0.9]}
    p = os.environ.get("FAKE_WHISPER_SCRIPT")
    return json.load(open(p)) if p else {}

class WhisperModel:
    instances, calls = [], []
    def __init__(self, model_size_or_path, device=None, compute_type=None, **kw):
        self.args = (model_size_or_path, device, compute_type)
        WhisperModel.instances.append(self)
    def transcribe(self, wav_path, **kw):
        src = _source_of(wav_path)
        WhisperModel.calls.append(src)
        rule = _script().get(src, _script().get("*", ["en", 0.9]))
        if rule == "RAISE":
            raise RuntimeError("scripted failure")
        def _segments():              # must never be iterated (Y10)
            raise AssertionError("segments were consumed")
            yield
        return _segments(), _Info(*rule)
```

- **pytest**: `conftest` fixture `fake_model` sets `sys.modules["faster_whisper"]` to this module (so Y9 can exercise `load_model()` itself) and `monkeypatch.setattr(vam, "load_model", lambda: WhisperModel("x"))` for the e2e tests; `pythonpath` in `pyproject.toml` already makes the package importable.
- **bats / launcher e2e** (optional P1: one test running the real `verify_audio_language.py` through the launcher with real `python3.12`): `PYTHONPATH=tests/fakes/pypath` makes `python3 -c "import faster_whisper"` succeed at `verify-audio-language.sh:261`, and the worker's lazy import at `:140` picks up the fake. No `sys.modules` hack needed there.

### 3.6 CI (`.github/workflows/ci.yml`)

```yaml
name: ci
on: [push, pull_request]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get install -y shellcheck
      - run: shellcheck -S warning arr-language-audit.sh scan/*.sh verify/*.sh
      - uses: astral-sh/setup-uv@v5
      - run: uvx ruff check verify tests/python

  bats:
    strategy:
      fail-fast: false
      matrix: { os: [ubuntu-latest, macos-latest] }
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: bats-core/bats-action@3.0.1          # installs bats + bats-support/assert/file via git; no npm
      - uses: actions/setup-python@v5
        with: { python-version: "3.12" }            # for the fake server / real-worker e2e only
      - run: command -v jq || brew install jq        # both images ship jq; belt and braces
      - name: bats (forced /bin/bash so macOS really runs 3.2)
        run: PATH="/bin:/usr/bin:$PATH" bats -r tests/bats
        env: { BASH_UNDER_TEST: /bin/bash }

  pytest:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest]
        python: ["3.10", "3.12", "3.13"]            # 3.10 = declared floor (decision pending, see §4)
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: astral-sh/setup-uv@v5
      - run: uvx --python ${{ matrix.python }} pytest -q
```

**Gotcha that would silently defeat the macOS leg:** GitHub's macOS images ship Homebrew bash 5 with `/opt/homebrew/bin` early in `PATH`, so `#!/usr/bin/env bash` resolves to bash 5, not the 3.2 we want to prove against. Hence: (a) every bats test runs scripts as `run "$BASH_UNDER_TEST" "$SCRIPT" …`; (b) sourced-orchestrator tests need bats itself under `/bin/bash`, hence the `PATH="/bin:/usr/bin:$PATH"` prefix; (c) L4's self-check `[[ ${BASH_VERSINFO[0]} -eq 3 ]]` when `RUNNER_OS == macOS` fails loudly if a future image change breaks this.

Alternative to `bats-action`: vendor `bats-core`, `bats-support`, `bats-assert` as pinned git submodules under `tests/bats/lib/` and call `tests/bats/lib/bats-core/bin/bats`. Identical behaviour locally and in CI, no third-party action, one `git submodule update --init` step. Both are npm-free; the submodule route is the more reproducible one if the repo owner accepts submodules.

Dependabot (`.github/dependabot.yml`) should gain a `github-actions` ecosystem entry so the pinned action versions get bumped.

---

## 4. Order of work

1. Harness skeleton + L1–L5 (lint gates), fake server, shims, fake whisper — no product code touched.
2. Land the two seam refactors: orchestrator `BASH_SOURCE` guard + `ARR_PLAIN_MENU`; `main(argv=None)` in both `.py`. Zero behaviour change; O1–O4, R1–R2, R4–R7, Y1, Y3–Y12, Y14–Y20 go green immediately.
3. RED tests first, fix in the same commit, one logical change per commit (`fix(scan): …`, `fix(verify): …`, `fix(report): …`):
   D1/D2 (S1–S3, S6) → D3/D4 (L3, L4, V1, O9, O13) → D6 (Y23) → D10 (S9, S10) → D11 (S25, O11) → D7 (S26, O7) → D5 (V13, L5) → D8 (Y2, Y13) → D9 (R8) → D15 (R3) → D12 (Y21, after the decision).
4. Remaining P1s, then the optional P2s (wizard, CRLF, `--check` position).

Decisions needed from the lead before step 3:
- **Python floor**: 3.10 + explicit `sys.version_info` guard and launcher check (recommended — matches `str | None` usage and lets ruff `target-version=py310` stand), or `from __future__ import annotations` to keep 3.9 alive.
- **D12 semantics for `--limit`**: carry deferred rows' previous verdicts (recommended), or document the loss.
- **D10 exit code**: 2 for "completed with a failed app fetch" is the proposal; the README exit-code tables need the same edit in both languages.

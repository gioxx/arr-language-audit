# PR follow-up audit

Date: 2026-09-05. Baseline: `perf/deep-audit-hardening` at `f894e19`, the
head of [upstream PR #1](https://github.com/gioxx/arr-language-audit/pull/1)
when this review started. The working tree was clean.

## Scope and method

Reviewed all product entry points and their shared helpers, the existing PR
description and audit decisions, tests, CI, dependencies and documentation.
Three implementation agents owned separate areas: phase 1/cache, phase 2/audio
and resume, shell orchestration/security. The coordinator handled report
integrity, report interaction tests, external API validation and integration.
A fresh independent reviewer checked the combined changes and reproduced the
remaining findings before approving their corrections.

The starting suite passed: 152 Bash tests and 163 Python tests, with Python
3.9 and 3.12 exercised locally. Passing those tests did not establish that the
fakes matched real dependency contracts. Each behavioral correction below was
preceded by a failing reproduction or regression test.

## Findings and corrections

| Priority | Finding and resulting behavior | Evidence |
|---|---|---|
| P1 | `detect_language(audio=...)` received a filename. faster-whisper 1.2.1 requires decoded audio; the worker now passes a float32 waveform at 16 kHz. The fake rejects undecoded paths. | `tests/integration/test_whisper_contract.py`, detection and harness tests |
| P1 | Failed Sonarr episode/file requests and malformed payloads could publish incomplete CSV/cache as success. They now exit 2 and preserve the previous outputs. | `tests/bats/scan.bats` |
| P1 | Cache v2 could reuse another instance's or a renamed series' rows. Cache v3 includes source URL, series identity, validated statistics and original media paths. | Scan cache regressions; ADR 0004 |
| P1 | Predictable scan temporary names could follow a pre-existing symlink. Private sibling files now use `mktemp`; report/cache modes are 0600. | Scan temporary-path regression |
| P1 | Output destinations could replace input CSV or media. All three output producers reject collisions with known media, including aliases. Scan includes Italian-tagged media and cached paths. Paths are compared without trimming filename whitespace. | Scan S58–S63; worker/report integrity tests; independent reproductions |
| P1 | `.curlrc` could add recipients of the API key; CR/LF in keys could inject headers. `curl -q` ignores implicit configuration and newline-bearing keys are rejected. | `tests/bats/lib_common.bats`, loopback-only reproduction |
| P1 | Pipeline actions lost exit status and continued with old CSVs after errors/cancellation. Actions propagate status and subsequent stages stop. | `tests/bats/orchestrator.bats` |
| P1 | Invalid CSV inputs and interrupted retries could discard prior results. CSV structure is validated first, initial publication is atomic and controlled aborts retain pending previous verdicts, including relabels. | `test_worker_hardening.py`, `test_resume.py` |
| P2 | Integer mtime lost changes within one second. New signatures preserve nanoseconds; old signatures retain their original precision until re-verification. | Worker signature/resume regressions |
| P2 | NaN, negative limits, invalid probabilities and malformed ffprobe data bypassed checks or crashed processing. Invalid values now fail explicitly or become per-file errors; internal detector TypeErrors do not masquerade as old APIs. | Worker hardening/detection tests |
| P2 | Failed extractions retained partial WAVs; interpreter/setup probes inherited API keys. Samples are cleaned immediately and unrelated children receive no Arr keys. | Worker and shell regressions |
| P2 | Preflight accepted HTTP success without a status object; reconfiguration edited the wrong dotenv file; disk checks mishandled leading zeroes/overflow. These now validate the expected data and preserve the active configuration. | Orchestrator and launcher regressions |
| P2 | Rescan status-polling requests and sleeps could exceed the declared budget. They now use the remaining timeout and decimal bounds are checked; the initial POST uses ARR_TIMEOUT. | Scan timeout regressions |
| P2 | Repeated template substitution corrupted titles containing placeholders; prototype-named verdicts disappeared. Substitution now runs once and unknown verdicts remain visible. Malformed report CSV and invalid ports fail before output replacement. | `test_report_integrity.py`, report DOM tests |
| P2 | Filters/sorting lacked keyboard controls; copy could use a stale search, fail silently or claim success before permission. Native buttons expose state; copy uses the current filter, deduplicates paths and offers selected text on failure. | `tests/report-ui/report.test.mjs`, live Chrome verification |

## Dependency contract evidence

The pinned [faster-whisper 1.2.1 implementation](https://github.com/SYSTRAN/faster-whisper/blob/v1.2.1/faster_whisper/transcribe.py)
expects an audio array in `WhisperModel.detect_language`; unlike `transcribe`,
it does not decode a filename itself. The new integration test runs its real
PyAV decoder, feature extractor and detection method, replacing only VAD
decisions and neural outputs. No model weights are initialized or downloaded.
The contract stage disables model-hub networking and overrides pytest's normal
fake package path. CI exercises this separately on Python 3.9 and 3.12.

The Sonarr `includeEpisodeFile` request and nullable/string `audioLanguages`
shape were checked against the official [episode controller](https://github.com/Sonarr/Sonarr/blob/develop/src/Sonarr.Api.V3/Episodes/EpisodeController.cs)
and [OpenAPI schema](https://github.com/Sonarr/Sonarr/blob/develop/src/Sonarr.Api.V3/openapi.json).
This is source validation, not a live instance test.

## Verification and limits

The final integrated `./scripts/test.sh all` run completed with exit status 0
on the final working tree:

| Check | Result |
|---|---|
| ShellCheck and Ruff | Passed |
| Python regression suite | 246 passed on Python 3.9; 246 passed on Python 3.12 |
| Bash regression suite | 189 passed under macOS Bash 3.2 |
| Report DOM interactions | 6 passed |
| Installed faster-whisper contract | 1 passed on Python 3.12, without model downloads |
| Patch whitespace and report test dependency audit | Clean; zero reported npm vulnerabilities |

This covers 442 distinct test cases, 127 more than the starting suite. The
Python regression suite runs twice to verify both supported local interpreters.

The independent reviewer reproduced the remaining report/scan media collisions,
then confirmed that each now exits with an error and preserves the media
byte for byte. No material findings remained in the reviewed final code.

Live Chrome checks used 2,105 synthetic rows: the 2,000-row cap, keyboard
filtering and sorting, search for literal template/HTML text, prototype-named
verdicts and manual copying with clipboard access unavailable. The repeatable
DOM suite additionally checks denied clipboard permission, copy during debounce,
duplicate paths and copying all filtered results beyond the display cap.

Intentional limits remain:

- No live Radarr/Sonarr instance, real media library or Whisper model accuracy
  was tested. The real decoder contract does not measure language accuracy.
- Phase 2 still samples the default audio track (or the first) and a limited
  window. A secondary Italian track can be missed; changing this policy needs
  a separate product decision and representative audio fixtures.
- Sonarr tag-only changes can leave count/size unchanged; use `--refresh` or
  `FORCE_RESCAN=true`. Cache v3 requires one initial rebuild.
- Worker appends remain vulnerable to a forced kill, power loss or I/O failure
  mid-row. Controlled interrupts are covered; full crash durability would need
  a journal or a different persistence design.
- CSV and cache publication are individually atomic, not one joint transaction.
  A cache-write warning does not invalidate an otherwise complete CSV.
- `.curlrc` is deliberately ignored; use curl's standard environment settings
  for proxy/CA configuration. Outputs are private by default.
- Linux validation of these final changes belongs to the new CI run after push.
  Older green checks on `f894e19` are not evidence for the modified working tree.

The additional real-dependency check on local Python 3.9.6/NumPy 2.0.2 passed
with three `matmul` RuntimeWarnings from Apple Accelerate. A warning-as-error
diagnostic fails there. Even identity-matrix multiplication reproduces the
warnings with an exact result; the original audio fixture and a 440 Hz sine
both produced finite features consistent with an independent float64 `einsum`
calculation (maximum relative matrix error 1.60e-7, absolute feature error
1.21e-7). Python 3.12.13/NumPy 2.5.2 showed no warnings on the same backend.
This is consistent with [NumPy issue 29820](https://github.com/numpy/numpy/issues/29820)
and [upstream fix 30102](https://github.com/numpy/numpy/pull/30102), and does not
establish model accuracy. No warnings were suppressed or dependency bounds
changed to conceal this environment-specific behavior.

Large module splits, concurrent Sonarr fetching, sample prefetching and a new
multi-track classification policy were not introduced: they are separate design
changes, not required to repair the reproduced defects.

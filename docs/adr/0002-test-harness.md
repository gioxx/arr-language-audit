# 2. Test harness: bats-core and pytest over fakes, never real tools

- Status: accepted
- Date: 2026-09-05
- Deciders: repository maintainers

## Context

The project is roughly half bash (orchestrator, phase 1 scan, phase 2 launcher)
and half Python (phase 2 worker, HTML report, shared constants), and it had no
automated tests at all. The behaviour worth protecting is the awkward kind:
exit codes, resume bookkeeping, cache invalidation, CSV quoting, bash 3.2
portability. Meanwhile everything it does in production is expensive or
unavailable in CI — a real run needs Radarr and Sonarr with API keys, media
files on disk, `ffmpeg`, and a whisper model from Hugging Face. A suite that
needs those runs nowhere, and a suite that runs nowhere is not a suite.

## Decision

Two runners, one per language, chosen so each tests its own code in its own
idiom rather than through a wrapper:

- **bats-core** for the shell entry points, with `bats-support` and
  `bats-assert` vendored under `tests/bats/lib` so a clone needs only `bats`.
- **pytest** for the Python modules, with `pythonpath` in `pyproject.toml`
  putting `verify/` on `sys.path`: the repository ships scripts, not a package.

**No test touches the network, ffmpeg, or whisper.** Every external tool is a
fake, driven purely by environment variables:

- `tests/bats/fakes/bin` shims `curl`, `ffmpeg`, `ffprobe`, `python3`, `df`,
  `uname`, `whiptail`, `apt`, plus a counting `jq` that records each invocation
  before exec'ing the real one, and a generic `recorder` that stands in for any
  script the orchestrator shells out to.
- `tests/fakes/fake_arr_server.py` is a real HTTP server on `127.0.0.1` serving
  both apps under `/radarr` and `/sonarr` URL bases from the JSON fixtures, so
  the scripts build URLs exactly as in production; a control file makes it fail
  a path N times, answer with CRLF, or delay a response.
- `tests/fakes/pypath/faster_whisper` is a stub package: it reads the marker the
  `ffmpeg` shim wrote into the "sample" and answers from a JSON script, so a
  test declares what language a file "is" without decoding a byte of audio.

`scripts/test.sh {lint|py|bats|all}` is the single entry point, and CI calls the
same script, so the two cannot drift. `ruff` and `pytest` run through `uvx`:
nothing is installed into the project.

## Consequences

- The suite runs offline, on a laptop, in seconds, and CI is a matrix rather
  than a special environment.
- A fake is code that can be wrong. The stubs are deliberately dumb — replay,
  not reimplementation — but a real *arr API change still lands as a production
  bug, not a red test.
- The shims mean a test asserts on argv, not on effects: `ffprobe` is pinned to
  an exact argument list, which catches a silent flag change and also breaks on
  a harmless one.
## Alternatives considered

- **shunit2 / a hand-rolled bash runner.** Rejected: bats-core has TAP output,
  per-test isolation and `run`/`assert_*` that CI understands.
- **Driving the shell scripts from pytest via `subprocess`.** Rejected: it puts
  bash failures behind a Python traceback and makes the bash 3.2 gate awkward
  to express.
- **Recorded HTTP cassettes instead of a fake server.** Rejected: the scan's
  retry, timeout and rescan-polling paths are about *when* the server answers,
  which a cassette cannot express.
- **Integration tests against a disposable Radarr in Docker.** Rejected here:
  slow, and it still would not cover whisper. Worth a separate optional job.

# 1. Compatibility floors: bash 3.2 and Python 3.9

- Status: accepted
- Date: 2026-09-05
- Deciders: repository maintainers
- Supersedes: —

## Context

The README promises Linux and macOS, and phase 1 is the kind of thing an
operator runs on whatever box already talks to Radarr and Sonarr. A stock macOS
install is therefore a first-class target, and it ships:

- `/bin/bash` at **3.2.57** — Apple has not shipped a GPLv3 bash and will not.
  Homebrew's bash 5 is on some machines, but `sudo`, a `PATH` without
  `/opt/homebrew/bin`, or a LaunchAgent all land back on 3.2.
- a system **Python 3.9** — the interpreter phase 2 falls back to when there is
  no `verify/venv` and no `PYTHON_BIN`.

Without a stated floor these surface as bug reports: `mapfile: command not
found` from phase 1, or a `TypeError` from a 3.10-only annotation halfway
through a multi-hour phase 2 run.

## Decision

The supported floors are **bash ≥ 3.2** and **Python ≥ 3.9**, enforced rather
than merely documented:

- No bash 4+ construct in any shipped script — no `mapfile`/`readarray`,
  `declare -A`, `${var,,}`, `local -n`, `&>>` or `|&`; `tests/bats/lint.bats`
  greps the sources for each and fails on a hit.
- The bats suite runs with `PATH="/bin:/usr/bin:$PATH"` and
  `BASH_UNDER_TEST=/bin/bash`, locally and in CI, so the macOS job genuinely
  exercises 3.2 rather than Homebrew's 5.x; a second test asserts it really is
  on bash 3 there.
- Every Python module starts with `from __future__ import annotations`, so
  modern annotation syntax stays a string on 3.9. `check_python_floor()` refuses
  anything older, and the phase 2 launcher checks the chosen interpreter's
  version in its pre-flight, not mid-run. The pytest matrix includes 3.9.

`jq` is documented at ≥ 1.6 (the 2018 release, and what every current distro
ships). Nothing in the code checks a jq version: the phase 1 programs use only
builtins that predate 1.6, so the floor is a support statement, not a gate.

## Consequences

- Phase 1 pays for portability in verbosity: no associative arrays means the
  `.env` allow-list is a space-delimited string matched with `case`, and reading
  lines into an array is a `while read` loop.
- CI is slower and wider: macOS runners and a 3.9 interpreter are both extra
  jobs, and `fail-fast: false` means a floor break is reported per-cell.
- Raising a floor is now a visible decision — a new ADR and a CI matrix edit —
  rather than something a convenient one-liner does by accident.

## Alternatives considered

- **Require bash 4+ and tell macOS users to `brew install bash`.** Rejected:
  it turns "clone and run" into "install a package manager first", and the
  failure mode when they do not is a cryptic builtin error, not a clear message.
- **Re-exec into a newer bash found on `PATH`.** Rejected: the interpreter that
  actually runs would depend on the machine, so a bug reproduces on one box and
  not on another.
- **Python 3.11 floor (walrus everywhere, `tomllib`, better error messages).**
  Rejected: it would force every macOS user into a venv before phase 2 can run
  at all, which is exactly the friction the launcher's fallback chain exists to
  avoid.

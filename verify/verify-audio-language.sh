#!/usr/bin/env bash
#
# Phase 2 of arr-language-audit.
#
# Pre-flight checks + launcher for verify_audio_language.py.
#
# Takes the CSV produced by phase 1, and for each suspect file extracts a
# short audio sample with ffmpeg and runs local language detection with
# faster-whisper (CPU, no external service) to find out what language is
# ACTUALLY spoken. The Python script writes a second CSV with a verdict
# per file. No media file is ever modified.
#
# This script does NOT install anything automatically: if a dependency is
# missing it prints the exact command to install it and stops, so you stay
# in control of what gets installed on your machine.
#
# Requirements: bash 3.2, ffmpeg, ffprobe, Python 3.9+ with faster-whisper
#               (faster-whisper usually lives in ./venv -- see the recipe the
#               script prints when it cannot find it)
#
# Design notes that matter when changing this file:
#
#   * The interpreter is chosen ONCE, by lib/common.sh's find_phase2_python:
#     PYTHON_BIN, then the venv beside this script, then python3 -- and only
#     an interpreter that can actually `import faster_whisper` is accepted.
#     The system pip and venv-capability probes are diagnostics for the case
#     where nothing was found; running them on every launch cost seconds on a
#     NAS and made a perfectly good venv fail the pre-flight.
#   * The venv directory is derived from THIS script's location, not from the
#     library's, so a copy of the tree uses its own venv.
#   * bash 3.2 (the /bin/bash macOS ships): "${arr[@]}" on an EMPTY array under
#     `set -u` is an error before bash 4.4, so the worker's optional arguments
#     are expanded as ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}. This is not a style
#     preference: the plain form aborted the DEFAULT configuration on macOS.
#   * The worker never needs the *arr API keys, and it shells out to ffmpeg for
#     every file, so the keys are removed from the environment it inherits.
#
# Usage, arguments, environment and exit codes: --help (the usage() below is
# the single copy of all four).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" > /dev/null 2>&1 && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." > /dev/null 2>&1 && pwd)"
PYTHON_SCRIPT="$SCRIPT_DIR/verify_audio_language.py"
VENV_DIR="$SCRIPT_DIR/venv"
REQUIREMENTS="$REPO_ROOT/verify/requirements.txt"

# Set by detect_os_hint, read by the hint printers.
OS_HINT="your package manager"

# Globals a function fills in for main: bash 3.2 has no clean way to return an
# array, and no namerefs.
CHECK_ONLY=0
POSITIONAL=()
EXTRA_ARGS=()

usage() {
    cat <<'EOF'
Phase 2 of arr-language-audit -- verify the real spoken language.

Pre-flight checks + launcher for verify_audio_language.py. Reads the CSV
from phase 1, extracts a short audio sample per file with ffmpeg, and uses
faster-whisper (local, CPU) to detect the language actually spoken. Writes
a verdict CSV: MISTAGGED_IS_ITALIAN (false positive, only the tag is wrong)
vs CONFIRMED_NOT_ITALIAN (real action needed: redownload or remux).

Nothing is installed automatically and no media file is modified.

Usage:
  verify-audio-language.sh [INPUT_CSV] [OUTPUT_CSV]
  verify-audio-language.sh --check            (check the environment only, no run)
  verify-audio-language.sh -h | --help

--check is accepted in any position, so "verify-audio-language.sh in.csv --check"
checks the environment for that input without running anything.

Arguments:
  INPUT_CSV   CSV from phase 1  (default: <repo>/reports/missing-italian-audio.csv)
  OUTPUT_CSV  verdict report    (default: <repo>/reports/verified-language-results.csv)

Environment variables (a <repo>/.env file supplies them too; a value already
in the environment wins over the file):
  PYTHON_BIN         interpreter to run phase 2 with  (default: see below)
  WHISPER_MODEL      tiny | base | small | medium            (default: small)
  SAMPLE_SECONDS     audio sample length, in seconds         (default: 60)
  SAMPLE_OFFSET_PCT  where to start sampling, % of duration  (default: 25)
  MIN_FREE_SPACE_MB  minimum free space required, in MB      (default: 500)
  TEMP_DIR           PARENT directory for the temporary audio samples: the run
                     creates its own lang-check-* directory inside it and
                     removes only that one           (default: the system temp)
  LIMIT              only (re)verify the first N files that need it (testing)
  RETRY_ERRORS       true to also reprocess previously failed rows
  NO_RESUME          true to ignore an existing OUTPUT_CSV and start fresh
verify_audio_language.py --help documents the rest (MIN_CONFIDENCE,
WHISPER_THREADS); they are passed through from .env and the environment too.

Resume reuses verdicts for files whose size and mtime are unchanged; a file
that was replaced since the last run is re-verified automatically. A row whose
file is no longer in the phase 1 CSV is dropped when that file also changed on
disk (it was fixed), and kept otherwise (narrower scan scope, or file gone).
Use the orchestrator's "Reset reports" to wipe reports/ and start from scratch.

Which Python runs phase 2, in order: $PYTHON_BIN if it can import
faster-whisper, then ./venv/bin/python next to this script, then python3. The
interpreter must be Python 3.9 or newer. If no interpreter has the package,
the exact install commands are printed -- including, on Debian/Ubuntu, the
python3.X-venv package to install first when python3 -m venv does not work
(PEP 668 / missing ensurepip).

Exit codes:
  0    verification finished
  1    missing dependency, missing input, not enough disk space, bad usage
  2    the worker rejected an option (e.g. a non-numeric LIMIT)
  3    verification finished, but EVERY file this run errored (paths not
       visible here?) -- a partial failure still exits 0; see the CSV
  130  interrupted (Ctrl-C)
Codes 0, 2, 3 and 130 are verify_audio_language.py's own, passed through
unchanged once the pre-flight checks have passed.
EOF
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# export_if_set <name>... -- export each variable that is set and non-empty.
# The worker reads its configuration from the environment, so what .env
# supplied has to be exported; load_dotenv deliberately exports nothing itself.
export_if_set() {
    local key
    for key in "$@"; do
        if [[ -n "${!key:-}" ]]; then
            # shellcheck disable=SC2163  # exporting by name is the point here.
            export "${key?}"
        fi
    done
}

load_config() {
    local dotenv
    dotenv="$(find_dotenv || true)"
    if [[ -n "$dotenv" ]]; then
        load_dotenv "$dotenv" || true
    fi
    export_if_set WHISPER_MODEL SAMPLE_SECONDS SAMPLE_OFFSET_PCT \
        MIN_CONFIDENCE WHISPER_THREADS MIN_FREE_SPACE_MB TEMP_DIR \
        LIMIT RETRY_ERRORS NO_RESUME
}

# ---------------------------------------------------------------------------
# Install hints
# ---------------------------------------------------------------------------

detect_os_hint() {
    if [[ "$(uname 2>/dev/null || true)" == "Darwin" ]]; then
        OS_HINT="brew"
    elif have apt; then
        OS_HINT="apt"
    elif have dnf; then
        OS_HINT="dnf"
    elif have pacman; then
        OS_HINT="pacman"
    fi
}

print_install_hint() {
    local tool="$1"
    case "$OS_HINT" in
        brew)   log "    brew install $tool" ;;
        apt)    log "    sudo apt update && sudo apt install -y $tool" ;;
        dnf)    log "    sudo dnf install -y $tool" ;;
        pacman) log "    sudo pacman -S $tool" ;;
        *)      log "    (install '$tool' using your system's package manager)" ;;
    esac
}

print_pip_hint() {
    case "$OS_HINT" in
        apt)    log "    sudo apt update && sudo apt install -y python3-pip" ;;
        dnf)    log "    sudo dnf install -y python3-pip" ;;
        pacman) log "    sudo pacman -S python-pip" ;;
        *)      log "    python3 -m ensurepip --upgrade" ;;
    esac
}

# print_venv_recipe -- the ONE place the install instructions live. Which of
# the two forms is right depends only on whether a venv already exists.
print_venv_recipe() {
    log ""
    if [[ -x "$VENV_DIR/bin/python" ]]; then
        log "A venv already exists at $VENV_DIR -- install the dependency into it:"
        log ""
        log "    \"$VENV_DIR/bin/pip\" install -r \"$REQUIREMENTS\""
    else
        log "A system Python is often externally managed (PEP 668, the default on"
        log "Debian/Ubuntu), so a virtual environment is the way to install it:"
        log ""
        log "    python3 -m venv \"$VENV_DIR\""
        log "    \"$VENV_DIR/bin/pip\" install --upgrade pip"
        log "    \"$VENV_DIR/bin/pip\" install -r \"$REQUIREMENTS\""
    fi
    log ""
    log "Then re-run this script: it detects and uses that venv automatically."
}

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------

check_ffmpeg() {
    if have ffmpeg && have ffprobe; then
        log "  [OK] ffmpeg / ffprobe found."
        return 0
    fi
    err "ffmpeg/ffprobe not found."
    log "Install it with:"
    print_install_hint ffmpeg
    return 1
}

# python_two_part_version <python> -- echo "3.12", or nothing if it cannot be
# asked. -I so a sitecustomize or a stray PYTHONPATH cannot answer for it.
python_two_part_version() {
    "$1" -I -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true
}

# check_venv_capability -- actually create a throwaway venv, because Debian and
# Ubuntu ship the venv stdlib module without ensurepip: `import venv` succeeds
# and `python3 -m venv` still produces an unusable directory. rc 1 (having
# printed the package to install) when it does.
check_venv_capability() {
    local test_dir out py_ver ok=1
    test_dir="$(mktemp -d)"
    out="$(python3 -m venv "$test_dir" 2>&1 || true)"
    if [[ ! -x "$test_dir/bin/pip" ]]; then
        ok=0
    fi
    rm -rf -- "$test_dir"

    if [[ "$ok" -eq 1 ]]; then
        return 0
    fi

    py_ver="$(python_two_part_version python3)"
    [[ -n "$py_ver" ]] || py_ver="3.x"

    err "python3-venv support is missing or incomplete (ensurepip failed)."
    log ""
    printf '%s\n' "$out" | grep -i 'ensurepip\|venv' | sed 's/^/    /' >&2 || true
    log ""
    log "Install it with:"
    case "$OS_HINT" in
        apt) log "    sudo apt install -y python${py_ver}-venv" ;;
        dnf) log "    sudo dnf install -y python3-venv" ;;
        *)   log "    (install the venv/ensurepip support package for Python ${py_ver})" ;;
    esac
    log ""
    return 1
}

# report_missing_python -- the diagnostics for "no interpreter has the
# package", and ONLY for that case. This is where the system pip and the venv
# capability actually matter: a working venv makes both irrelevant.
report_missing_python() {
    local py_ver

    err "Python package 'faster-whisper' not found."

    if ! have python3; then
        log ""
        err "python3 not found."
        log "Install it with:"
        print_install_hint python3
        return 0
    fi

    py_ver="$(python3 --version 2>&1 || true)"
    log "  [OK] python3 found (${py_ver:-unknown})."

    if python3 -m pip --version > /dev/null 2>&1; then
        log "  [OK] pip for python3 found."
    else
        err "pip for python3 not found."
        log "Install it with:"
        print_pip_hint
    fi

    # Only worth asking when there is no venv to install into yet.
    if [[ ! -x "$VENV_DIR/bin/python" ]]; then
        check_venv_capability || true
    fi

    print_venv_recipe
}

# ensure_dir <dir> -- create it, or stop with a message of our own. mkdir's own
# stderr is dropped on purpose: "mkdir: /vol/x: Permission denied" reads like a
# crash halfway through the run, where this is the launcher refusing to start.
ensure_dir() {
    mkdir -p -- "$1" 2>/dev/null || die 1 "cannot create directory: $1"
}

# check_disk_space -- TEMP_DIR is the PARENT of the run's private sample
# directory, so it is created here rather than left for df to trip over: a
# TEMP_DIR that does not exist yet is a normal first run, not an error.
check_disk_space() {
    local dir min_mb avail_mb

    dir="${TEMP_DIR:-${TMPDIR:-/tmp}}"
    if [[ -n "${TEMP_DIR:-}" ]]; then
        ensure_dir "$TEMP_DIR"
    fi

    min_mb="${MIN_FREE_SPACE_MB:-500}"
    if [[ ! "$min_mb" =~ ^[0-9]+$ ]]; then
        err "MIN_FREE_SPACE_MB must be a whole number of MB (got '$min_mb')."
        return 1
    fi

    log "Checking disk space in '$dir'..."
    if ! avail_mb="$(df -Pm "$dir" 2>/dev/null | tail -1 | awk '{print $4}')"; then
        avail_mb=""
    fi
    if [[ ! "$avail_mb" =~ ^[0-9]+$ ]]; then
        err "Could not determine available disk space in '$dir'."
        return 1
    fi

    # Compare normalized decimal strings: Bash interprets leading zeroes as
    # octal and silently wraps large integers, either of which can let an
    # insufficient-space run through this guard.
    while [[ "$min_mb" == 0* && ${#min_mb} -gt 1 ]]; do min_mb="${min_mb#0}"; done
    while [[ "$avail_mb" == 0* && ${#avail_mb} -gt 1 ]]; do avail_mb="${avail_mb#0}"; done
    if [[ ${#avail_mb} -lt ${#min_mb} ||
        ( ${#avail_mb} -eq ${#min_mb} && "$avail_mb" < "$min_mb" ) ]]; then
        err "Only ${avail_mb} MB free in '$dir', need at least ${min_mb} MB."
        err "Free up space, or set TEMP_DIR to a location with more room, e.g.:"
        err "    TEMP_DIR=/path/with/space ./verify/verify-audio-language.sh"
        return 1
    fi

    log "  [OK] ${avail_mb} MB available (minimum required: ${min_mb} MB)."
}

# build_extra_args -- the environment switches the worker takes as flags.
build_extra_args() {
    EXTRA_ARGS=()
    if [[ -n "${LIMIT:-}" ]]; then
        EXTRA_ARGS+=(--limit "$LIMIT")
    fi
    if is_true "${RETRY_ERRORS:-}"; then
        EXTRA_ARGS+=(--retry-errors)
    fi
    if is_true "${NO_RESUME:-}"; then
        EXTRA_ARGS+=(--no-resume)
    fi
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

# parse_args "$@" -- sets CHECK_ONLY and the POSITIONAL array. --check is
# accepted in any position: the orchestrator and the README both put it last
# behind a path, and "in.csv --check" used to be read as an OUTPUT_CSV named
# "--check". Exits 0 on --help and 1 on a usage error, as usage() promises.
parse_args() {
    CHECK_ONLY=0
    POSITIONAL=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --check)   CHECK_ONLY=1; shift ;;
            --)        shift
                       while [[ $# -gt 0 ]]; do POSITIONAL+=("$1"); shift; done ;;
            -*)        err "unknown option: $1"
                       log "Try --help."
                       exit 1 ;;
            *)         POSITIONAL+=("$1"); shift ;;
        esac
    done

    if [[ ${#POSITIONAL[@]} -gt 2 ]]; then
        err "too many arguments: at most INPUT_CSV and OUTPUT_CSV."
        log "Try --help."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
    local check_only input_csv output_csv
    local python_bin="" found="" missing=0 rc=0

    parse_args "$@"
    check_only="$CHECK_ONLY"

    # No phase 2 child needs credentials, including interpreter imports and
    # dependency probes before the worker is launched. Clear export attributes
    # before loading .env; values parsed there remain local to this shell.
    unset RADARR_API_KEY SONARR_API_KEY
    load_config

    # Paths default to <repo>/reports/ so phase 1, phase 2 and the HTML report
    # all use the same location regardless of the current directory.
    input_csv="${POSITIONAL[0]:-$ALA_PHASE1_CSV}"
    output_csv="${POSITIONAL[1]:-$ALA_PHASE2_CSV}"

    # 1. Input, and the companion script this launcher exists to launch.
    if [[ "$check_only" -eq 0 && ! -f "$input_csv" ]]; then
        err "Input CSV not found: $input_csv"
        err "Run scan/find-missing-italian-audio.sh first, or pass the correct path as the first argument."
        return 1
    fi
    if [[ ! -f "$PYTHON_SCRIPT" ]]; then
        err "Companion script not found: $PYTHON_SCRIPT"
        err "Make sure verify_audio_language.py is in the same folder as this script."
        return 1
    fi

    detect_os_hint

    # 2. ffmpeg / ffprobe.
    log "Checking dependencies..."
    check_ffmpeg || missing=1

    # 3./4. The interpreter, and the install recipe when there is none. The
    # floor is checked here rather than inside a command substitution, where a
    # die would only kill the subshell: running phase 2 on 3.8 buys a traceback
    # halfway through a multi-hour scan.
    if python_bin="$(find_phase2_python "$VENV_DIR")"; then
        if [[ "$python_bin" == "$VENV_DIR/bin/python" ]]; then
            log "  [OK] faster-whisper found (venv: $VENV_DIR)."
        else
            log "  [OK] faster-whisper found ($python_bin)."
        fi
        if ! python_meets_floor "$python_bin"; then
            found="$(python_two_part_version "$python_bin")"
            die 1 "Python ${ALA_MIN_PYTHON}+ is required (found ${found:-an older version} at $python_bin)"
        fi
    else
        report_missing_python
        missing=1
    fi

    if [[ "$missing" -eq 1 ]]; then
        log ""
        err "One or more dependencies are missing. Install them and re-run this script."
        return 1
    fi

    if [[ "$check_only" -eq 1 ]]; then
        log ""
        log "[OK] phase 2 environment is ready (python via: $python_bin)."
        return 0
    fi

    # 5. Disk space for the audio samples.
    check_disk_space || return 1

    # 6. Run the worker, without the *arr credentials it does not need.
    ensure_dir "$(dirname -- "$output_csv")"
    build_extra_args

    log ""
    log "All checks passed. Starting language verification..."
    log "Model: ${WHISPER_MODEL:-small} | Sample length: ${SAMPLE_SECONDS:-60}s | Input: $input_csv"
    log ""

    env -u RADARR_API_KEY -u SONARR_API_KEY \
        "$python_bin" "$PYTHON_SCRIPT" \
        --input "$input_csv" --output "$output_csv" \
        ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        return "$rc"
    fi

    log ""
    log "Tip: build a browsable HTML report from the CSV with:"
    log "    $SCRIPT_DIR/report.py \"$output_csv\"            # writes an .html next to it"
    log "    $SCRIPT_DIR/report.py \"$output_csv\" --serve    # and view it from another machine"
}

# `main "$@"` and nothing else: on the left of a `||` the whole run would sit
# inside a tested command, where errexit is disabled, and a failed mkdir would
# be reported as a clean run. The script's exit status is main's either way.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

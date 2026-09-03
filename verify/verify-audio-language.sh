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
# Requirements: bash, ffmpeg, ffprobe, python3, pip, faster-whisper
#               (faster-whisper may live in a local ./venv, see below)
#
# Usage:
#   ./verify/verify-audio-language.sh [INPUT_CSV] [OUTPUT_CSV]
#   ./verify/verify-audio-language.sh -h | --help
#
# Arguments:
#   INPUT_CSV          CSV from phase 1 (default: ./missing-italian-audio.csv)
#   OUTPUT_CSV         verdict report   (default: ./verified-language-results.csv)
#
# Environment variables (see verify_audio_language.py --help for the rest):
#   WHISPER_MODEL       tiny | base | small | medium            (default: small)
#   SAMPLE_SECONDS      audio sample length, in seconds         (default: 60)
#   SAMPLE_OFFSET_PCT   where to start sampling, % of duration  (default: 25)
#   MIN_FREE_SPACE_MB   minimum free space required, in MB      (default: 500)
#   TEMP_DIR           directory for temporary audio samples   (default: mktemp)
#   LIMIT              only process the first N new files       (for testing)
#   RETRY_ERRORS      true to also reprocess previously failed rows
#   NO_RESUME         true to ignore an existing OUTPUT_CSV and start fresh
#
# Resume: if OUTPUT_CSV already exists, files already listed in it are
# skipped (matched by path). Use RETRY_ERRORS=true to retry only the
# failures; NO_RESUME=true to overwrite and start over.
#
# Exit codes:
#   0   verification finished
#   1   missing dependency, missing input, or not enough disk space

set -euo pipefail

# ---------------------------------------------------------------------------
# OUTPUT HELPERS  (shared style with scan/find-missing-italian-audio.sh)
# ---------------------------------------------------------------------------
log()  { echo "$@" >&2; }
warn() { echo "WARN: $*" >&2; }
err()  { echo "ERROR: $*" >&2; }

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
  verify-audio-language.sh -h | --help

Arguments:
  INPUT_CSV          CSV from phase 1 (default: ./missing-italian-audio.csv)
  OUTPUT_CSV         verdict report   (default: ./verified-language-results.csv)

Environment variables:
  WHISPER_MODEL      tiny | base | small | medium            (default: small)
  SAMPLE_SECONDS     audio sample length, in seconds         (default: 60)
  SAMPLE_OFFSET_PCT  where to start sampling, % of duration  (default: 25)
  MIN_FREE_SPACE_MB  minimum free space required, in MB      (default: 500)
  TEMP_DIR          directory for temporary audio samples   (default: mktemp)
  LIMIT             only process the first N new files       (for testing)
  RETRY_ERRORS      true to also reprocess previously failed rows
  NO_RESUME         true to ignore an existing OUTPUT_CSV and start fresh

faster-whisper is looked for in the system python3 first, then in a local
venv at ./venv (next to this script). If it is missing, the exact install
commands are printed. On Debian/Ubuntu the script also verifies that
python3 -m venv actually works (PEP 668 / missing ensurepip) and, if not,
suggests the correct apt package for your Python version.

Exit codes:
  0   verification finished
  1   missing dependency, missing input, or not enough disk space
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PYTHON_SCRIPT="$SCRIPT_DIR/verify_audio_language.py"

INPUT_CSV="${1:-./missing-italian-audio.csv}"
OUTPUT_CSV="${2:-./verified-language-results.csv}"

MIN_FREE_SPACE_MB="${MIN_FREE_SPACE_MB:-500}"

missing_deps=0

# ---------------------------------------------------------------------------
# 1. Check input file exists
# ---------------------------------------------------------------------------
if [[ ! -f "$INPUT_CSV" ]]; then
    err "Input CSV not found: $INPUT_CSV"
    err "Run scan/find-missing-italian-audio.sh first, or pass the correct path as the first argument."
    exit 1
fi

if [[ ! -f "$PYTHON_SCRIPT" ]]; then
    err "Companion script not found: $PYTHON_SCRIPT"
    err "Make sure verify_audio_language.py is in the same folder as this script."
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Detect OS for install hints
# ---------------------------------------------------------------------------
OS_HINT="your package manager"
if [[ "$(uname)" == "Darwin" ]]; then
    OS_HINT="brew"
elif command -v apt >/dev/null 2>&1; then
    OS_HINT="apt"
elif command -v dnf >/dev/null 2>&1; then
    OS_HINT="dnf"
elif command -v pacman >/dev/null 2>&1; then
    OS_HINT="pacman"
fi

print_install_hint() {
    local tool="$1"
    case "$OS_HINT" in
        brew)   echo "    brew install $tool" ;;
        apt)    echo "    sudo apt update && sudo apt install -y $tool" ;;
        dnf)    echo "    sudo dnf install -y $tool" ;;
        pacman) echo "    sudo pacman -S $tool" ;;
        *)      echo "    (install '$tool' using your system's package manager)" ;;
    esac
}

# ---------------------------------------------------------------------------
# 3. Check ffmpeg / ffprobe
# ---------------------------------------------------------------------------
log "Checking dependencies..."

if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
    err "ffmpeg/ffprobe not found."
    log "Install it with:"
    print_install_hint "ffmpeg" >&2
    missing_deps=1
else
    log "  [OK] ffmpeg / ffprobe found."
fi

# ---------------------------------------------------------------------------
# 4. Check python3
# ---------------------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
    err "python3 not found."
    log "Install it with:"
    print_install_hint "python3" >&2
    missing_deps=1
else
    log "  [OK] python3 found ($(python3 --version))."
fi

# ---------------------------------------------------------------------------
# 5. Check pip3
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
    if ! python3 -m pip --version >/dev/null 2>&1; then
        err "pip for python3 not found."
        log "Install it with:"
        case "$OS_HINT" in
            brew)   log "    python3 -m ensurepip --upgrade" ;;
            apt)    log "    sudo apt update && sudo apt install -y python3-pip" ;;
            dnf)    log "    sudo dnf install -y python3-pip" ;;
            pacman) log "    sudo pacman -S python-pip" ;;
            *)      log "    python3 -m ensurepip --upgrade" ;;
        esac
        missing_deps=1
    else
        log "  [OK] pip3 found."
    fi
fi

# ---------------------------------------------------------------------------
# 6. Check faster-whisper: system python3 first, then a local venv
# ---------------------------------------------------------------------------
VENV_DIR="$SCRIPT_DIR/venv"
PYTHON_BIN="python3"

# Actually try creating a throwaway venv to see if ensurepip/venv support is
# present (Debian/Ubuntu split this into a separate python3.X-venv package,
# distinct from just having the 'venv' stdlib module importable).
check_venv_capability() {
    local test_dir
    test_dir=$(mktemp -d)
    local out
    out=$(python3 -m venv "$test_dir" 2>&1)
    local ok=1
    if [[ ! -x "$test_dir/bin/pip" ]]; then
        ok=0
    fi
    rm -rf "$test_dir"

    if [[ "$ok" -eq 0 ]]; then
        local py_ver
        py_ver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        err "python3-venv support is missing or incomplete (ensurepip failed)."
        log ""
        echo "$out" | grep -i "ensurepip\|venv" | sed 's/^/    /' >&2 || true
        log ""
        log "Install it with:"
        case "$OS_HINT" in
            apt)  log "    sudo apt install -y python${py_ver}-venv" ;;
            dnf)  log "    sudo dnf install -y python3-venv" ;;
            *)    log "    (install the venv/ensurepip support package for Python ${py_ver})" ;;
        esac
        log ""
        return 1
    fi
    return 0
}

if python3 -c "import faster_whisper" >/dev/null 2>&1; then
    log "  [OK] faster-whisper found (system python3)."
elif [[ -x "$VENV_DIR/bin/python" ]] && "$VENV_DIR/bin/python" -c "import faster_whisper" >/dev/null 2>&1; then
    log "  [OK] faster-whisper found (venv: $VENV_DIR)."
    PYTHON_BIN="$VENV_DIR/bin/python"
else
    err "Python package 'faster-whisper' not found."

    if [[ -x "$VENV_DIR/bin/python" ]]; then
        # A venv exists but doesn't have the package -- just needs the install step.
        log ""
        log "A venv already exists at $VENV_DIR -- install the package into it with:"
        log "    \"$VENV_DIR/bin/pip\" install faster-whisper"
        missing_deps=1
    elif check_venv_capability; then
        log ""
        log "Your system Python is externally managed (common on Debian/Ubuntu), so"
        log "a virtual environment is the recommended way to install it. Run:"
        log ""
        log "    python3 -m venv \"$VENV_DIR\""
        log "    \"$VENV_DIR/bin/pip\" install --upgrade pip"
        log "    \"$VENV_DIR/bin/pip\" install faster-whisper"
        log ""
        log "Then just re-run this script -- it will detect and use that venv automatically."
        missing_deps=1
    else
        log "After installing the package above, run:"
        log ""
        log "    python3 -m venv \"$VENV_DIR\""
        log "    \"$VENV_DIR/bin/pip\" install --upgrade pip"
        log "    \"$VENV_DIR/bin/pip\" install faster-whisper"
        log ""
        log "Then just re-run this script -- it will detect and use that venv automatically."
        missing_deps=1
    fi
fi

if [[ "$missing_deps" -eq 1 ]]; then
    log ""
    err "One or more dependencies are missing. Install them and re-run this script."
    exit 1
fi

# ---------------------------------------------------------------------------
# 7. Disk space check (temp dir used for audio samples)
# ---------------------------------------------------------------------------
TEMP_CHECK_DIR="${TEMP_DIR:-${TMPDIR:-/tmp}}"
avail_mb=$(df -Pm "$TEMP_CHECK_DIR" | tail -1 | awk '{print $4}')

log "Checking disk space in '$TEMP_CHECK_DIR'..."
if [[ -z "$avail_mb" ]]; then
    err "Could not determine available disk space in '$TEMP_CHECK_DIR'."
    exit 1
fi

if (( avail_mb < MIN_FREE_SPACE_MB )); then
    err "Only ${avail_mb} MB free in '$TEMP_CHECK_DIR', need at least ${MIN_FREE_SPACE_MB} MB."
    err "Free up space, or set TEMP_DIR to a location with more room, e.g.:"
    err "    TEMP_DIR=/path/with/space ./verify/verify-audio-language.sh"
    exit 1
else
    log "  [OK] ${avail_mb} MB available (minimum required: ${MIN_FREE_SPACE_MB} MB)."
fi

# ---------------------------------------------------------------------------
# 8. Run the actual Python script
# ---------------------------------------------------------------------------
log ""
log "All checks passed. Starting language verification..."
log "Model: ${WHISPER_MODEL:-small} | Sample length: ${SAMPLE_SECONDS:-60}s | Input: $INPUT_CSV"
log ""

EXTRA_ARGS=()
if [[ -n "${LIMIT:-}" ]]; then
    EXTRA_ARGS+=(--limit "$LIMIT")
fi
if [[ "${RETRY_ERRORS:-false}" == "true" ]]; then
    EXTRA_ARGS+=(--retry-errors)
fi
if [[ "${NO_RESUME:-false}" == "true" ]]; then
    EXTRA_ARGS+=(--no-resume)
fi

"$PYTHON_BIN" "$PYTHON_SCRIPT" --input "$INPUT_CSV" --output "$OUTPUT_CSV" "${EXTRA_ARGS[@]}"

log ""
log "Tip: build a browsable HTML report from the CSV with:"
log "    $SCRIPT_DIR/report.py \"$OUTPUT_CSV\"            # writes an .html next to it"
log "    $SCRIPT_DIR/report.py \"$OUTPUT_CSV\" --serve    # and view it from another machine"

#!/usr/bin/env bash
#
# lib/common.sh -- helpers shared by the three entry points.
#
# Source it, never execute it:
#
#     . "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
#
# Constraints this file is held to:
#   * bash 3.2 (the /bin/bash macOS ships): no reading a file into an array in
#     one builtin, no associative arrays, no case-converting expansions, no
#     namerefs.
#   * sourcing is silent, has no side effects and never exits, so a caller can
#     source it twice and a `--help` path stays fast.
#   * shellcheck -S warning clean.

# Sourced twice -- by the orchestrator and again by the script it calls -- the
# second source must be a no-op.
[[ -n "${ALA_COMMON_LOADED:-}" ]] && return 0
ALA_COMMON_LOADED=1

# ---------------------------------------------------------------------------
# Paths and constants
#
# Everything is derived from this file's location, so the scripts work from any
# working directory and the tests can exercise a copy of the tree.
# ---------------------------------------------------------------------------

ALA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALA_ROOT="$(cd "$ALA_LIB_DIR/.." && pwd)"

# shellcheck disable=SC2034  # a library defines these for its callers to use.
{
    ALA_REPORTS_DIR="$ALA_ROOT/reports"
    ALA_PHASE1_CSV="$ALA_REPORTS_DIR/missing-italian-audio.csv"
    ALA_PHASE2_CSV="$ALA_REPORTS_DIR/verified-language-results.csv"
    ALA_REPORT_HTML="$ALA_REPORTS_DIR/verified-language-results.html"
    ALA_ENV_FILE="$ALA_ROOT/.env"
    ALA_MIN_PYTHON="3.9"
}

# The only keys a .env file may set. Anything else is reported and dropped: a
# .env is configuration, not a way to reach PATH, LD_PRELOAD or IFS.
ALA_DOTENV_KEYS="RADARR_URL RADARR_API_KEY SKIP_RADARR \
SONARR_URL SONARR_API_KEY SKIP_SONARR \
FORCE_RESCAN RESCAN_TIMEOUT REFRESH \
WHISPER_MODEL SAMPLE_SECONDS SAMPLE_OFFSET_PCT \
MIN_FREE_SPACE_MB MIN_CONFIDENCE WHISPER_THREADS \
TEMP_DIR LIMIT RETRY_ERRORS NO_RESUME PYTHON_BIN"

# ---------------------------------------------------------------------------
# Logging
#
# Everything goes to stderr: stdout belongs to the data a function returns.
# ---------------------------------------------------------------------------

log()  { echo "$@" >&2; }
warn() { echo "WARN: $*" >&2; }
err()  { echo "ERROR: $*" >&2; }

# die [exit-code] message... -- report and stop. A leading all-digit argument
# is the exit code; without one the status is 1.
die() {
    local code=1
    if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
        code="$1"
        shift
    fi
    err "$@"
    exit "$code"
}

# ---------------------------------------------------------------------------
# Small predicates
# ---------------------------------------------------------------------------

# have <command> -- is it callable?
have() { command -v "$1" >/dev/null 2>&1; }

# require <command>... -- die on the first one that is missing.
require() {
    local cmd
    for cmd in "$@"; do
        have "$cmd" || die 1 "$cmd is required but not installed."
    done
}

# is_true <value> -- the string "true" in any case, and nothing else. Written
# as a regex because bash 3.2 has no case-converting expansion.
is_true() { [[ "${1:-}" =~ ^[Tt][Rr][Uu][Ee]$ ]]; }

# strip_cr <variable-name> -- remove every CR from the named variable in place.
# Takes a name rather than a value so a caller can clean a variable it already
# holds, which is what reading a CRLF file leaves behind.
strip_cr() {
    local _sc_name="$1" _sc_value
    _sc_value="${!_sc_name:-}"
    printf -v "$_sc_name" '%s' "${_sc_value//$'\r'/}"
}

# normalize_url <url> -- echo it without trailing slashes or trailing blanks,
# so callers can concatenate "$url/api/v3/..." without doubling the separator.
normalize_url() {
    local url="${1:-}"
    while [[ -n "$url" && "$url" == *[/[:space:]] ]]; do
        url="${url%?}"
    done
    printf '%s\n' "$url"
}

# ---------------------------------------------------------------------------
# .env handling
#
# The file is parsed, never sourced and never eval'd: a .env is frequently
# world-readable and sometimes shared, and sourcing it hands whoever can write
# it arbitrary code execution as the user running the audit.
# ---------------------------------------------------------------------------

# find_dotenv -- echo the first .env the repository provides, rc 1 if none.
# The working directory is deliberately not a candidate: running the audit from
# a directory someone else can write must not change its configuration.
find_dotenv() {
    local candidate
    for candidate in "$ALA_ROOT/.env" "$ALA_ROOT/scan/.env"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# _ala_key_allowed <key> -- is the key on the .env allow-list?
_ala_key_allowed() {
    case " $ALA_DOTENV_KEYS " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# load_dotenv <file> -- set the allow-listed keys the file defines, rc 1 if the
# file does not exist.
#
#   * blank lines and # comments are skipped;
#   * only KEY=value with a shell-identifier KEY is accepted, anything else is
#     ignored, so a stray command in the file is inert;
#   * a trailing CR (a file edited on Windows) is removed;
#   * one pair of matching surrounding quotes is removed from the value, and
#     nothing else about it is interpreted -- no expansion, no substitution;
#   * a variable already set in the environment wins over the file, so
#     `LIMIT=5 ./scan.sh` beats what .env says;
#   * nothing is exported: a caller that wants a child to see a value exports
#     it itself.
load_dotenv() {
    local file="${1:-}" line key value name
    [[ -f "$file" ]] || return 1

    # `|| [[ -n "$line" ]]` so a last line without a newline is still read.
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        case "$line" in
            '' | '#'*) continue ;;
        esac
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"

        if ! _ala_key_allowed "$key"; then
            warn "$file: ignoring unknown key $key"
            continue
        fi

        if [[ ${#value} -ge 2 ]]; then
            case "$value" in
                \"*\" | \'*\') value="${value:1:${#value}-2}" ;;
            esac
        fi

        # Already set in the environment: the caller's value wins.
        declare -p "$key" >/dev/null 2>&1 && continue
        printf -v "$key" '%s' "$value"
    done < "$file"

    # A base URL with a trailing slash produces "//api/v3/..." later, which
    # some reverse proxies in front of *arr reject.
    for name in RADARR_URL SONARR_URL; do
        if [[ -n "${!name:-}" ]]; then
            printf -v "$name" '%s' "$(normalize_url "${!name}")"
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# Radarr / Sonarr HTTP
#
# The API key goes to curl through a --config file read from stdin. On argv it
# would be readable in `ps` output by every user on the box for as long as the
# request runs.
# ---------------------------------------------------------------------------

# arr_curl <api-key> <curl-arg>... -- curl with the key supplied out of band.
arr_curl() {
    local key="${1:-}" escaped
    shift
    # curl's config parser reads \" and \\ inside a quoted value.
    escaped="${key//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    printf 'header = "X-Api-Key: %s"\n' "$escaped" |
        curl -sf --compressed -K - "$@"
}

# arr_get <url> <api-key> [attempts] -- echo the response body, rc 1 once the
# last attempt has failed. *arr answers 503 while it is starting up and the
# scans are long enough to hit a restart, so a transient failure is retried.
arr_get() {
    local url="${1:-}" key="${2:-}" tries="${3:-3}" attempt=1 body
    while :; do
        if body="$(arr_curl "$key" -m "${ARR_TIMEOUT:-120}" "$url")"; then
            printf '%s\n' "$body"
            return 0
        fi
        [[ $attempt -ge $tries ]] && return 1
        attempt=$((attempt + 1))
        sleep "${ARR_RETRY_DELAY:-2}"
    done
}

# arr_post <url> <api-key> <json> -- echo the response body, rc 1 on failure.
# Not retried: the POSTs here queue commands, and a retry can queue twice.
arr_post() {
    local url="${1:-}" key="${2:-}" json="${3:-}"
    # -d already makes it a POST; -X POST as well would only confuse a redirect.
    arr_curl "$key" \
        -H 'Content-Type: application/json' \
        -d "$json" \
        -m "${ARR_TIMEOUT:-120}" \
        "$url"
}

# ---------------------------------------------------------------------------
# Phase 2 interpreter discovery
#
# Phase 2 needs an interpreter that can `import faster_whisper`. Probes run
# with -I (isolated) so a stray PYTHONPATH or a module in the working directory
# cannot make a broken interpreter look usable.
# ---------------------------------------------------------------------------

# python_meets_floor <python> -- rc 0 if it is at least $ALA_MIN_PYTHON.
python_meets_floor() {
    local bin="${1:-}" major minor
    [[ -n "$bin" ]] || return 1
    major="${ALA_MIN_PYTHON%%.*}"
    minor="${ALA_MIN_PYTHON#*.}"
    "$bin" -I -c \
        "import sys; sys.exit(0 if sys.version_info >= ($major, $minor) else 1)" \
        >/dev/null 2>&1
}

# python_has_faster_whisper <python> -- rc 0 if the import succeeds.
python_has_faster_whisper() {
    local bin="${1:-}"
    [[ -n "$bin" ]] || return 1
    "$bin" -I -c 'import faster_whisper' >/dev/null 2>&1
}

# find_phase2_python -- echo the interpreter to run phase 2 with, rc 1 if none
# has faster_whisper. PYTHON_BIN wins when it is usable; when it is not, say so
# rather than silently running something the operator did not ask for.
find_phase2_python() {
    local venv_python="$ALA_ROOT/verify/venv/bin/python"

    if [[ -n "${PYTHON_BIN:-}" ]]; then
        if python_has_faster_whisper "$PYTHON_BIN"; then
            printf '%s\n' "$PYTHON_BIN"
            return 0
        fi
        warn "PYTHON_BIN=$PYTHON_BIN cannot import faster_whisper; ignoring it."
    fi

    if [[ -x "$venv_python" ]] && python_has_faster_whisper "$venv_python"; then
        printf '%s\n' "$venv_python"
        return 0
    fi

    if have python3 && python_has_faster_whisper python3; then
        printf '%s\n' "python3"
        return 0
    fi

    return 1
}

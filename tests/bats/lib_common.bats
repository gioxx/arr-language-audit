#!/usr/bin/env bats
#
# lib/common.sh -- the shared bash library.
#
# Every snippet runs through "$BASH_UNDER_TEST" (bash 3.2 on macOS) so a bash 4
# builtin that slipped in fails here rather than on a user's machine. The
# library is copied into an isolated fake repository first: the tests write
# .env files and a fake verify/venv, and neither belongs in the real checkout.

load helpers/common
load helpers/fake_arr
load helpers/shims

teardown() {
    stop_fake_arr
}

# make_fake_repo -- copy the library into $BATS_TEST_TMPDIR/repo and export
# FAKE_ROOT (what ALA_ROOT must resolve to) and LIB (the path to source).
make_fake_repo() {
    FAKE_ROOT="$BATS_TEST_TMPDIR/repo"
    LIB="$FAKE_ROOT/lib/common.sh"
    mkdir -p "$FAKE_ROOT/lib" "$FAKE_ROOT/scan" "$FAKE_ROOT/verify" \
        "$BATS_TEST_TMPDIR/elsewhere"
    cp "$ROOT/lib/common.sh" "$LIB"
    export FAKE_ROOT LIB
}

# lib_run <snippet> -- source the library, then run the snippet under bash 3.2.
lib_run() {
    run "$BASH_UNDER_TEST" -c ". \"\$LIB\" || exit 99
$1"
}

# lib_run_err <snippet> -- like lib_run, with stderr captured in $ERRFILE so a
# test can assert on stdout and on the warnings separately.
lib_run_err() {
    ERRFILE="$BATS_TEST_TMPDIR/stderr.txt"
    export ERRFILE
    : > "$ERRFILE"
    lib_run "{ $1
} 2>\"\$ERRFILE\""
}

# write_env <path> <line>... -- a .env fixture, LF terminated.
write_env() {
    local path="$1"
    shift
    printf '%s\n' "$@" > "$path"
}

# fake_python <path> -- an interpreter that answers every probe successfully.
fake_python() {
    mkdir -p "$(dirname "$1")"
    printf '#!/bin/sh\nexit 0\n' > "$1"
    chmod +x "$1"
}

# ---------------------------------------------------------------- sourcing --

@test "sourcing the library is silent, succeeds and is idempotent" {
    make_fake_repo

    lib_run 'true'
    assert_success
    assert_output ""

    # Sourced twice, the guard must not re-run anything and every helper must
    # still be defined.
    lib_run '. "$LIB"; . "$LIB"; is_true TRUE && normalize_url "http://h/"'
    assert_success
    assert_output "http://h"
}

@test "the library exports the documented paths relative to the repo root" {
    make_fake_repo

    lib_run 'printf "%s\n" "$ALA_ROOT" "$ALA_LIB_DIR" "$ALA_REPORTS_DIR" \
        "$ALA_PHASE1_CSV" "$ALA_PHASE2_CSV" "$ALA_REPORT_HTML" \
        "$ALA_ENV_FILE" "$ALA_MIN_PYTHON"'
    assert_success
    assert_line --index 0 "$FAKE_ROOT"
    assert_line --index 1 "$FAKE_ROOT/lib"
    assert_line --index 2 "$FAKE_ROOT/reports"
    assert_line --index 3 "$FAKE_ROOT/reports/missing-italian-audio.csv"
    assert_line --index 4 "$FAKE_ROOT/reports/verified-language-results.csv"
    assert_line --index 5 "$FAKE_ROOT/reports/verified-language-results.html"
    assert_line --index 6 "$FAKE_ROOT/.env"
    assert_line --index 7 "3.9"
}

# ----------------------------------------------------------------- logging --

@test "log, warn and err write to stderr with the established prefixes" {
    make_fake_repo

    lib_run_err 'log plain; warn careful; err broken'
    assert_success
    assert_output ""

    run cat "$ERRFILE"
    assert_output "plain
WARN: careful
ERROR: broken"
}

@test "die prints ERROR and exits with the given code, defaulting to 1" {
    make_fake_repo

    lib_run 'die "no way"'
    assert_failure 1
    assert_output "ERROR: no way"

    lib_run 'die 3 "no way"'
    assert_failure 3
    assert_output "ERROR: no way"
}

@test "have and require detect a missing command" {
    make_fake_repo

    lib_run 'have sh && ! have definitely-not-a-command-9x'
    assert_success

    lib_run 'require sh definitely-not-a-command-9x sed; echo NOT REACHED'
    assert_failure 1
    assert_output "ERROR: definitely-not-a-command-9x is required but not installed."
}

@test "is_true accepts true in any case and nothing else" {
    make_fake_repo

    lib_run 'is_true true && is_true TRUE && is_true True'
    assert_success

    lib_run 'is_true false || is_true yes || is_true 1 || is_true ""'
    assert_failure
}

@test "strip_cr removes carriage returns from the named variable" {
    make_fake_repo

    lib_run 'v=$(printf "a\rb\r"); strip_cr v; printf "[%s]\n" "$v"'
    assert_success
    assert_output "[ab]"
}

@test "normalize_url drops trailing slashes and trailing whitespace" {
    make_fake_repo

    lib_run 'normalize_url "http://h:7878/// "'
    assert_success
    assert_output "http://h:7878"

    lib_run 'normalize_url "http://h:7878/radarr"'
    assert_success
    assert_output "http://h:7878/radarr"
}

# --------------------------------------------------------------- find_dotenv --

@test "find_dotenv prefers the repo root over scan/ and ignores the CWD" {
    make_fake_repo
    write_env "$FAKE_ROOT/scan/.env" "LIMIT=2"
    write_env "$BATS_TEST_TMPDIR/elsewhere/.env" "LIMIT=99"

    # Only scan/.env exists.
    lib_run 'cd "$BATS_TEST_TMPDIR/elsewhere" && find_dotenv'
    assert_success
    assert_output "$FAKE_ROOT/scan/.env"

    # The root file wins once it exists.
    write_env "$FAKE_ROOT/.env" "LIMIT=1"
    lib_run 'cd "$BATS_TEST_TMPDIR/elsewhere" && find_dotenv'
    assert_success
    assert_output "$FAKE_ROOT/.env"

    # With neither in the repo, the .env in the working directory is not a
    # candidate: find_dotenv fails rather than reading it.
    rm -f "$FAKE_ROOT/.env" "$FAKE_ROOT/scan/.env"
    lib_run 'cd "$BATS_TEST_TMPDIR/elsewhere" && find_dotenv'
    assert_failure 1
    assert_output ""
}

@test "ALA_DOTENV_FILE overrides the search, and only when the file exists" {
    make_fake_repo
    write_env "$FAKE_ROOT/.env" "LIMIT=1"
    write_env "$BATS_TEST_TMPDIR/chosen.env" "LIMIT=7"

    # The override wins over a .env the search would otherwise have found.
    export ALA_DOTENV_FILE="$BATS_TEST_TMPDIR/chosen.env"
    lib_run 'find_dotenv'
    assert_success
    assert_output "$BATS_TEST_TMPDIR/chosen.env"

    lib_run 'load_dotenv "$(find_dotenv)"; printf "%s\n" "$LIMIT"'
    assert_success
    assert_output "7"

    # Pointed at a file that does not exist it reports "no .env" rather than
    # falling back to the repository's: a test that neutralises the developer's
    # .env must not have it quietly reinstated.
    export ALA_DOTENV_FILE="$BATS_TEST_TMPDIR/absent.env"
    lib_run 'find_dotenv'
    assert_failure 1
    assert_output ""

    # Empty is "not set": the search order is back.
    export ALA_DOTENV_FILE=""
    lib_run 'find_dotenv'
    assert_success
    assert_output "$FAKE_ROOT/.env"
}

# --------------------------------------------------------------- load_dotenv --

@test "load_dotenv never executes command substitution in a value" {
    make_fake_repo
    write_env "$FAKE_ROOT/.env" 'RADARR_API_KEY=$(echo INJECTED >&2; echo k)'
    export ERRFILE="$BATS_TEST_TMPDIR/err.txt"

    lib_run 'load_dotenv "$ALA_ENV_FILE" 2>"$ERRFILE"; printf "%s\n" "$RADARR_API_KEY"'
    assert_success
    assert_output '$(echo INJECTED >&2; echo k)'

    run cat "$ERRFILE"
    refute_output --partial "INJECTED"
}

@test "load_dotenv never executes backticks and never sources the file" {
    make_fake_repo
    write_env "$FAKE_ROOT/.env" \
        'WHISPER_MODEL=`touch '"$BATS_TEST_TMPDIR"'/pwned`' \
        'echo INJECTED_LINE >&2'
    export ERRFILE="$BATS_TEST_TMPDIR/err.txt"

    lib_run 'load_dotenv "$ALA_ENV_FILE" 2>"$ERRFILE"; printf "%s\n" "$WHISPER_MODEL"'
    assert_success
    assert_output '`touch '"$BATS_TEST_TMPDIR"'/pwned`'
    [ ! -e "$BATS_TEST_TMPDIR/pwned" ]

    run cat "$ERRFILE"
    refute_output --partial "INJECTED_LINE"
}

@test "load_dotenv keeps spaces and strips one pair of surrounding quotes" {
    make_fake_repo
    write_env "$FAKE_ROOT/.env" \
        'WHISPER_MODEL=large v3' \
        'TEMP_DIR="/tmp/with quotes"' \
        "MIN_CONFIDENCE='0.5'" \
        'RESCAN_TIMEOUT="600'

    lib_run 'load_dotenv "$ALA_ENV_FILE"; printf "[%s]\n" "$WHISPER_MODEL" \
        "$TEMP_DIR" "$MIN_CONFIDENCE" "$RESCAN_TIMEOUT"'
    assert_success
    assert_line --index 0 "[large v3]"
    assert_line --index 1 "[/tmp/with quotes]"
    assert_line --index 2 "[0.5]"
    # Only a *matching* pair is stripped.
    assert_line --index 3 '["600]'
}

@test "load_dotenv skips blank lines and comments" {
    make_fake_repo
    write_env "$FAKE_ROOT/.env" \
        '# a comment' \
        '' \
        '   ' \
        'LIMIT=7'

    lib_run_err 'load_dotenv "$ALA_ENV_FILE"; printf "%s\n" "$LIMIT"'
    assert_success
    assert_output "7"

    run cat "$ERRFILE"
    assert_output ""
}

@test "load_dotenv strips the trailing CR of a CRLF file" {
    make_fake_repo
    printf 'WHISPER_MODEL=small\r\nLIMIT=3\r\n' > "$FAKE_ROOT/.env"

    lib_run 'load_dotenv "$ALA_ENV_FILE"; printf "[%s][%s]\n" "$WHISPER_MODEL" "$LIMIT"'
    assert_success
    assert_output "[small][3]"
}

@test "load_dotenv warns about a malformed line and names its line number" {
    make_fake_repo
    write_env "$FAKE_ROOT/.env" \
        'LIMIT=1' \
        'RADARR_API_KEY abc' \
        'not a config line at all'

    lib_run_err 'load_dotenv "$ALA_ENV_FILE"
        printf "%s\n" "$LIMIT" "${RADARR_API_KEY:-unset}"'
    assert_success
    assert_line --index 0 "1"
    assert_line --index 1 "unset"

    run cat "$ERRFILE"
    assert_line --index 0 "WARN: $FAKE_ROOT/.env:2: ignoring malformed line"
    assert_line --index 1 "WARN: $FAKE_ROOT/.env:3: ignoring malformed line"
    # The line number, never the line: it can still hold most of a key.
    refute_output --partial "abc"
}

@test "load_dotenv accepts an indented key without warning" {
    make_fake_repo
    printf '  LIMIT=7\n\t# indented comment\n\tWHISPER_MODEL=small\n' \
        > "$FAKE_ROOT/.env"

    lib_run_err 'load_dotenv "$ALA_ENV_FILE"; printf "[%s][%s]\n" "$LIMIT" "$WHISPER_MODEL"'
    assert_success
    assert_output "[7][small]"

    run cat "$ERRFILE"
    assert_output ""
}

@test "load_dotenv warns about an unknown key and does not set it" {
    make_fake_repo
    write_env "$FAKE_ROOT/.env" 'PATH=/evil' 'SOMETHING_ELSE=x' 'LIMIT=4'

    lib_run_err 'load_dotenv "$ALA_ENV_FILE"
        printf "%s\n" "${SOMETHING_ELSE:-unset}" "$LIMIT"'
    assert_success
    assert_line --index 0 "unset"
    assert_line --index 1 "4"

    run cat "$ERRFILE"
    assert_output --partial "ignoring unknown key PATH"
    assert_output --partial "ignoring unknown key SOMETHING_ELSE"
    # A .env must not be able to rewrite PATH.
    refute_output --partial "/evil"
}

@test "load_dotenv lets an already-set environment variable win over the file" {
    make_fake_repo
    write_env "$FAKE_ROOT/.env" 'FORCE_RESCAN=false' 'LIMIT=9'
    export FORCE_RESCAN=true

    lib_run 'load_dotenv "$ALA_ENV_FILE"; printf "%s\n" "$FORCE_RESCAN" "$LIMIT"'
    assert_success
    assert_line --index 0 "true"
    assert_line --index 1 "9"
}

@test "load_dotenv treats a set-but-empty variable as unset" {
    make_fake_repo
    write_env "$FAKE_ROOT/.env" 'LIMIT=4'
    # A caller that defaults its own variables before loading -- exactly what
    # the entry points do -- must not thereby void the .env.
    export LIMIT=

    lib_run 'load_dotenv "$ALA_ENV_FILE"; printf "%s\n" "$LIMIT"'
    assert_success
    assert_output "4"
}

@test "load_dotenv lets a non-exported shell variable win too" {
    make_fake_repo
    write_env "$FAKE_ROOT/.env" 'LIMIT=4'

    lib_run 'LIMIT=9; load_dotenv "$ALA_ENV_FILE"; printf "%s\n" "$LIMIT"'
    assert_success
    assert_output "9"
}

@test "load_dotenv keeps the first non-empty value of a duplicated key" {
    make_fake_repo
    write_env "$FAKE_ROOT/.env" \
        'WHISPER_MODEL=' \
        'WHISPER_MODEL=small' \
        'WHISPER_MODEL=large-v3' \
        'LIMIT=1' \
        'LIMIT=2'

    lib_run 'load_dotenv "$ALA_ENV_FILE"; printf "[%s][%s]\n" "$WHISPER_MODEL" "$LIMIT"'
    assert_success
    # The empty first assignment does not lock the key; the first non-empty
    # value does.
    assert_output "[small][1]"
}

@test "load_dotenv does not export what it sets" {
    make_fake_repo
    write_env "$FAKE_ROOT/.env" 'LIMIT=5'

    lib_run 'load_dotenv "$ALA_ENV_FILE"; env | grep -c "^LIMIT=" || true'
    assert_success
    assert_output "0"
}

@test "load_dotenv normalizes the Radarr and Sonarr base URLs" {
    make_fake_repo
    write_env "$FAKE_ROOT/.env" \
        'RADARR_URL=http://radarr:7878///' \
        'SONARR_URL=http://sonarr:8989/'

    lib_run 'load_dotenv "$ALA_ENV_FILE"; printf "%s\n" "$RADARR_URL" "$SONARR_URL"'
    assert_success
    assert_line --index 0 "http://radarr:7878"
    assert_line --index 1 "http://sonarr:8989"
}

@test "load_dotenv fails on a missing file without setting anything" {
    make_fake_repo

    lib_run 'load_dotenv "$FAKE_ROOT/nope.env"'
    assert_failure 1
}

# ------------------------------------------------------------------ arr_curl --

@test "arr_get returns the body and authenticates with the api key" {
    make_fake_repo
    start_fake_arr "$BATS_TESTS_DIR/fixtures"

    lib_run 'arr_get "$RADARR_URL/api/v3/system/status" "$RADARR_API_KEY"'
    assert_success
    assert_output --partial '"instanceName": "Radarr"'

    run arr_requests 'select(.path == "/radarr/api/v3/system/status") | .key_ok'
    assert_success
    assert_output "true"
}

@test "arr_get never puts the api key on the curl command line" {
    make_fake_repo
    make_bin
    install_shim curl
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    export FAKE_CURL_LOG="$BATS_TEST_TMPDIR/curl-argv.log"

    lib_run 'arr_get "$RADARR_URL/api/v3/system/status" "$RADARR_API_KEY" >/dev/null'
    assert_success

    # The wrapper ran and the request was authenticated, so the key did reach
    # the server -- just not through argv.
    run arr_requests 'select(.path == "/radarr/api/v3/system/status") | .key_ok'
    assert_output "true"

    run cat "$FAKE_CURL_LOG"
    assert_success
    refute_output --partial "radarr-key"
    refute_output --partial "X-Api-Key"
    assert_output --partial "-K -"
}

@test "arr_curl survives an api key containing quotes and backslashes" {
    make_fake_repo
    # curl's config parser would otherwise end the quoted header at the " and
    # eat the \c as an escape.
    export FAKE_RADARR_KEY='a"b\c'
    start_fake_arr "$BATS_TESTS_DIR/fixtures"

    lib_run 'arr_get "$RADARR_URL/api/v3/system/status" "$RADARR_API_KEY" >/dev/null'
    assert_success

    run arr_requests 'select(.path == "/radarr/api/v3/system/status") | .key_ok'
    assert_success
    assert_output "true"
}

@test "arr_post sends the JSON body as a POST" {
    make_fake_repo
    start_fake_arr "$BATS_TESTS_DIR/fixtures"

    lib_run 'arr_post "$RADARR_URL/api/v3/command" "$RADARR_API_KEY" \
        "{\"name\":\"RescanMovie\"}"'
    assert_success
    assert_output --partial '"id": 42'

    run arr_requests 'select(.path == "/radarr/api/v3/command")
        | [.method, .body, .key_ok] == ["POST", "{\"name\":\"RescanMovie\"}", true]'
    assert_success
    assert_output "true"
}

@test "arr_get retries a failing request and succeeds on the third attempt" {
    make_fake_repo
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    arr_control '{"fail_count": {"/radarr/api/v3/movie": 2}}'
    export ARR_RETRY_DELAY=0

    lib_run_err 'arr_get "$RADARR_URL/api/v3/movie" "$RADARR_API_KEY"'
    assert_success
    assert_output --partial '"title"'

    run arr_request_count "/radarr/api/v3/movie"
    assert_output "3"

    # One warning per failed attempt, and none for the attempt that worked.
    run grep -c "^WARN: GET .* failed" "$ERRFILE"
    assert_output "2"
}

@test "arr_get gives up after the default three attempts" {
    make_fake_repo
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    arr_control '{"fail_count": {"/radarr/api/v3/movie": 99}}'
    export ARR_RETRY_DELAY=0

    lib_run_err 'arr_get "$RADARR_URL/api/v3/movie" "$RADARR_API_KEY"'
    assert_failure 1
    assert_output ""

    run arr_request_count "/radarr/api/v3/movie"
    assert_output "3"

    # curl -sf exits 22 on an HTTP error and says nothing itself, so the
    # library has to: three attempts, three warnings, the url and never the key.
    run cat "$ERRFILE"
    assert_line --index 0 "WARN: GET $RADARR_URL/api/v3/movie failed (curl exit 22), attempt 1/3"
    assert_line --index 1 "WARN: GET $RADARR_URL/api/v3/movie failed (curl exit 22), attempt 2/3"
    assert_line --index 2 "WARN: GET $RADARR_URL/api/v3/movie failed (curl exit 22), attempt 3/3"
    refute_output --partial "radarr-key"

    run grep -c "^WARN: GET .* failed" "$ERRFILE"
    assert_output "3"
}

@test "arr_get honours an explicit attempt count" {
    make_fake_repo
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    arr_control '{"fail_count": {"/radarr/api/v3/movie": 99}}'
    export ARR_RETRY_DELAY=0

    lib_run_err 'arr_get "$RADARR_URL/api/v3/movie" "$RADARR_API_KEY" 1'
    assert_failure 1

    run arr_request_count "/radarr/api/v3/movie"
    assert_output "1"

    run cat "$ERRFILE"
    assert_output "WARN: GET $RADARR_URL/api/v3/movie failed (curl exit 22), attempt 1/1"
}

# ------------------------------------------------------------------- python --

@test "python_meets_floor rejects an interpreter below 3.9" {
    make_fake_repo
    make_bin
    install_shim python3

    export FAKE_PY_VERSION=3.8.10
    lib_run 'python_meets_floor python3'
    assert_failure

    export FAKE_PY_VERSION=3.9.6
    lib_run 'python_meets_floor python3'
    assert_success

    # An empty interpreter path is rejected without invoking anything.
    lib_run 'python_meets_floor ""'
    assert_failure 1
}

@test "python_has_faster_whisper follows the interpreter's import probe" {
    make_fake_repo
    make_bin
    install_shim python3

    export FAKE_PY_HAS_FW=1
    lib_run 'python_has_faster_whisper python3'
    assert_success

    export FAKE_PY_HAS_FW=0
    lib_run 'python_has_faster_whisper python3'
    assert_failure
}

@test "find_phase2_python prefers the verify venv over a bare python3" {
    make_fake_repo
    make_bin
    install_shim python3
    fake_python "$FAKE_ROOT/verify/venv/bin/python"
    export FAKE_PY_HAS_FW=0

    lib_run 'find_phase2_python'
    assert_success
    assert_output "$FAKE_ROOT/verify/venv/bin/python"
}

@test "find_phase2_python falls back to python3 when the venv has no faster_whisper" {
    make_fake_repo
    make_bin
    install_shim python3
    export FAKE_PY_HAS_FW=1

    lib_run 'find_phase2_python'
    assert_success
    assert_output "python3"
}

@test "find_phase2_python fails when no interpreter has faster_whisper" {
    make_fake_repo
    make_bin
    install_shim python3
    export FAKE_PY_HAS_FW=0

    lib_run 'find_phase2_python'
    assert_failure 1
    assert_output ""
}

@test "PYTHON_BIN overrides the venv when it has faster_whisper" {
    make_fake_repo
    make_bin
    install_shim python3
    fake_python "$FAKE_ROOT/verify/venv/bin/python"
    fake_python "$BATS_TEST_TMPDIR/mypython"
    export FAKE_PY_HAS_FW=0
    export PYTHON_BIN="$BATS_TEST_TMPDIR/mypython"

    lib_run 'find_phase2_python'
    assert_success
    assert_output "$PYTHON_BIN"
}

@test "PYTHON_BIN without faster_whisper warns and falls through to the venv" {
    make_fake_repo
    make_bin
    install_shim python3
    fake_python "$FAKE_ROOT/verify/venv/bin/python"
    export FAKE_PY_HAS_FW=0
    export PYTHON_BIN="$BATS_TEST_TMPDIR/bin/python3"

    lib_run_err 'find_phase2_python'
    assert_success
    assert_output "$FAKE_ROOT/verify/venv/bin/python"

    run cat "$ERRFILE"
    assert_output --partial "WARN:"
    assert_output --partial "faster_whisper"
}

# --------------------------------------------------------------- static gate --

@test "shellcheck is clean on the library at -S warning" {
    if ! command -v shellcheck >/dev/null 2>&1; then
        skip "shellcheck is not installed"
    fi

    run bash -c "cd '$ROOT' && shellcheck -S warning lib/common.sh"
    assert_success
    assert_output ""
}

@test "the library uses no bash 4 only syntax" {
    run bash -c "cd '$ROOT' && grep -nE 'mapfile|readarray|declare -A|\\\$\\{[A-Za-z_]+(,,|\\^\\^)|&>>|local -n' lib/common.sh"
    assert_output ""
}

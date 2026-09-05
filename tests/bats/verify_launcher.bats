#!/usr/bin/env bats
#
# verify/verify-audio-language.sh -- the phase 2 pre-flight + launcher.
#
# The launcher never runs Python: its whole job is to decide WHICH interpreter
# phase 2 runs under, to refuse early and helpfully when it cannot, and to hand
# the worker a clean environment. So every test here drives the real script with
# PATH shims and asserts on the decision it made -- the argv it handed the
# worker, the interpreter it picked, the hint it printed, the exit status.
#
# The tree is copied into $BATS_TEST_TMPDIR (verify/ AND lib/, because the
# launcher sources ../lib/common.sh relative to itself) so that a venv, a
# reports/ directory or a .env created by a test never lands in the checkout.
#
# Everything runs through "$BASH_UNDER_TEST" (bash 3.2 on macOS): V1 is the
# regression that started this file -- "${EXTRA_ARGS[@]}" on an empty array
# under `set -u` aborts the DEFAULT configuration on bash < 4.4.

bats_require_minimum_version 1.5.0

load helpers/common
load helpers/shims

setup() {
    make_bin
    install_shim ffmpeg ffprobe python3 df uname

    TMP="$BATS_TEST_TMPDIR"
    cp -R "$ROOT/verify" "$TMP/verify"
    cp -R "$ROOT/lib" "$TMP/lib"
    # A developer's real venv must not travel into the fake repository.
    rm -rf "$TMP/verify/venv"

    LAUNCHER="$TMP/verify/verify-audio-language.sh"
    WORKER="$TMP/verify/verify_audio_language.py"
    IN="$TMP/in.csv"
    OUT="$TMP/reports/out.csv"
    write_csv "$IN" \
        "App,Title,FilePath,AudioLanguages" \
        "Radarr,Il Film,/media/film.mkv,English"

    ARGLOG="$TMP/arglog.txt"
    VENV_ARGLOG="$TMP/venv-arglog.txt"
    DFLOG="$TMP/df.log"
    export FAKE_PY_ARGLOG="$ARGLOG"
    export FAKE_PY_ARGLOG_VENV="$VENV_ARGLOG"
    export FAKE_DF_LOG="$DFLOG"

    # Point .env discovery at a file that does not exist, so the developer's
    # own .env can never reach a test. V18 overrides this deliberately.
    export ALA_DOTENV_FILE="$TMP/absent.env"
}

teardown() {
    # V21 leaves a mode 500 directory behind; bats' own cleanup must not trip
    # over it on a host where the parent permissions are not enough.
    chmod -R u+rwX "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# --------------------------------------------------------------------------
# local helpers
# --------------------------------------------------------------------------

run_launcher() {
    run --separate-stderr "$BASH_UNDER_TEST" "$LAUNCHER" "$@"
}

assert_stderr_contains() {
    if [[ "$stderr" != *"$1"* ]]; then
        printf 'expected stderr to contain:\n  %s\nstderr was:\n%s\n' \
            "$1" "$stderr" >&2
        return 1
    fi
}

refute_stderr_contains() {
    if [[ "$stderr" == *"$1"* ]]; then
        printf 'expected stderr NOT to contain:\n  %s\nstderr was:\n%s\n' \
            "$1" "$stderr" >&2
        return 1
    fi
}

# install_venv_shim -- the same python3 shim at the venv location. It answers
# FAKE_PY_HAS_FW_VENV / FAKE_PY_ARGLOG_VENV instead of the system variables, so
# a test can give the venv a different answer than the system interpreter.
install_venv_shim() {
    mkdir -p "$TMP/verify/venv/bin"
    cp "$BATS_TESTS_DIR/fakes/bin/python3" "$TMP/verify/venv/bin/python"
    chmod +x "$TMP/verify/venv/bin/python"
}

# alt_python <path> -- a standalone interpreter that answers every probe
# successfully and logs the worker invocation to $ALT_PY_LOG. Deliberately not
# the shim: it must be immune to FAKE_PY_HAS_FW, so that a test proving
# PYTHON_BIN was honoured cannot be satisfied by the system shim.
alt_python() {
    cat > "$1" <<'EOF'
#!/bin/sh
for arg in "$@"; do
    case "$arg" in
        *.py) printf '%s\n' "$*" >> "$ALT_PY_LOG"; exit 0 ;;
    esac
done
exit 0
EOF
    chmod +x "$1"
}

# arglog_line <file> -- the invocation line (the environment dump follows it).
arglog_line() {
    head -1 "$1"
}

# --------------------------------------------------------------------------
# V1-V2: the worker invocation
# --------------------------------------------------------------------------

@test "V1: the default configuration runs the worker with only --input/--output" {
    run_launcher "$IN" "$OUT"
    assert_success

    run arglog_line "$ARGLOG"
    assert_output "$WORKER --input $IN --output $OUT"
}

@test "V2: LIMIT / RETRY_ERRORS / NO_RESUME become worker flags" {
    export LIMIT=3 RETRY_ERRORS=true NO_RESUME=true

    run_launcher "$IN" "$OUT"
    assert_success

    run arglog_line "$ARGLOG"
    assert_output "$WORKER --input $IN --output $OUT --limit 3 --retry-errors --no-resume"
}

# --------------------------------------------------------------------------
# V3-V7, V10: interpreter discovery and the install recipe
# --------------------------------------------------------------------------

@test "V3: --check with a system faster-whisper is ready, needs no input and runs nothing" {
    rm -f "$IN"
    export FAKE_PY_HAS_FW=1

    run_launcher --check
    assert_success
    assert_stderr_contains "[OK] phase 2 environment is ready (python via: python3)"
    [ ! -e "$ARGLOG" ]
}

@test "V4: --check without the package prints the venv recipe, exits 1 and creates no venv" {
    export FAKE_PY_HAS_FW=0 FAKE_PY_VENV_OK=1

    run_launcher --check
    assert_failure 1
    assert_stderr_contains "faster-whisper"
    assert_stderr_contains "python3 -m venv \"$TMP/verify/venv\""
    assert_stderr_contains "install -r \"$TMP/verify/requirements.txt\""
    [ ! -d "$TMP/verify/venv" ]
}

@test "V5: the venv interpreter is used when the system one lacks the package" {
    install_venv_shim
    export FAKE_PY_HAS_FW=0 FAKE_PY_HAS_FW_VENV=1

    run_launcher "$IN" "$OUT"
    assert_success
    assert_stderr_contains "venv"

    # The venv shim wrote the log, the system shim was never handed the worker.
    run arglog_line "$VENV_ARGLOG"
    assert_output "$WORKER --input $IN --output $OUT"
    [ ! -e "$ARGLOG" ]
}

@test "V20: the venv wins even when the system interpreter also has the package" {
    install_venv_shim
    export FAKE_PY_HAS_FW=1 FAKE_PY_HAS_FW_VENV=1

    run_launcher "$IN" "$OUT"
    assert_success
    assert_stderr_contains "faster-whisper found (venv: $TMP/verify/venv)"

    run arglog_line "$VENV_ARGLOG"
    assert_output "$WORKER --input $IN --output $OUT"
    [ ! -e "$ARGLOG" ]

    # And the path the orchestrator parses out of --check is the venv's.
    run_launcher --check
    assert_success
    assert_stderr_contains "python via: $TMP/verify/venv/bin/python"
}

@test "V6: an existing venv without the package gets the pip-into-venv recipe" {
    install_venv_shim
    export FAKE_PY_HAS_FW=0 FAKE_PY_HAS_FW_VENV=0

    run_launcher --check
    assert_failure 1
    assert_stderr_contains "\"$TMP/verify/venv/bin/pip\" install -r \"$TMP/verify/requirements.txt\""
    refute_stderr_contains "python3 -m venv"
}

@test "V7: a venv-incapable python3 gets the pythonX.Y-venv package hint" {
    install_shim apt
    export FAKE_UNAME=Linux
    export FAKE_PY_HAS_FW=0 FAKE_PY_VENV_OK=0 FAKE_PY_VERSION=3.12.1

    run_launcher --check
    assert_failure 1
    assert_stderr_contains "sudo apt install -y python3.12-venv"
}

@test "V10: pip only matters when no interpreter has faster-whisper" {
    export FAKE_PY_HAS_PIP=0 FAKE_PY_HAS_FW=1

    run_launcher "$IN" "$OUT"
    assert_success
    [ -s "$ARGLOG" ]
    refute_stderr_contains "pip for python3 not found"

    rm -f "$ARGLOG"
    export FAKE_PY_HAS_FW=0

    run_launcher "$IN" "$OUT"
    assert_failure 1
    assert_stderr_contains "pip for python3 not found"
}

# --------------------------------------------------------------------------
# V8-V9: input and ffmpeg
# --------------------------------------------------------------------------

@test "V8: a missing input CSV stops the run" {
    rm -f "$IN"

    run_launcher "$IN" "$OUT"
    assert_failure 1
    assert_stderr_contains "Input CSV not found: $IN"
    [ ! -e "$ARGLOG" ]
}

@test "V9: a missing ffmpeg is reported with the hint for this OS" {
    rm -f "$BATS_TEST_TMPDIR/bin/ffmpeg"

    export FAKE_UNAME=Darwin
    run_launcher "$IN" "$OUT"
    assert_failure 1
    assert_stderr_contains "brew install ffmpeg"
    [ ! -e "$ARGLOG" ]

    export FAKE_UNAME=Linux
    install_shim apt
    run_launcher "$IN" "$OUT"
    assert_failure 1
    assert_stderr_contains "sudo apt update && sudo apt install -y ffmpeg"
    [ ! -e "$ARGLOG" ]
}

# --------------------------------------------------------------------------
# V11-V12: disk space and TEMP_DIR
# --------------------------------------------------------------------------

@test "V11: the disk guard refuses too little space and passes enough" {
    export MIN_FREE_SPACE_MB=500 FAKE_DF_AVAIL_MB=100

    run_launcher "$IN" "$OUT"
    assert_failure 1
    assert_stderr_contains "Only 100 MB free"
    assert_stderr_contains "TEMP_DIR=/path/with/space"
    [ ! -e "$ARGLOG" ]

    export FAKE_DF_AVAIL_MB=10000
    run_launcher "$IN" "$OUT"
    assert_success
    [ -s "$ARGLOG" ]
}

@test "V12: a TEMP_DIR that does not exist yet is created and is what df is asked about" {
    export TEMP_DIR="$TMP/scratch/samples"

    run_launcher "$IN" "$OUT"
    assert_success
    [ -d "$TEMP_DIR" ]
    run grep -F -- "$TEMP_DIR" "$DFLOG"
    assert_success
}

@test "V21: a TEMP_DIR that cannot be created is refused in our own words" {
    if [[ "$(id -u)" -eq 0 ]]; then
        skip "root writes into a mode 500 directory regardless"
    fi
    mkdir -p "$TMP/readonly"
    chmod 500 "$TMP/readonly"
    export TEMP_DIR="$TMP/readonly/samples"

    run_launcher "$IN" "$OUT"
    assert_failure 1
    assert_stderr_contains "cannot create directory: $TEMP_DIR"
    # mkdir's own diagnostic reads like a crash mid-run; ours reads like a
    # launcher that refused to start.
    refute_stderr_contains "mkdir:"
    [ ! -e "$ARGLOG" ]
}

# --------------------------------------------------------------------------
# V13-V15: the Python floor, exit status pass-through, argument order
# --------------------------------------------------------------------------

@test "V13: an interpreter below the Python floor is refused before the worker runs" {
    export FAKE_PY_VERSION=3.8.10 FAKE_PY_HAS_FW=1

    run_launcher "$IN" "$OUT"
    assert_failure 1
    assert_stderr_contains "Python 3.9+ is required"
    assert_stderr_contains "3.8"
    [ ! -e "$ARGLOG" ]
}

@test "V14: the worker's exit status is the launcher's" {
    export FAKE_PY_EXIT=3

    run_launcher "$IN" "$OUT"
    assert_failure 3
    [ -s "$ARGLOG" ]
}

@test "V15: --check is accepted after the positional arguments" {
    run_launcher "$IN" "$OUT" --check
    assert_success
    assert_stderr_contains "phase 2 environment is ready (python via: python3)"
    [ ! -e "$ARGLOG" ]
}

# --------------------------------------------------------------------------
# V19: usage errors; V16-V18: the worker's environment
# --------------------------------------------------------------------------

@test "V19: a usage error is refused with a pointer to --help" {
    run_launcher --bogus
    assert_failure 1
    assert_stderr_contains "unknown option: --bogus"
    assert_stderr_contains "Try --help."
    [ ! -e "$ARGLOG" ]

    run_launcher "$IN" "$OUT" one-too-many
    assert_failure 1
    assert_stderr_contains "too many arguments"
    [ ! -e "$ARGLOG" ]
}

@test "V16: the *arr API keys are stripped from the worker's environment" {
    export RADARR_API_KEY=radarr-secret SONARR_API_KEY=sonarr-secret
    export RADARR_URL=http://radarr.local:7878

    run_launcher "$IN" "$OUT"
    assert_success

    # RADARR_URL proves the shim does dump RADARR_*: the absence of the key is
    # a fact about the environment, not about what the shim bothers to log.
    run grep -c '^RADARR_URL=http://radarr.local:7878$' "$ARGLOG"
    assert_output "1"
    run grep -c 'API_KEY' "$ARGLOG"
    assert_output "0"
}

@test "V17: an explicit PYTHON_BIN with the package is used as it is" {
    alt_python "$TMP/mypython"
    export ALT_PY_LOG="$TMP/alt.log"
    export PYTHON_BIN="$TMP/mypython"
    # The system interpreter could not have satisfied this run.
    export FAKE_PY_HAS_FW=0

    run_launcher "$IN" "$OUT"
    assert_success

    run arglog_line "$ALT_PY_LOG"
    assert_output "$WORKER --input $IN --output $OUT"
    [ ! -e "$ARGLOG" ]
}

@test "V18: .env reaches the worker's environment and the caller's value still wins" {
    unset ALA_DOTENV_FILE
    printf 'WHISPER_MODEL=tiny\n' > "$TMP/.env"

    run_launcher "$IN" "$OUT"
    assert_success
    run grep -c '^WHISPER_MODEL=tiny$' "$ARGLOG"
    assert_output "1"

    rm -f "$ARGLOG"
    export WHISPER_MODEL=base

    run_launcher "$IN" "$OUT"
    assert_success
    run grep -c '^WHISPER_MODEL=base$' "$ARGLOG"
    assert_output "1"
}

@test "dependency imports do not inherit the arr API keys" {
    export RADARR_API_KEY=radarr-secret SONARR_API_KEY=sonarr-secret
    export PYTHON_BIN="$TMP/private-python"
    export PROBE_LOG="$TMP/probe-env.log"
    cat > "$PYTHON_BIN" <<'EOF'
#!/bin/sh
printf 'probe\n' >> "$PROBE_LOG"
env | grep -E '^(RADARR_API_KEY|SONARR_API_KEY)=' >> "$PROBE_LOG" || true
exit 0
EOF
    chmod +x "$PYTHON_BIN"

    run_launcher --check
    assert_success
    [ -s "$PROBE_LOG" ]
    run grep -c 'API_KEY=' "$PROBE_LOG"
    assert_output "0"
}

@test "the disk guard compares decimal MB values without octal or integer overflow" {
    export FAKE_DF_AVAIL_MB=100
    local minimum
    for minimum in 0000101 18446744073709551616; do
        export MIN_FREE_SPACE_MB="$minimum"
        run_launcher "$IN" "$OUT"
        assert_failure 1
        assert_stderr_contains "Only 100 MB free"
        [ ! -e "$ARGLOG" ]
    done
    export MIN_FREE_SPACE_MB=0000100
    run_launcher "$IN" "$OUT"
    assert_success
    [ -s "$ARGLOG" ]
}

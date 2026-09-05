#!/usr/bin/env bats
#
# arr-language-audit.sh -- the interactive orchestrator.
#
# The orchestrator is a menu: it never computes anything itself, it decides
# WHAT to run, WITH WHICH arguments and WITH WHICH environment, and it renders
# what the last run left behind. So every test here either calls one of its
# functions directly -- the script is sourced, which is only possible because
# `main` now runs behind a BASH_SOURCE guard -- or drives the whole script and
# asserts on the argv and the environment the recorder saw.
#
# The tree is copied into $BATS_TEST_TMPDIR (the script, lib/, verify/) so ROOT
# resolves inside the sandbox: reports/, a venv or a .env created by a test can
# never land in the checkout. The three programs the menu drives are replaced
# by the recorder shim.
#
# Everything runs through "$BASH_UNDER_TEST" (bash 3.2 on macOS): O9 is the
# regression that started this file -- "${flag[@]}" on an EMPTY array under
# `set -u` aborts before bash 4.4, which killed `ask_yesno ... yes` under
# whiptail, `ask_menu` with no default and `action_serve` with a blank port.

bats_require_minimum_version 1.5.0

load helpers/common
load helpers/fake_arr
load helpers/shims

setup() {
    make_bin

    TMP="$BATS_TEST_TMPDIR"
    mkdir -p "$TMP/scan" "$TMP/verify"
    cp "$ROOT/arr-language-audit.sh" "$TMP/arr-language-audit.sh"
    cp -R "$ROOT/lib" "$TMP/lib"
    cp "$ROOT/verify/requirements.txt" "$TMP/verify/requirements.txt"

    ALA="$TMP/arr-language-audit.sh"
    SCAN_SH="$TMP/scan/find-missing-italian-audio.sh"
    VERIFY_SH="$TMP/verify/verify-audio-language.sh"
    REPORT_PY="$TMP/verify/report.py"
    REPORTS="$TMP/reports"
    CSV="$REPORTS/missing-italian-audio.csv"
    VERIFIED_CSV="$REPORTS/verified-language-results.csv"
    HTML="$REPORTS/verified-language-results.html"

    # The three programs the menu drives, plus a stand-in interpreter for
    # report.py (which is never executed directly: PHASE2_PYTHON runs it).
    install_recorder "$SCAN_SH"
    install_recorder "$VERIFY_SH"
    install_recorder "$TMP/fakepy"
    FAKEPY="$TMP/fakepy"
    printf '# placeholder; the tests run it through PHASE2_PYTHON\n' > "$REPORT_PY"

    RECORDER_LOG="$TMP/recorder.log"
    : > "$RECORDER_LOG"
    export RECORDER_LOG

    # A .env that does not exist, so the developer's own configuration can
    # never reach a test (O7 points this at a file of its own).
    export ALA_DOTENV_FILE="$TMP/absent.env"
    # No *arr configuration unless a test provides one.
    unset RADARR_URL RADARR_API_KEY SONARR_URL SONARR_API_KEY
    export SKIP_RADARR=false SKIP_SONARR=false

    # Plain menu by default; the whiptail tests clear this and install the shim.
    export ARR_PLAIN_MENU=1
    export FAKE_WT_LOG="$TMP/whiptail.log"

    export ALA_SCRIPT="$ALA"
    cat > "$TMP/driver.sh" <<'DRIVER'
#!/usr/bin/env bash
# Source the orchestrator -- which must have no side effects -- then run the
# shell code passed as arguments. No errexit: neither has the script.
set -uo pipefail
. "${ALA_SCRIPT:?}"
eval "$*"
DRIVER
    chmod +x "$TMP/driver.sh"
}

teardown() {
    stop_fake_arr
}

# --------------------------------------------------------------------------
# local helpers
# --------------------------------------------------------------------------

# run_ala <shell-code> -- source the orchestrator in a fresh bash and run the
# code against its functions and globals.
run_ala() {
    run --separate-stderr "$BASH_UNDER_TEST" "$TMP/driver.sh" "$@"
}

# run_guarded <seconds> <command>... -- `run` with a hard wall-clock cap, so a
# test that drives the interactive loop cannot hang the suite. macOS ships no
# timeout(1); perl's alarm survives exec and is everywhere.
run_guarded() {
    local secs="$1"
    shift
    if [[ -x /usr/bin/perl ]]; then
        run --separate-stderr /usr/bin/perl -e \
            'alarm shift @ARGV; exec @ARGV or die "exec: $!"' "$secs" "$@"
    else
        run --separate-stderr "$@"
    fi
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

# assert_log_contains <substring> -- the recorder log, argv and environment.
assert_log_contains() {
    if ! grep -Fq -- "$1" "$RECORDER_LOG"; then
        printf 'expected the recorder log to contain:\n  %s\nlog was:\n%s\n' \
            "$1" "$(cat "$RECORDER_LOG")" >&2
        return 1
    fi
}

refute_log_contains() {
    if grep -Fq -- "$1" "$RECORDER_LOG"; then
        printf 'expected the recorder log NOT to contain:\n  %s\nlog was:\n%s\n' \
            "$1" "$(cat "$RECORDER_LOG")" >&2
        return 1
    fi
}

# make_csv <path> -- a phase 1 CSV with one row.
make_csv() {
    mkdir -p "$(dirname "$1")"
    write_csv "$1" \
        "App,Title,Year,Episode,AudioLanguages,Path" \
        "Radarr,Il Film,2019,,English,/media/film.mkv"
}

# verdict_row <verdict> -- one phase 2 CSV row carrying that verdict.
verdict_row() {
    printf 'Radarr,Il Film,2019,,English,en,0.99,%s,/media/film.mkv,10,20' "$1"
}

# --------------------------------------------------------------------------
# O1-O4: what the menu renders
# --------------------------------------------------------------------------

@test "O1: recommended_action names the next step in every state" {
    mkdir -p "$REPORTS"

    run_ala 'ENV_READY=false; PHASE2_READY=true; recommended_action'
    assert_output "8"

    # Reachable, nothing scanned yet.
    run_ala 'ENV_READY=true; PHASE2_READY=true; recommended_action'
    assert_output "1"

    # A header-only phase 1 CSV counts as scanned: it exists, so move on.
    write_csv "$CSV" "App,Title,Year,Episode,AudioLanguages,Path"
    run_ala 'ENV_READY=true; PHASE2_READY=false; recommended_action'
    assert_output "6"

    run_ala 'ENV_READY=true; PHASE2_READY=true; recommended_action'
    assert_output "2"

    # A phase 2 CSV older than the phase 1 CSV is stale.
    touch -t 202001010000 "$VERIFIED_CSV"
    run_ala 'ENV_READY=true; PHASE2_READY=true; recommended_action'
    assert_output "2"

    touch "$VERIFIED_CSV"
    run_ala 'ENV_READY=true; PHASE2_READY=true; recommended_action'
    assert_output "3"

    touch -t 202001010000 "$HTML"
    run_ala 'ENV_READY=true; PHASE2_READY=true; recommended_action'
    assert_output "3"

    touch "$HTML"
    run_ala 'ENV_READY=true; PHASE2_READY=true; recommended_action'
    assert_output "4"
}

@test "O2: csv_row_count does not count the header, and says so when there is no file" {
    mkdir -p "$REPORTS"

    run_ala "csv_row_count '$CSV'"
    assert_success
    [ "$output" = "-" ]

    write_csv "$CSV" "App,Title,Year,Episode,AudioLanguages,Path"
    run_ala "csv_row_count '$CSV'"
    assert_output "0"

    write_csv "$CSV" \
        "App,Title,Year,Episode,AudioLanguages,Path" \
        "Radarr,A,2019,,English,/a.mkv" \
        "Radarr,B,2020,,English,/b.mkv"
    run_ala "csv_row_count '$CSV'"
    assert_output "2"
}

@test "O3: verdict_summary counts every verdict class on a CRLF CSV" {
    mkdir -p "$REPORTS"

    run_ala 'verdict_summary'
    assert_output "not run yet"

    write_csv "$VERIFIED_CSV" \
        "App,Title,Year,Episode,DeclaredAudioLanguages,DetectedLanguage,Confidence,Verdict,Path,FileSize,FileMtime"
    run_ala 'verdict_summary'
    assert_output "0 mistagged / 0 confirmed not Italian / 0 low confidence / 0 errors"

    write_csv "$VERIFIED_CSV" \
        "App,Title,Year,Episode,DeclaredAudioLanguages,DetectedLanguage,Confidence,Verdict,Path,FileSize,FileMtime" \
        "$(verdict_row MISTAGGED_IS_ITALIAN)" \
        "$(verdict_row MISTAGGED_IS_ITALIAN)" \
        "$(verdict_row CONFIRMED_NOT_ITALIAN)" \
        "$(verdict_row LOW_CONFIDENCE)" \
        "$(verdict_row FILE_NOT_FOUND)" \
        "$(verdict_row EXTRACTION_FAILED)" \
        "$(verdict_row DETECTION_FAILED)"

    run_ala 'verdict_summary'
    assert_output "2 mistagged / 1 confirmed not Italian / 1 low confidence / 3 errors"
}

@test "O4: status_text carries the identity, both apps, the counts and the next step" {
    mkdir -p "$REPORTS"
    make_csv "$CSV"

    run_ala 'RADARR_LINE="OK   v4   [Radarr]   http://r"
             SONARR_LINE="skipped (SKIP_SONARR=true)"
             TOOLS_LINE="tools: phase 1 ready"
             PHASE2_NOTE="phase 2: ready"
             ENV_READY=true; PHASE2_READY=true
             status_text'
    assert_success
    assert_output --partial "arr-language-audit"
    assert_output --partial "Radarr : OK   v4   [Radarr]   http://r"
    assert_output --partial "Sonarr : skipped (SKIP_SONARR=true)"
    assert_output --partial "Phase 1 CSV : 1 rows"
    assert_output --partial "Phase 2     : not run yet"
    assert_output --partial "HTML report : not built"
    assert_output --partial "Next: run 'Verify suspects (phase 2)'"
    refute_output --partial "No Radarr/Sonarr reachable"

    run_ala 'RADARR_LINE="not configured"; SONARR_LINE="not configured"
             TOOLS_LINE=""; PHASE2_NOTE=""
             ENV_READY=false; PHASE2_READY=false
             status_text'
    assert_success
    assert_output --partial ">> No Radarr/Sonarr reachable"
    assert_output --partial "Next: configure Radarr/Sonarr"
}

# --------------------------------------------------------------------------
# O5-O6, O18, O21: the pre-flight
# --------------------------------------------------------------------------

@test "O5: probe_app reports one attempt per app and never puts the key on argv" {
    run_ala 'probe_app "" ""'
    assert_failure
    assert_output "not configured"

    run_ala 'probe_app "http://radarr.test:7878" "YOUR_RADARR_API_KEY_HERE"'
    assert_failure
    assert_output "not configured"

    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    install_shim curl
    export FAKE_CURL_LOG="$TMP/curl.log"

    run_ala 'probe_app "$RADARR_URL" "$RADARR_API_KEY"'
    assert_success
    assert_output "OK   v4.0.0.1234   [Radarr]   $RADARR_URL"

    # The key travelled through curl's --config file, not its command line.
    run grep -c -- "$RADARR_API_KEY" "$FAKE_CURL_LOG"
    assert_output "0"
    # Positive control: the log really does hold this invocation.
    run grep -c -- "$RADARR_URL/api/v3/system/status" "$FAKE_CURL_LOG"
    assert_output "1"

    : > "$FAKE_ARR_LOG"
    run_ala 'probe_app "$RADARR_URL" "wrong-key"'
    assert_failure
    assert_output --partial "UNREACHABLE ($RADARR_URL)"
    # One attempt, not three: the retries belong to the scan script.
    run arr_request_count "/radarr/api/v3/system/status"
    assert_output "1"

    # A CRLF response leaves no carriage return in the status line.
    arr_control '{"crlf": true}'
    run_ala 'probe_app "$RADARR_URL" "$RADARR_API_KEY"'
    assert_success
    [[ "$output" != *$'\r'* ]] || {
        printf 'the status line kept a carriage return: %q\n' "$output" >&2
        return 1
    }
}

@test "O6: run_preflight takes the phase 2 verdict from the launcher's --check" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    export SKIP_SONARR=true
    export RECORDER_OUT="[OK] phase 2 environment is ready (python via: /x/python)."

    run_ala 'run_preflight
             echo "ready=$PHASE2_READY"
             echo "python=$PHASE2_PYTHON"
             echo "radarr_ok=$RADARR_OK"
             echo "sonarr=$SONARR_LINE"
             echo "env_ready=$ENV_READY"
             echo "note=$PHASE2_NOTE"'
    assert_success
    assert_line "ready=true"
    assert_line "python=/x/python"
    assert_line "radarr_ok=true"
    assert_line "sonarr=skipped (SKIP_SONARR=true)"
    assert_line "env_ready=true"

    # The launcher is the single source of truth: it said no, so phase 2 is
    # not ready, whatever this machine's python3 happens to import.
    export RECORDER_RC=1
    export RECORDER_OUT="faster-whisper is not installed"
    run_ala 'run_preflight
             echo "ready=$PHASE2_READY"
             echo "python=$PHASE2_PYTHON"'
    assert_success
    assert_line "ready=false"
    assert_line "python="
}

@test "O18: an unreachable Radarr and Sonarr are probed once, concurrently" {
    install_shim curl
    export FAKE_CURL_LOG="$TMP/curl.log"
    # TEST-NET-1: routable nowhere, so the probe runs into its own -m timeout
    # instead of a fast connection refused.
    export RADARR_URL="http://192.0.2.1:7878" RADARR_API_KEY=k1
    export SONARR_URL="http://192.0.2.1:8989" SONARR_API_KEY=k2
    # 5s per probe against the 8s bound below: concurrent is ~5s, sequential
    # would be ~10s. At the default 3s BOTH shapes fit under 8s and the bound
    # would prove nothing about concurrency.
    export ARR_PROBE_TIMEOUT=5

    local started elapsed
    started="$(date +%s)"
    run_ala 'run_preflight
             echo "radarr=$RADARR_OK"
             echo "sonarr=$SONARR_OK"
             echo "env_ready=$ENV_READY"'
    elapsed=$(( $(date +%s) - started ))

    assert_success
    assert_line "radarr=false"
    assert_line "sonarr=false"
    assert_line "env_ready=false"

    # One attempt each, and both in flight at once: two 5s probes one after
    # the other cannot fit in 8s, so this bound fails on a sequential
    # pre-flight. Sequentially, with the old three attempts of 5s plus a 1s
    # sleep, this was 36 seconds of dead menu.
    run grep -c "api/v3/system/status" "$FAKE_CURL_LOG"
    assert_output "2"
    [ "$elapsed" -lt 8 ] || {
        printf 'the pre-flight took %ss with both apps unreachable\n' "$elapsed" >&2
        return 1
    }
}

@test "O7: a .env cannot execute anything and cannot set what it likes" {
    cat > "$TMP/hostile.env" <<'ENVFILE'
RADARR_URL=http://radarr.test:7878
RADARR_API_KEY=from-dotenv
touch "$ALA_PWNED"
PATH=/nonexistent
IFS=:
ENVFILE
    export ALA_DOTENV_FILE="$TMP/hostile.env"
    export ALA_PWNED="$TMP/pwned"
    export SKIP_RADARR=true SKIP_SONARR=true

    run_ala 'run_preflight
             echo "url=$RADARR_URL"
             echo "key=$RADARR_API_KEY"
             echo "path_ok=$(command -v curl >/dev/null && echo yes || echo no)"'
    assert_success
    assert_line "url=http://radarr.test:7878"
    assert_line "key=from-dotenv"
    assert_line "path_ok=yes"
    [ ! -e "$TMP/pwned" ] || {
        printf 'the .env executed a command\n' >&2
        return 1
    }
    assert_stderr_contains "ignoring malformed line"
    assert_stderr_contains "ignoring unknown key PATH"
}

@test "O21: a second pre-flight re-reads a .env that changed under it" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    local url="$RADARR_URL" good_key="$RADARR_API_KEY"
    # start_fake_arr exports a working configuration; take it back out of the
    # environment, or it would (correctly) win over the file.
    unset RADARR_URL RADARR_API_KEY SONARR_URL SONARR_API_KEY
    export SKIP_SONARR=true
    export ALA_DOTENV_FILE="$TMP/reload.env"
    printf 'RADARR_URL=%s\nRADARR_API_KEY=%s\n' "$url" "stale-key" > "$ALA_DOTENV_FILE"

    # This is what "Reconfigure (.env) + re-check" does: the operator pastes
    # the real API key and asks for another pre-flight. The second probe must
    # use the new key, not the one the first pre-flight read.
    run_ala "run_preflight
             echo \"first=\$RADARR_OK\"
             printf 'RADARR_URL=%s\nRADARR_API_KEY=%s\n' '$url' '$good_key' > '$ALA_DOTENV_FILE'
             run_preflight
             echo \"second=\$RADARR_OK\"
             echo \"key=\$RADARR_API_KEY\""
    assert_success
    assert_line "first=false"
    assert_line "second=true"
    assert_line "key=$good_key"

    # And the server agrees: the key it was given was wrong the first time and
    # right the second.
    run arr_requests '.key_ok'
    assert_line --index 0 "false"
    assert_line --index 1 "true"

    # The other direction: a key given in the environment is an explicit
    # override and keeps winning, however often the file changes.
    export SKIP_RADARR=true SKIP_SONARR=true
    export RADARR_URL="http://env.test:7878" RADARR_API_KEY="from-environment"
    printf 'RADARR_URL=http://file.test:7878\nRADARR_API_KEY=file-key-a\n' > "$ALA_DOTENV_FILE"

    run_ala "run_preflight
             echo \"first=\$RADARR_API_KEY\"
             printf 'RADARR_URL=http://file.test:7878\nRADARR_API_KEY=file-key-b\n' > '$ALA_DOTENV_FILE'
             run_preflight
             echo \"second=\$RADARR_API_KEY\"
             echo \"url=\$RADARR_URL\""
    assert_success
    assert_line "first=from-environment"
    assert_line "second=from-environment"
    assert_line "url=http://env.test:7878"
}

# --------------------------------------------------------------------------
# O8-O10, O19: the ask_* helpers
# --------------------------------------------------------------------------

@test "O8: ask_yesno honours its default in the plain prompt" {
    run_ala 'ask_yesno "Proceed?" yes' <<< ""
    assert_success

    run_ala 'ask_yesno "Proceed?" no' <<< ""
    assert_failure

    run_ala 'ask_yesno "Proceed?" no' <<< "y"
    assert_success

    run_ala 'ask_yesno "Proceed?" yes' <<< "n"
    assert_failure

    # No terminal at all is not a yes.
    run_ala 'ask_yesno "Proceed?" yes' < /dev/null
    assert_failure
}

@test "O9: under whiptail on bash 3.2 an empty option array is not an error" {
    export ARR_PLAIN_MENU=""
    install_shim whiptail

    # `ask_yesno ... yes` drops --defaultno: an empty array expanded under
    # `set -u`, which aborted the whole session before bash 4.4.
    run_ala 'ask_yesno "Proceed?" yes'
    assert_success
    run cat "$FAKE_WT_LOG"
    assert_output --partial "--yesno Proceed?"
    refute_output --partial "--defaultno"

    : > "$FAKE_WT_LOG"
    run_ala 'ask_yesno "Proceed?" no'
    assert_success
    run cat "$FAKE_WT_LOG"
    assert_output --partial "--defaultno"

    # Same bug, second site: a menu with no pre-selected item.
    : > "$FAKE_WT_LOG"
    export FAKE_WT_OUT=1
    run_ala 'ask_menu "" "Pick one" 1 alpha'
    assert_success
    assert_output "1"
    run cat "$FAKE_WT_LOG"
    assert_output --partial "--menu Pick one 24 78 1 1 alpha"
    refute_output --partial "--default-item"

    : > "$FAKE_WT_LOG"
    run_ala 'ask_menu 2 "Pick one" 1 alpha 2 beta'
    assert_success
    run cat "$FAKE_WT_LOG"
    assert_output --partial "--default-item 2 --menu Pick one 24 78 2"
}

@test "O10: the plain menu falls back to its default tag and echoes a choice" {
    run_ala 'ask_menu 4 "Pick one" 1 alpha 4 delta' <<< ""
    assert_success
    assert_output "4"
    assert_stderr_contains "1) alpha"
    assert_stderr_contains "4) delta"

    run_ala 'ask_menu 4 "Pick one" 1 alpha 4 delta' <<< "1"
    assert_success
    assert_output "1"

    # End of input is a cancel, never a silent "take the recommendation".
    run_ala 'ask_menu 4 "Pick one" 1 alpha 4 delta' < /dev/null
    assert_failure
    assert_output ""
}

@test "O19: ask_input reports a whiptail Cancel as a failure, not as a blank" {
    export ARR_PLAIN_MENU=""
    install_shim whiptail
    export FAKE_WT_OUT="8080" FAKE_WT_RC=1

    run_ala 'ask_input "Port?" ""'
    assert_failure 1
    assert_output ""

    # And the caller abandons the action instead of running it with a default.
    make_csv "$VERIFIED_CSV"
    run_ala "PHASE2_PYTHON='$FAKEPY'; action_serve"
    refute_log_contains "report.py"

    export FAKE_WT_RC=0
    run_ala 'ask_input "Port?" ""'
    assert_success
    assert_output "8080"
}

# --------------------------------------------------------------------------
# O11-O15, O20: the actions
# --------------------------------------------------------------------------

@test "O11: action_scan forwards FORCE_RESCAN and --refresh, and reads exit 2" {
    make_csv "$CSV"

    # force = yes, refresh = yes, then the pause.
    run_ala 'ENV_READY=true; action_scan' <<< $'y\ny\n\n'
    assert_success
    assert_log_contains "argv: $SCAN_SH $CSV --refresh"
    assert_log_contains "env: FORCE_RESCAN=true"

    : > "$RECORDER_LOG"
    run_ala 'ENV_READY=true; action_scan' <<< $'n\nn\n\n'
    assert_success
    assert_log_contains "argv: $SCAN_SH $CSV"
    refute_log_contains "--refresh"
    assert_log_contains "env: FORCE_RESCAN=false"

    # Exit 2 is not a generic failure: the previous report is still on disk.
    export RECORDER_RC=2
    run_ala 'ENV_READY=true; action_scan' <<< $'n\nn\n\n'
    assert_stderr_contains "phase 1 finished with an unreachable app; previous report kept"

    export RECORDER_RC=1
    run_ala 'ENV_READY=true; action_scan' <<< $'n\nn\n\n'
    assert_stderr_contains "phase 1 exited with an error"

    # Nothing reachable and the user declines: nothing runs.
    unset RECORDER_RC
    : > "$RECORDER_LOG"
    run_ala 'ENV_READY=false; action_scan' <<< $'n\n'
    refute_log_contains "argv:"
}

@test "O12: action_verify passes the model, the limit and the retry flag" {
    make_csv "$CSV"

    # No phase 1 CSV: an explanation, and nothing is run.
    run_ala "PHASE2_READY=true; CSV='$TMP/never-scanned.csv'; action_verify" <<< $'\n'
    assert_failure 1
    assert_stderr_contains "Run 'Scan library (phase 1)' first."
    refute_log_contains "argv:"

    run_ala 'PHASE2_READY=false; PHASE2_NOTE="not installed"; action_verify' <<< $'\n'
    assert_failure 1
    assert_stderr_contains "Set up phase 2"
    refute_log_contains "argv:"

    # model = default (small), limit = 5, then the pause.
    run_ala 'PHASE2_READY=true; action_verify' <<< $'\n5\n\n'
    assert_success
    assert_log_contains "argv: $VERIFY_SH $CSV $VERIFIED_CSV"
    assert_log_contains "env: WHISPER_MODEL=small"
    assert_log_contains "env: LIMIT=5"
    assert_log_contains "env: RETRY_ERRORS=false"

    # An existing output adds the retry question.
    : > "$RECORDER_LOG"
    make_csv "$VERIFIED_CSV"
    run_ala 'PHASE2_READY=true; action_verify' <<< $'tiny\n\ny\n\n'
    assert_success
    assert_log_contains "env: WHISPER_MODEL=tiny"
    assert_log_contains "env: RETRY_ERRORS=true"

    # Exit 3 from the worker: finished, but nothing could be verified.
    export RECORDER_RC=3
    run_ala 'PHASE2_READY=true; action_verify' <<< $'\n\nn\n\n'
    assert_stderr_contains "phase 2 finished but every file errored (are the media paths mounted here?)"
}

@test "O13: action_serve builds the report.py command line it was asked for" {
    make_csv "$VERIFIED_CSV"

    # Blank port, no LAN: loopback and a free port, so no flag at all.
    run_ala "PHASE2_PYTHON='$FAKEPY'; action_serve" <<< $'\nn\n\n'
    assert_success
    assert_log_contains "argv: $FAKEPY $REPORT_PY $VERIFIED_CSV --serve"
    refute_log_contains "--port"
    refute_log_contains "--host"

    : > "$RECORDER_LOG"
    run_ala "PHASE2_PYTHON='$FAKEPY'; action_serve" <<< $'8080\nn\n\n'
    assert_success
    assert_log_contains "argv: $FAKEPY $REPORT_PY $VERIFIED_CSV --serve --port 8080"

    # Exposing it on the LAN is a deliberate yes, never the default.
    : > "$RECORDER_LOG"
    run_ala "PHASE2_PYTHON='$FAKEPY'; action_serve" <<< $'\ny\n\n'
    assert_success
    assert_log_contains "argv: $FAKEPY $REPORT_PY $VERIFIED_CSV --serve --host 0.0.0.0"

    : > "$RECORDER_LOG"
    run_ala "PHASE2_PYTHON='$FAKEPY'; action_serve" <<< $'8080\ny\n\n'
    assert_success
    assert_log_contains "argv: $FAKEPY $REPORT_PY $VERIFIED_CSV --serve --port 8080 --host 0.0.0.0"
}

@test "O14: action_report runs report.py with the phase 2 interpreter" {
    # No phase 2 CSV: an explanation, and nothing is run.
    run_ala "PHASE2_PYTHON='$FAKEPY'; action_report" <<< $'\n'
    assert_success
    refute_log_contains "argv:"

    make_csv "$VERIFIED_CSV"
    run_ala "PHASE2_PYTHON='$FAKEPY'; action_report" <<< $'\n'
    assert_success
    assert_log_contains "argv: $FAKEPY $REPORT_PY $VERIFIED_CSV"

    export RECORDER_RC=1
    run_ala "PHASE2_PYTHON='$FAKEPY'; action_report" <<< $'\n'
    assert_stderr_contains "report generation failed"
}

@test "O15: action_setup_phase2 installs the pinned requirements, not a bare package" {
    install_shim python3
    mkdir -p "$TMP/verify/venv/bin"
    printf '#!/bin/sh\nexit 0\n' > "$TMP/verify/venv/bin/python"
    chmod +x "$TMP/verify/venv/bin/python"
    install_recorder "$TMP/verify/venv/bin/pip"

    # The launcher says the environment is already good: nothing is installed.
    run_ala 'action_setup_phase2' <<< $'\n'
    assert_success
    refute_log_contains "install"

    # It says no: the venv is topped up from verify/requirements.txt.
    : > "$RECORDER_LOG"
    export RECORDER_RC=1
    run_ala 'action_setup_phase2' <<< $'y\n\n'
    assert_log_contains "argv: $TMP/verify/venv/bin/pip install --upgrade pip"
    assert_log_contains "argv: $TMP/verify/venv/bin/pip install -r $TMP/verify/requirements.txt"
    refute_log_contains "pip install faster-whisper"

    # And a no answer installs nothing.
    : > "$RECORDER_LOG"
    run_ala 'action_setup_phase2' <<< $'n\n'
    refute_log_contains "install"
}

@test "O20: the *arr API keys never reach phase 2 or the report" {
    export RADARR_URL="http://radarr.test:7878" RADARR_API_KEY="radarr-secret"
    export SONARR_URL="http://sonarr.test:8989" SONARR_API_KEY="sonarr-secret"
    export SKIP_RADARR=true SKIP_SONARR=true
    make_csv "$CSV"
    make_csv "$VERIFIED_CSV"

    run_ala "run_preflight
             PHASE2_READY=true
             action_verify
             PHASE2_PYTHON='$FAKEPY'
             action_report" <<< $'\n\nn\n\n\n'
    assert_success

    # Positive control: the recorder does dump RADARR_*/SONARR_*, so the
    # absence of the keys is a fact about the environment, not about the log.
    assert_log_contains "env: RADARR_URL=http://radarr.test:7878"
    assert_log_contains "env: SONARR_URL=http://sonarr.test:8989"
    run grep -c "API_KEY" "$RECORDER_LOG"
    assert_output "0"
    # All three children ran: --check, the worker and the report.
    run grep -c "^argv:" "$RECORDER_LOG"
    assert_output "3"

    # The report server is the fourth way out of this script, and it carries
    # the same guarantee. Its own log, so the assertion is about that child.
    : > "$RECORDER_LOG"
    run_ala "PHASE2_PYTHON='$FAKEPY'
             action_serve" <<< $'\n\n\n'
    assert_success
    assert_log_contains "argv: $FAKEPY $REPORT_PY $VERIFIED_CSV --serve"
    assert_log_contains "env: RADARR_URL=http://radarr.test:7878"
    run grep -c "API_KEY" "$RECORDER_LOG"
    assert_output "0"
}

# --------------------------------------------------------------------------
# O16-O17: the entry point
# --------------------------------------------------------------------------

@test "O16: main runs the menu loop and quits, and sourcing the script does not" {
    # Sourcing must not start the menu, create reports/ or shell out.
    rm -rf "$REPORTS"
    run_ala 'echo sourced'
    assert_success
    assert_output "sourced"
    [ ! -d "$REPORTS" ]
    refute_log_contains "argv:"

    run_guarded 30 "$BASH_UNDER_TEST" "$ALA" <<< $'x\n0\n'
    assert_success
    assert_stderr_contains "unknown choice: x"
    assert_stderr_contains "Bye."
    [ -d "$REPORTS" ]
}

@test "pipeline stops after a failed scan even when old reports exist" {
    make_csv "$CSV"
    make_csv "$VERIFIED_CSV"
    export RECORDER_RC=2

    run_ala 'ENV_READY=true; PHASE2_READY=true; action_pipeline' <<< $'y\nn\nn\n\n\n\n\n\n'
    assert_failure 2
    assert_log_contains "argv: $SCAN_SH"
    refute_log_contains "argv: $VERIFY_SH"
    refute_log_contains "$REPORT_PY"
}

@test "pipeline stops when verification is unavailable despite an old verdict CSV" {
    make_csv "$CSV"
    make_csv "$VERIFIED_CSV"

    run_ala 'ENV_READY=true; PHASE2_READY=false; action_pipeline' <<< $'y\nn\nn\n\n\n\n'
    assert_failure
    refute_log_contains "$REPORT_PY"
}

@test "pipeline stops after the verification worker fails" {
    make_csv "$CSV"
    make_csv "$VERIFIED_CSV"
    printf '#!/bin/sh\nexit 0\n' > "$SCAN_SH"
    export RECORDER_RC=3

    run_ala 'ENV_READY=true; PHASE2_READY=true; action_pipeline' <<< $'y\nn\nn\n\n\n\nn\n\n\n'
    assert_failure 3
    assert_log_contains "argv: $VERIFY_SH"
    refute_log_contains "$REPORT_PY"
}

@test "pipeline stops when the model prompt is cancelled" {
    make_csv "$CSV"
    make_csv "$VERIFIED_CSV"

    run_ala 'ENV_READY=true; PHASE2_READY=true; action_pipeline' <<< $'y\nn\nn'
    assert_failure
    refute_log_contains "argv: $VERIFY_SH"
    refute_log_contains "$REPORT_PY"
}

@test "probe_app rejects successful HTTP responses without a valid status object" {
    cp -R "$BATS_TESTS_DIR/fixtures" "$TMP/status-fixtures"
    start_fake_arr "$TMP/status-fixtures"
    local payload
    for payload in 'null' '[]' '{}' '"login required"' '{"version":null}' '{"version":42}'; do
        printf '%s\n' "$payload" > "$TMP/status-fixtures/radarr/system_status.json"
        run_ala 'probe_app "$RADARR_URL" "$RADARR_API_KEY"'
        assert_failure
        refute_output --partial 'OK '
    done
}

@test "reconfigure opens the active override or fallback dotenv" {
    install_recorder "$TMP/editor"
    export EDITOR="$TMP/editor"
    export ALA_DOTENV_FILE="$TMP/custom.env"
    printf 'WHISPER_MODEL=tiny\n' > "$ALA_DOTENV_FILE"

    run_ala 'preflight_apps() { :; }; action_configure' <<< $'\n'
    assert_success
    assert_log_contains "argv: $TMP/editor $TMP/custom.env"
    [ ! -e "$TMP/.env" ]

    unset ALA_DOTENV_FILE
    : > "$RECORDER_LOG"
    printf 'WHISPER_MODEL=base\n' > "$TMP/scan/.env"
    run_ala 'preflight_apps() { :; }; action_configure' <<< $'\n'
    assert_success
    assert_log_contains "argv: $TMP/editor $TMP/scan/.env"
    [ ! -e "$TMP/.env" ]
}

@test "reconfigure stops before launching an editor when dotenv creation fails" {
    install_recorder "$TMP/editor"
    export EDITOR="$TMP/editor"
    export ALA_DOTENV_FILE="$TMP/no-parent/custom.env"
    printf 'WHISPER_MODEL=small\n' > "$TMP/.env.example"

    run_ala 'action_configure' <<< $'\n'
    assert_failure
    refute_log_contains "argv: $TMP/editor"
    refute_log_contains "--check"
    refute_stderr_contains "Created "
}

@test "a failed HTML build propagates its exit status without claiming an output" {
    make_csv "$VERIFIED_CSV"
    export RECORDER_RC=2

    run_ala "PHASE2_PYTHON='$FAKEPY'; action_report" <<< $'\n'
    assert_failure 2
    refute_stderr_contains "HTML report:"
}

@test "phase 2 installation commands do not inherit arr API keys" {
    install_shim python3
    mkdir -p "$TMP/verify/venv/bin"
    printf '#!/bin/sh\nexit 0\n' > "$TMP/verify/venv/bin/python"
    chmod +x "$TMP/verify/venv/bin/python"
    install_recorder "$TMP/verify/venv/bin/pip"
    export RADARR_API_KEY=radarr-secret SONARR_API_KEY=sonarr-secret
    export RECORDER_RC=1

    run_ala 'preflight_apps() { :; }; action_setup_phase2' <<< $'y\n\n'
    assert_log_contains "install -r"
    refute_log_contains "API_KEY="
}

@test "preflight normalizes URLs supplied only by the process environment" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    local radarr_base="$RADARR_URL" sonarr_base="$SONARR_URL"
    export RADARR_URL="$radarr_base/// " SONARR_URL="$sonarr_base/ "

    run_ala 'run_preflight
             echo "radarr=$RADARR_OK:$RADARR_URL"
             echo "sonarr=$SONARR_OK:$SONARR_URL"'
    assert_success
    assert_line "radarr=true:$radarr_base"
    assert_line "sonarr=true:$sonarr_base"
}

@test "O17: -h prints the usage, exits 0 and touches nothing" {
    rm -rf "$REPORTS"

    run --separate-stderr "$BASH_UNDER_TEST" "$ALA" -h
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "interactive orchestrator"
    [ ! -d "$REPORTS" ]
    refute_log_contains "argv:"

    run --separate-stderr "$BASH_UNDER_TEST" "$ALA" --help
    assert_success
    assert_output --partial "Usage:"
}

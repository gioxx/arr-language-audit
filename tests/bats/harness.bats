#!/usr/bin/env bats
#
# Smoke tests for the test harness itself: the fake Radarr/Sonarr server and
# the PATH shims. If these fail, no other bats test can be trusted.

load helpers/common
load helpers/fake_arr
load helpers/shims

teardown() {
    stop_fake_arr
}

# Local to this file: GET the fake command and print just its status.
# poll_command_status <app-url> <api-key>
poll_command_status() {
    curl -sf -H "X-Api-Key: $2" "$1/api/v3/command/42" | "${REAL_JQ:-jq}" -r '.status'
}

@test "fake server serves the system/status fixture and logs the request" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"

    run curl -sf -H "X-Api-Key: radarr-key" "$RADARR_URL/api/v3/system/status"
    assert_success
    assert_output --partial '"version": "4.0.0.1234"'
    assert_output --partial '"instanceName": "Radarr"'

    run arr_request_count "/radarr/api/v3/system/status"
    assert_success
    assert_output "1"

    run arr_requests 'select(.path == "/radarr/api/v3/system/status") | .key_ok'
    assert_success
    assert_output "true"
}

@test "fake server answers 401 when the api key is wrong" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"

    run curl -s -o /dev/null -w '%{http_code}' \
        -H "X-Api-Key: wrong-key" "$RADARR_URL/api/v3/system/status"
    assert_success
    assert_output "401"

    run arr_requests 'select(.path == "/radarr/api/v3/system/status") | .key_ok'
    assert_success
    assert_output "false"
}

@test "fake server /ping needs no api key" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"

    run curl -sf "$RADARR_URL/ping"
    assert_success
    assert_output --partial '"status": "OK"'
}

@test "control file fail_count makes the first request fail and the next succeed" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    arr_control '{"fail_count": {"/radarr/api/v3/movie": 1}}'

    run curl -s -o /dev/null -w '%{http_code}' \
        -H "X-Api-Key: radarr-key" "$RADARR_URL/api/v3/movie"
    assert_success
    assert_output "500"

    run curl -s -o /dev/null -w '%{http_code}' \
        -H "X-Api-Key: radarr-key" "$RADARR_URL/api/v3/movie"
    assert_success
    assert_output "200"
}

@test "ffmpeg shim writes a RIFF/WAVE file tagged with its input path" {
    make_bin
    install_shim ffmpeg

    run ffmpeg -y -ss 0 -i /media/x.mkv -t 60 -vn "$BATS_TEST_TMPDIR/out.wav"
    assert_success
    [ -f "$BATS_TEST_TMPDIR/out.wav" ]

    run head -c 4 "$BATS_TEST_TMPDIR/out.wav"
    assert_output "RIFF"

    run grep -c 'FAKEWAV:/media/x.mkv' "$BATS_TEST_TMPDIR/out.wav"
    assert_success
    assert_output "1"
}

@test "python3 shim reports the scripted interpreter version" {
    make_bin
    install_shim python3

    export FAKE_PY_VERSION=3.9.6

    run python3 --version
    assert_success
    assert_output "Python 3.9.6"

    run python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])'
    assert_success
    assert_output "3.9"
}

@test "df shim reports the scripted available megabytes" {
    make_bin
    install_shim df

    export FAKE_DF_AVAIL_MB=42

    run bash -c "df -Pm /x | tail -1 | awk '{print \$4}'"
    assert_success
    assert_output "42"
}

@test "ffprobe shim reports the scripted duration and a default otherwise" {
    make_bin
    install_shim ffprobe

    export FAKE_DURATIONS='{"/media/x.mkv": 42}'

    run ffprobe -v error -show_entries format=duration -of json /media/x.mkv
    assert_success
    assert_output '{"format":{"duration":"42"}}'

    run ffprobe -v error -show_entries format=duration -of json /media/other.mkv
    assert_success
    assert_output '{"format":{"duration":"600"}}'
}

@test "whiptail shim returns the scripted answer and exit status" {
    make_bin
    install_shim whiptail

    export FAKE_WT_OUT="chosen" FAKE_WT_RC=1 FAKE_WT_LOG="$BATS_TEST_TMPDIR/wt.log"

    run whiptail --menu Pick 10 40 2 a A b B
    assert_failure 1
    assert_output "chosen"

    run cat "$FAKE_WT_LOG"
    assert_output --partial "--menu Pick"
}

@test "install_recorder stands in for a script and records argv and environment" {
    make_bin
    install_recorder "$BATS_TEST_TMPDIR/fake-scan.sh"

    export RECORDER_LOG="$BATS_TEST_TMPDIR/recorder.log" RECORDER_RC=3
    export RADARR_URL="http://127.0.0.1:1/radarr"

    run "$BATS_TEST_TMPDIR/fake-scan.sh" --refresh
    assert_failure 3

    run cat "$RECORDER_LOG"
    assert_output --partial "argv: $BATS_TEST_TMPDIR/fake-scan.sh --refresh"
    assert_output --partial "env: RADARR_URL=http://127.0.0.1:1/radarr"
}

@test "command_status walks the scripted sequence and repeats the last value" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    arr_control '{"command_status": ["queued", "completed"]}'

    run curl -sf -X POST -H "X-Api-Key: radarr-key" "$RADARR_URL/api/v3/command"
    assert_success
    assert_output --partial '"status": "queued"'

    run poll_command_status "$RADARR_URL" radarr-key
    assert_output "queued"

    run poll_command_status "$RADARR_URL" radarr-key
    assert_output "completed"

    run poll_command_status "$RADARR_URL" radarr-key
    assert_output "completed"
}

@test "each app walks command_status independently" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    arr_control '{"command_status": ["queued", "completed"]}'

    run poll_command_status "$RADARR_URL" radarr-key
    assert_output "queued"

    # Sonarr has not polled yet, so it must still see the first element.
    run poll_command_status "$SONARR_URL" sonarr-key
    assert_output "queued"

    run poll_command_status "$RADARR_URL" radarr-key
    assert_output "completed"

    run poll_command_status "$SONARR_URL" sonarr-key
    assert_output "completed"
}

@test "control crlf makes every response body end with CRLF" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    arr_control '{"crlf": true}'

    curl -sf -H "X-Api-Key: radarr-key" \
        -o "$BATS_TEST_TMPDIR/body.json" "$RADARR_URL/api/v3/system/status"

    run bash -c "tail -c 2 '$BATS_TEST_TMPDIR/body.json' | od -An -t x1 | tr -d ' \n'"
    assert_output "0d0a"
}

@test "write_csv writes CRLF line endings like csv.DictWriter" {
    write_csv "$BATS_TEST_TMPDIR/rows.csv" "App,Title" "Radarr,Il Cammino Lungo"

    run grep -c $'\r$' "$BATS_TEST_TMPDIR/rows.csv"
    assert_success
    assert_output "2"

    # Exactly two CR bytes: one per line, none anywhere else.
    run bash -c "tr -dc '\r' < '$BATS_TEST_TMPDIR/rows.csv' | wc -c | tr -d ' '"
    assert_output "2"
}

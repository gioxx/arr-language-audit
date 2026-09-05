#!/usr/bin/env bash
#
# Drive the fake Radarr/Sonarr server (tests/fakes/fake_arr_server.py) from
# bats. One server process serves both apps under /radarr and /sonarr.
#
# The fixture directory is served read-only. A test that needs a variant
# (movies_all_italian.json, series_changed_size.json, ...) copies the fixture
# tree into $BATS_TEST_TMPDIR first and overwrites the file the route maps to.

# start_fake_arr <fixture-dir>
#
# Exports FAKE_ARR_PORT, RADARR_URL, SONARR_URL, RADARR_API_KEY,
# SONARR_API_KEY, FAKE_ARR_LOG and FAKE_ARR_CONTROL.
start_fake_arr() {
    local fixture_dir="$1"

    if [[ ! -d "$fixture_dir" ]]; then
        printf 'start_fake_arr: no such fixture directory: %s\n' "$fixture_dir" >&2
        return 1
    fi

    local state_dir="$BATS_TEST_TMPDIR/fake-arr"
    mkdir -p "$state_dir"

    FAKE_ARR_PORTFILE="$state_dir/port"
    FAKE_ARR_LOG="$state_dir/requests.jsonl"
    FAKE_ARR_CONTROL="$state_dir/control.json"
    rm -f "$FAKE_ARR_PORTFILE"
    : > "$FAKE_ARR_LOG"
    printf '{}\n' > "$FAKE_ARR_CONTROL"

    FAKE_RADARR_KEY="${FAKE_RADARR_KEY:-radarr-key}"
    FAKE_SONARR_KEY="${FAKE_SONARR_KEY:-sonarr-key}"
    export FAKE_ARR_PORTFILE FAKE_ARR_LOG FAKE_ARR_CONTROL
    export FAKE_RADARR_KEY FAKE_SONARR_KEY

    "${REAL_PYTHON3:-python3}" "$ROOT/tests/fakes/fake_arr_server.py" "$fixture_dir" &
    FAKE_ARR_PID=$!

    if ! wait_for_file "$FAKE_ARR_PORTFILE" 5; then
        printf 'start_fake_arr: server did not report a port\n' >&2
        stop_fake_arr
        return 1
    fi

    FAKE_ARR_PORT="$(cat "$FAKE_ARR_PORTFILE")"
    RADARR_URL="http://127.0.0.1:$FAKE_ARR_PORT/radarr"
    SONARR_URL="http://127.0.0.1:$FAKE_ARR_PORT/sonarr"
    RADARR_API_KEY="$FAKE_RADARR_KEY"
    SONARR_API_KEY="$FAKE_SONARR_KEY"
    export FAKE_ARR_PORT RADARR_URL SONARR_URL RADARR_API_KEY SONARR_API_KEY
}

# stop_fake_arr -- safe to call from teardown even if the server never started.
stop_fake_arr() {
    if [[ -n "${FAKE_ARR_PID:-}" ]]; then
        kill "$FAKE_ARR_PID" 2>/dev/null || true
        wait "$FAKE_ARR_PID" 2>/dev/null || true
        FAKE_ARR_PID=""
    fi
}

# arr_requests <jq-filter> -- run the filter over the JSONL request log.
# Each entry is {"method","path","query","key_ok","body"}.
arr_requests() {
    "${REAL_JQ:-jq}" -c "$1" "$FAKE_ARR_LOG"
}

# arr_request_count <path-substring> -- how many logged requests match.
arr_request_count() {
    "${REAL_JQ:-jq}" -s --arg needle "$1" \
        '[.[] | select(.path | contains($needle))] | length' "$FAKE_ARR_LOG"
}

# arr_control <json> -- overwrite the control file the server re-reads on every
# request: {"fail_count": {"<path>": N}, "command_status": [...], "crlf": bool}.
arr_control() {
    printf '%s\n' "$1" > "$FAKE_ARR_CONTROL"
}

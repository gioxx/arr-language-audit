#!/usr/bin/env bats
#
# scan/find-missing-italian-audio.sh -- phase 1.
#
# Every test drives the real script against the fake Radarr/Sonarr server and
# asserts on the bytes it writes: the CSV row, the stdout hit line, the cache
# and the exit code. The script runs through "$BASH_UNDER_TEST" (bash 3.2 on
# macOS), so a bash 4 builtin fails here rather than on a user's machine.
#
# S1-S8 are the row format, and S1/S3 in particular are the regression that
# started this: jq's @tsv output was split with IFS=$'\t', which collapses
# consecutive tabs, so a file with an empty audioLanguages had its path
# shifted into the language column -- the exact file the tool exists to find.

bats_require_minimum_version 1.5.0

load helpers/common
load helpers/fake_arr
load helpers/shims

SCAN="$ROOT/scan/find-missing-italian-audio.sh"

setup() {
    make_bin

    OUT="$BATS_TEST_TMPDIR/report.csv"
    CACHE="$BATS_TEST_TMPDIR/report.cache.json"

    # No sleeping between retries, and an explicit configuration so a .env in
    # the developer's checkout cannot change what these tests exercise
    # (load_dotenv leaves a set, non-empty variable alone).
    export ARR_RETRY_DELAY=0
    export SKIP_RADARR=false SKIP_SONARR=false
    export REFRESH=false FORCE_RESCAN=false RESCAN_TIMEOUT=300
}

teardown() {
    stop_fake_arr
}

# --------------------------------------------------------------------------
# local helpers
# --------------------------------------------------------------------------

# fixture_copy -- a writable copy of the fixture tree, so a test can swap the
# file a route maps to. Echoes the directory.
fixture_copy() {
    local dir="$BATS_TEST_TMPDIR/fixtures"
    rm -rf "$dir"
    mkdir -p "$dir"
    cp -R "$BATS_TESTS_DIR/fixtures/radarr" "$dir/radarr"
    cp -R "$BATS_TESTS_DIR/fixtures/sonarr" "$dir/sonarr"
    printf '%s\n' "$dir"
}

# run_scan [arg...] -- the script under test, stdout and stderr kept apart.
run_scan() {
    run --separate-stderr "$BASH_UNDER_TEST" "$SCAN" "$OUT" "$@"
}

# episode_requests <series-id> -- how many /episode?seriesId=<id> requests the
# fake server logged. arr_request_count only looks at the path, and the series
# id lives in the query string.
episode_requests() {
    "${REAL_JQ:-jq}" -s --arg id "$1" \
        '[.[] | select(.path | endswith("/api/v3/episode"))
              | select(.query | test("(^|&)seriesId=" + $id + "(&|$)"))] | length' \
        "$FAKE_ARR_LOG"
}

# episode_request_total -- every /episode request, whichever series it asked for.
episode_request_total() {
    "${REAL_JQ:-jq}" -s \
        '[.[] | select(.path | endswith("/api/v3/episode"))] | length' \
        "$FAKE_ARR_LOG"
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

assert_csv_has() {
    if ! grep -qxF -- "$1" "$OUT"; then
        printf 'expected the report to contain the line:\n  %s\nreport was:\n' "$1" >&2
        cat "$OUT" >&2
        return 1
    fi
}

# --------------------------------------------------------------------------
# S1-S8: the CSV row format
# --------------------------------------------------------------------------

@test "S1: an empty audioLanguages keeps the path in the path column" {
    local dir
    dir="$(fixture_copy)"
    cp "$dir/radarr/movies_edge_cases.json" "$dir/radarr/movies.json"
    start_fake_arr "$dir"
    export SKIP_SONARR=true

    run_scan
    assert_success

    # The C1 regression: with @tsv + IFS=$'\t' this row was never written at
    # all, because the path landed in the language column and "/media/Italian
    # Movies/..." matched the Italian test.
    assert_csv_has 'Radarr,"Null Tag",2015,,"","/media/Italian Movies/null-tag.mkv"'
}

@test "S2: a missing year leaves the year column empty" {
    local dir
    dir="$(fixture_copy)"
    cp "$dir/radarr/movies_edge_cases.json" "$dir/radarr/movies.json"
    start_fake_arr "$dir"
    export SKIP_SONARR=true

    run_scan
    assert_success

    assert_csv_has 'Radarr,"No Year At All",,,"English","/media/movies/No Year At All/No Year At All.mkv"'
}

@test "S3: an episode with an empty title and an empty tag keeps its path" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    export SKIP_RADARR=true

    run_scan
    assert_success

    assert_csv_has 'Sonarr,"Le Colline Silenziose",,"S01E03 - ","","/media/tv/Le Colline Silenziose/Season 01/S01E03.mkv"'
}

@test "S4: every Italian spelling is skipped and nothing else is" {
    local dir
    dir="$(fixture_copy)"
    cp "$dir/radarr/movies_variants.json" "$dir/radarr/movies.json"
    start_fake_arr "$dir"
    export SKIP_SONARR=true

    run_scan
    assert_success

    # LC_ALL=C: a UTF-8 collation would fold case and put "Tag empty" first.
    run bash -c "tail -n +2 '$OUT' | LC_ALL=C sort"
    assert_output "$(cat <<'EOF'
Radarr,"Tag English",2006,,"English","/media/movies/tag-english.mkv"
Radarr,"Tag Japanese slash English",2007,,"Japanese / English","/media/movies/tag-japanese-english.mkv"
Radarr,"Tag Occitan",2009,,"Occitan","/media/movies/tag-occitan.mkv"
Radarr,"Tag empty",2008,,"","/media/movies/tag-empty.mkv"
EOF
)"
}

@test "S5: double quotes are doubled and the row parses as RFC 4180 CSV" {
    local dir
    dir="$(fixture_copy)"
    cp "$dir/radarr/movies_edge_cases.json" "$dir/radarr/movies.json"
    start_fake_arr "$dir"
    export SKIP_SONARR=true

    run_scan
    assert_success

    assert_csv_has 'Radarr,"Hello, ""World""",2013,,"English","/m/a, ""b"".mkv"'

    # A real CSV reader has to get the title and the path back verbatim.
    run "$REAL_PYTHON3" -c '
import csv, sys
with open(sys.argv[1], newline="") as handle:
    rows = [r for r in csv.DictReader(handle) if r["Title"].startswith("Hello")]
print(rows[0]["Title"])
print(rows[0]["Path"])
' "$OUT"
    assert_success
    assert_line --index 0 'Hello, "World"'
    assert_line --index 1 '/m/a, "b".mkv'
}

@test "S6: a UNC path keeps its single backslashes" {
    local dir
    dir="$(fixture_copy)"
    cp "$dir/radarr/movies_edge_cases.json" "$dir/radarr/movies.json"
    start_fake_arr "$dir"
    export SKIP_SONARR=true

    run_scan
    assert_success

    assert_csv_has 'Radarr,"Windows Share",2012,,"English","\\nas\share\a.mkv"'
}

@test "S7: a title with a tab and a newline stays one row" {
    local dir
    dir="$(fixture_copy)"
    cp "$dir/radarr/movies_edge_cases.json" "$dir/radarr/movies.json"
    start_fake_arr "$dir"
    export SKIP_SONARR=true

    run_scan
    assert_success

    assert_csv_has 'Radarr,"A B C",2011,,"English","/media/movies/Tabbed Title/tabbed.mkv"'

    # Seven flagged movies, seven rows: the embedded newline did not split one.
    run bash -c "tail -n +2 '$OUT' | wc -l | tr -d ' '"
    assert_output "7"
}

@test "S8: a movie without a file is absent and one without mediaInfo is flagged" {
    local dir
    dir="$(fixture_copy)"
    cp "$dir/radarr/movies_edge_cases.json" "$dir/radarr/movies.json"
    start_fake_arr "$dir"
    export SKIP_SONARR=true

    run_scan
    assert_success

    run grep -c 'Never Downloaded' "$OUT"
    assert_failure

    assert_csv_has 'Radarr,"No Media Info",2014,,"","/media/movies/No Media Info/No Media Info.mkv"'
}

# --------------------------------------------------------------------------
# S12-S13: skipping and the empty report
# --------------------------------------------------------------------------

@test "S12: SKIP_RADARR makes no Radarr request at all" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    export SKIP_RADARR=true

    run_scan
    assert_success
    # Saved before the next `run` overwrites $output with the request count.
    local hit_lines="$output"

    run arr_request_count "/radarr/"
    assert_output "0"

    [ -n "$hit_lines" ]
    if [[ "$hit_lines" == *"[Radarr]"* ]]; then
        printf 'stdout carried a Radarr hit line:\n%s\n' "$hit_lines" >&2
        return 1
    fi
}

@test "S12 twin: SKIP_SONARR makes no Sonarr request at all" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    export SKIP_SONARR=true

    run_scan
    assert_success
    local hit_lines="$output"

    run arr_request_count "/sonarr/"
    assert_output "0"

    [ ! -f "$CACHE" ]

    [ -n "$hit_lines" ]
    if [[ "$hit_lines" == *"[Sonarr]"* ]]; then
        printf 'stdout carried a Sonarr hit line:\n%s\n' "$hit_lines" >&2
        return 1
    fi
}

@test "S13: zero findings still leaves a header-only report" {
    local dir
    dir="$(fixture_copy)"
    cp "$dir/radarr/movies_all_italian.json" "$dir/radarr/movies.json"
    printf '[]\n' > "$dir/sonarr/series.json"
    start_fake_arr "$dir"

    run_scan
    assert_success
    assert_output ""
    assert_stderr_contains "No files missing Italian audio were found."

    [ -f "$OUT" ]
    run cat "$OUT"
    assert_output "App,Title,Year,Episode,AudioLanguages,Path"
}

# --------------------------------------------------------------------------
# S14-S18: the Sonarr per-series cache
# --------------------------------------------------------------------------

@test "S14: the cache is v2 and a second run reuses it" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"

    run_scan
    assert_success

    run "$REAL_JQ" -r '.__meta.version' "$CACHE"
    assert_output "2"
    run "$REAL_JQ" -r '."1".sig' "$CACHE"
    assert_output "10:123456"
    run "$REAL_JQ" -r '.__meta.regex' "$CACHE"
    assert_output '(^|[^a-z])(italian|ita|it-it)([^a-z]|$)'

    cp "$OUT" "$BATS_TEST_TMPDIR/first.csv"
    : > "$FAKE_ARR_LOG"

    run_scan
    assert_success
    assert_stderr_contains "[cache] Le Colline Silenziose unchanged (10:123456); reused 3 flagged file(s)."

    run episode_requests 1
    assert_output "0"

    run diff "$BATS_TEST_TMPDIR/first.csv" "$OUT"
    assert_success
}

@test "S15: only the series whose signature moved is re-fetched" {
    local dir
    dir="$(fixture_copy)"
    start_fake_arr "$dir"

    run_scan
    assert_success

    cp "$dir/sonarr/series_changed_size.json" "$dir/sonarr/series.json"
    : > "$FAKE_ARR_LOG"

    run_scan
    assert_success

    run episode_requests 1
    assert_output "1"
    run episode_requests 2
    assert_output "0"

    run "$REAL_JQ" -r '."1".sig' "$CACHE"
    assert_output "10:999999"
}

@test "S15 twin: a changed episode file count also re-fetches the series" {
    local dir
    dir="$(fixture_copy)"
    start_fake_arr "$dir"

    run_scan
    assert_success

    cp "$dir/sonarr/series_changed_count.json" "$dir/sonarr/series.json"
    : > "$FAKE_ARR_LOG"

    run_scan
    assert_success

    run episode_requests 1
    assert_output "1"
    run episode_requests 2
    assert_output "0"

    run "$REAL_JQ" -r '."1".sig' "$CACHE"
    assert_output "11:123456"
}

@test "S16: --refresh and REFRESH=true both ignore the cache" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"

    run_scan
    assert_success

    : > "$FAKE_ARR_LOG"
    run_scan --refresh
    assert_success
    run episode_requests 1
    assert_output "1"
    run episode_requests 2
    assert_output "1"

    : > "$FAKE_ARR_LOG"
    export REFRESH=true
    run_scan
    assert_success
    run episode_requests 1
    assert_output "1"
    run episode_requests 2
    assert_output "1"
}

@test "S17: a series that left the library leaves the cache too" {
    local dir
    dir="$(fixture_copy)"
    start_fake_arr "$dir"

    run_scan
    assert_success
    run "$REAL_JQ" -r '."2".sig' "$CACHE"
    assert_output "1:654321"

    "$REAL_JQ" '[.[] | select(.id == 1)]' \
        "$BATS_TESTS_DIR/fixtures/sonarr/series.json" > "$dir/sonarr/series.json"

    run_scan
    assert_success

    run "$REAL_JQ" -r 'has("2")' "$CACHE"
    assert_output "false"
    run "$REAL_JQ" -r 'has("1")' "$CACHE"
    assert_output "true"
}

@test "S18: a malformed cache is reported and rebuilt" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    printf 'not json at all\n' > "$CACHE"

    run_scan
    assert_success
    assert_stderr_contains "is unreadable, ignoring it."

    run episode_requests 1
    assert_output "1"

    run "$REAL_JQ" -r '.__meta.version' "$CACHE"
    assert_output "2"
}

# --------------------------------------------------------------------------
# S19-S21: failure paths and the episodefile fallback
# --------------------------------------------------------------------------

@test "S19: an unreachable Sonarr exits 2 and leaves the cache untouched" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"

    run_scan
    assert_success
    cp "$CACHE" "$BATS_TEST_TMPDIR/cache-before.json"

    arr_control '{"fail_count": {"/sonarr/api/v3/series": 3}}'

    run_scan
    assert_failure 2
    assert_stderr_contains "Sonarr scan failed"
    assert_stderr_contains "scan incomplete: Sonarr unreachable"
    refute_stderr_contains "No files missing Italian audio were found."

    # Radarr was still scanned and its findings are in the report.
    assert_csv_has 'Radarr,"Salt and Iron",2018,,"English","/media/movies/Salt and Iron (2018)/Salt and Iron (2018).mkv"'

    run diff "$BATS_TEST_TMPDIR/cache-before.json" "$CACHE"
    assert_success
}

@test "S20: a failed episode fetch reuses a cached series and skips a new one" {
    local dir
    dir="$(fixture_copy)"
    start_fake_arr "$dir"

    run_scan
    assert_success

    # Both known series move, and a third one appears that the cache has never
    # seen. Then every episode request fails: 3 series x 3 attempts.
    cat > "$dir/sonarr/series.json" <<'EOF'
[
  {"id": 1, "title": "Le Colline Silenziose", "statistics": {"episodeFileCount": 10, "sizeOnDisk": 999999}},
  {"id": 2, "title": "Northbound", "statistics": {"episodeFileCount": 2, "sizeOnDisk": 654321}},
  {"id": 3, "title": "Brand New", "statistics": {"episodeFileCount": 1, "sizeOnDisk": 111}}
]
EOF
    arr_control '{"fail_count": {"/sonarr/api/v3/episode": 9}}'

    run_scan
    assert_success

    assert_stderr_contains "episode fetch failed for 'Le Colline Silenziose'; keeping its previous cache entry."
    assert_stderr_contains "episode fetch failed for 'Brand New'; skipping it this run."

    # The cached series is still reported from its previous rows...
    assert_csv_has 'Sonarr,"Le Colline Silenziose",,"S01E02 - Cold Front","English","/media/tv/Le Colline Silenziose/Season 01/S01E02.mkv"'
    # ...the never-seen one contributes nothing and is not in the cache.
    run "$REAL_JQ" -r 'has("3")' "$CACHE"
    assert_output "false"
    run "$REAL_JQ" -r '."1".sig' "$CACHE"
    assert_output "10:123456"
}

@test "S21: hasFile with no embedded file falls back to /episodefile" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    export SKIP_RADARR=true

    run_scan
    assert_success

    run arr_request_count "/sonarr/api/v3/episodefile/77"
    assert_output "1"

    assert_csv_has 'Sonarr,"Le Colline Silenziose",,"S01E04 - Deferred File","German","/tv/s/S01E04.mkv"'
}

# --------------------------------------------------------------------------
# S30: the stdout contract
# --------------------------------------------------------------------------

@test "S30: stdout carries hit lines and nothing else" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"

    run_scan
    assert_success

    [ -n "$output" ]
    local line
    while IFS= read -r line; do
        if [[ ! "$line" =~ ^\[(Radarr|Sonarr)\]\  ]]; then
            printf 'unexpected stdout line: %s\n' "$line" >&2
            return 1
        fi
    done <<< "$output"
}

# --------------------------------------------------------------------------
# S34-S35: process count and cache schema changes
# --------------------------------------------------------------------------

# make_big_sonarr <fixture-dir> -- 30 single-episode series, all flagged.
make_big_sonarr() {
    "$REAL_PYTHON3" - "$1" <<'PY'
import json, pathlib, sys

sonarr = pathlib.Path(sys.argv[1]) / "sonarr"
series = []
for n in range(1, 31):
    series.append({
        "id": n,
        "title": "Series %02d" % n,
        "statistics": {"episodeFileCount": 1, "sizeOnDisk": 1000 + n},
    })
    (sonarr / ("episodes_%d.json" % n)).write_text(json.dumps([{
        "id": 100 + n,
        "seriesId": n,
        "seasonNumber": 1,
        "episodeNumber": 1,
        "title": "Ep %02d" % n,
        "hasFile": True,
        "episodeFileId": 200 + n,
        "episodeFile": {
            "id": 200 + n,
            "path": "/tv/s%02d/S01E01.mkv" % n,
            "mediaInfo": {"audioLanguages": "English"},
        },
    }]))
(sonarr / "series.json").write_text(json.dumps(series))
PY
}

@test "S34: jq is invoked a bounded number of times, not once per series" {
    local dir
    dir="$(fixture_copy)"
    make_big_sonarr "$dir"
    start_fake_arr "$dir"
    install_shim jq

    # Cold: nothing cached. Two jq per series (format, cache entry) plus the
    # fixed overhead.
    export FAKE_JQ_LOG="$BATS_TEST_TMPDIR/jq-cold.log"
    : > "$FAKE_JQ_LOG"
    run_scan
    assert_success

    run bash -c "wc -l < '$BATS_TEST_TMPDIR/jq-cold.log' | tr -d ' '"
    local cold="$output"
    [ "$cold" -le 72 ] || {
        printf 'cold run spawned %s jq processes, budget is 2*30 + 12\n' "$cold" >&2
        return 1
    }

    # Warm: every series a cache hit, so the count no longer depends on 30.
    export FAKE_JQ_LOG="$BATS_TEST_TMPDIR/jq-warm.log"
    : > "$FAKE_JQ_LOG"
    : > "$FAKE_ARR_LOG"
    run_scan
    assert_success

    run episode_request_total
    assert_output "0"

    run bash -c "wc -l < '$BATS_TEST_TMPDIR/jq-warm.log' | tr -d ' '"
    local warm="$output"
    [ "$warm" -le 12 ] || {
        printf 'warm run spawned %s jq processes, budget is 12\n' "$warm" >&2
        return 1
    }
}

@test "S35: a cache without __meta is discarded and rebuilt" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"

    # Exactly what the previous version wrote: series ids at the top level,
    # no schema marker anywhere.
    cat > "$CACHE" <<'EOF'
{
  "1": { "sig": "10:123456", "rows": [] },
  "2": { "sig": "1:654321", "rows": [] }
}
EOF

    run_scan
    assert_success
    assert_stderr_contains "cache format changed"

    # A full re-fetch, not a hit on the stale signatures.
    run episode_requests 1
    assert_output "1"
    run episode_requests 2
    assert_output "1"
    refute_stderr_contains "[cache]"

    run "$REAL_JQ" -r '.__meta.version' "$CACHE"
    assert_output "2"

    # And the rows the old cache claimed were empty are back in the report.
    assert_csv_has 'Sonarr,"Northbound",,"S01E01 - Due North","English","/media/tv/Northbound/Season 01/S01E01.mkv"'
}

@test "S35 twin: a cache built with a different regex is discarded" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"

    cat > "$CACHE" <<'EOF'
{
  "1": { "sig": "10:123456", "rows": [] },
  "__meta": { "version": 2, "regex": "italian|ita|it-it" }
}
EOF

    run_scan
    assert_success
    assert_stderr_contains "cache format changed"

    run episode_requests 1
    assert_output "1"
}

# --------------------------------------------------------------------------
# S38: the row format did not move
# --------------------------------------------------------------------------

@test "S38: the rewrite keeps the row format" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"

    run_scan
    assert_success
    local hit_lines="$output"

    # Byte for byte what the previous implementation produced, except the
    # S01E03 row: that one used to read
    #   Sonarr,"...",,"S01E03 - /media/.../S01E03.mkv","",""
    # because an empty audioLanguages collapsed two tabs together.
    run cat "$OUT"
    assert_output "$(cat <<'EOF'
App,Title,Year,Episode,AudioLanguages,Path
Radarr,"Salt and Iron",2018,,"English","/media/movies/Salt and Iron (2018)/Salt and Iron (2018).mkv"
Radarr,"Hoshi no Michi",2016,,"Japanese / English","/media/movies/Hoshi no Michi (2016)/Hoshi no Michi (2016).mkv"
Sonarr,"Le Colline Silenziose",,"S01E02 - Cold Front","English","/media/tv/Le Colline Silenziose/Season 01/S01E02.mkv"
Sonarr,"Le Colline Silenziose",,"S01E03 - ","","/media/tv/Le Colline Silenziose/Season 01/S01E03.mkv"
Sonarr,"Le Colline Silenziose",,"S01E04 - Deferred File","German","/tv/s/S01E04.mkv"
Sonarr,"Northbound",,"S01E01 - Due North","English","/media/tv/Northbound/Season 01/S01E01.mkv"
EOF
)"

    # And the stdout hit lines with it.
    run printf '%s\n' "$hit_lines"
    assert_output "$(cat <<'EOF'
[Radarr] Salt and Iron (2018) -> audio: English
[Radarr] Hoshi no Michi (2016) -> audio: Japanese / English
[Sonarr] Le Colline Silenziose - S01E02 - Cold Front -> audio: English
[Sonarr] Le Colline Silenziose - S01E03 -  -> audio: <none>
[Sonarr] Le Colline Silenziose - S01E04 - Deferred File -> audio: German
[Sonarr] Northbound - S01E01 - Due North -> audio: English
EOF
)"
}

# --------------------------------------------------------------------------
# S39-S40: errexit and signals
# --------------------------------------------------------------------------

@test "S39: a report that cannot be written fails the run" {
    if [[ "$(id -u)" -eq 0 ]]; then
        skip "running as root: an unwritable directory is still writable"
    fi

    start_fake_arr "$BATS_TESTS_DIR/fixtures"

    local locked="$BATS_TEST_TMPDIR/locked"
    mkdir -p "$locked"
    chmod 500 "$locked"
    OUT="$locked/report.csv"

    run_scan
    chmod 700 "$locked"

    # errexit has to be live for the whole run: with `main "$@" || exit $?` the
    # failed redirection was swallowed and the script still claimed success.
    [ "$status" -ne 0 ]
    refute_stderr_contains "Results exported to"
    refute_stderr_contains "No files missing Italian audio were found."
    [ ! -f "$OUT" ]
}

@test "S40: a real SIGINT stops a running scan and removes its temp directory" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    # Every response is held for five seconds, so the signal lands while the
    # scan is still blocked inside curl -- the state Ctrl-C actually finds.
    arr_control '{"delay": 5}'

    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$TMPDIR"

    # Measured on this machine, and the reason this test needs both of the
    # unusual things it does:
    #
    #   * without `set -m`, a non-interactive shell starts an asynchronous
    #     command with SIGINT set to SIG_IGN, and a signal ignored at entry
    #     cannot be trapped: the scan ran to completion and `wait` returned 0.
    #     `set -m` gives the job its own process group and a live disposition.
    #   * `kill -INT "$pid"` alone reaches bash but not curl, and bash defers a
    #     trap until the foreground child returns: 9s against a 10s sleep.
    #     Signalling the whole group is what a terminal's Ctrl-C does, and it
    #     returned in 0s.
    set -m
    "$BASH_UNDER_TEST" "$SCAN" "$OUT" \
        > "$BATS_TEST_TMPDIR/s40.out" 2> "$BATS_TEST_TMPDIR/s40.err" &
    local pid=$!
    set +m

    # Wait until the server has logged the first request: from here the scan is
    # inside curl and the server is holding the response.
    local waited=0
    while [[ "$(arr_request_count "/radarr/api/v3/movie")" == "0" ]]; do
        if [[ "$waited" -ge 100 ]]; then
            kill -9 "$pid" 2>/dev/null || true
            printf 'the scan never reached the fake server\n' >&2
            return 1
        fi
        sleep 0.05
        waited=$((waited + 1))
    done

    kill -INT -- "-$pid"
    local rc=0
    wait "$pid" || rc=$?

    [ "$rc" -eq 130 ] || {
        printf 'expected exit 130 from the interrupted scan, got %s\nstderr:\n' "$rc" >&2
        cat "$BATS_TEST_TMPDIR/s40.err" >&2
        return 1
    }

    # Nothing left behind, and no success claimed.
    run bash -c "ls -d '$TMPDIR'/ala-scan.* 2>/dev/null | wc -l | tr -d ' '"
    assert_output "0"
    run grep -c "Results exported to" "$BATS_TEST_TMPDIR/s40.err"
    assert_failure

    # The report holds its header and no half-written row: the scan was
    # interrupted before it could flag anything.
    run cat "$OUT"
    assert_output "App,Title,Year,Episode,AudioLanguages,Path"
}

@test "S40 twin: on_signal cleans up and exits 130 without falling through" {
    # The handler's own contract, without a race: sourcing the script defines
    # its functions without running main (the BASH_SOURCE guard).
    run "$BASH_UNDER_TEST" -c '
. "$1"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ala-signal.XXXXXX")"
printf "%s\n" "$TMP_DIR"
on_signal INT
printf "kept running\n"
' bash "$SCAN"

    assert_failure 130
    refute_output --partial "kept running"

    local leftover
    leftover="$(printf '%s\n' "$output" | head -1)"
    [ -n "$leftover" ]
    [ ! -d "$leftover" ]
}

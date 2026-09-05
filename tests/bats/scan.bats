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

    # No sleeping between retries, and ALA_DOTENV_FILE pointed at a file that
    # does not exist, so a .env in the developer's checkout is never read.
    # A test that wants a .env points ALA_DOTENV_FILE at its own (S25, S26,
    # S33, S37); S27 unsets it to exercise the default search order.
    export ARR_RETRY_DELAY=0
    export ALA_DOTENV_FILE="$BATS_TEST_TMPDIR/absent.env"
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

# file_mode <path> -- the permission bits as three octal digits, on BSD and on
# GNU stat alike.
file_mode() {
    # GNU stat first: on BSD "-c" is an illegal option and fails, falling
    # through to the BSD spelling. The other order is wrong: GNU accepts
    # "stat -f" (file-system status) and prints six lines instead of a mode.
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

# tmp_leftovers -- how many "<report>.tmp.<pid>" files survive next to $OUT. A
# run that failed or was interrupted must leave none.
tmp_leftovers() {
    local dir
    dir="$(dirname -- "$OUT")"
    ls -1 "$dir" 2>/dev/null | grep -c '\.tmp\.[^.]*$' || true
}

# command_posts <app> -- the bodies of every POST /<app>/api/v3/command, joined
# with "|" so a test can assert on all of them at once.
command_posts() {
    "${REAL_JQ:-jq}" -s -r --arg app "$1" \
        '[.[] | select(.method == "POST")
              | select(.path == "/" + $app + "/api/v3/command") | .body]
         | join("|")' "$FAKE_ARR_LOG"
}

# fake_env <path> -- a .env built from the committed .env.example with the fake
# server's URLs and keys substituted in. Proves .env.example itself parses.
fake_env() {
    sed -e "s|^RADARR_URL=.*|RADARR_URL=$RADARR_URL|" \
        -e "s|^RADARR_API_KEY=.*|RADARR_API_KEY=$RADARR_API_KEY|" \
        -e "s|^SONARR_URL=.*|SONARR_URL=$SONARR_URL|" \
        -e "s|^SONARR_API_KEY=.*|SONARR_API_KEY=$SONARR_API_KEY|" \
        "$ROOT/.env.example" > "$1"
}

# forget_arr_env -- drop the connection settings start_fake_arr exported, so a
# .env under test is the only place they can come from.
forget_arr_env() {
    unset RADARR_URL RADARR_API_KEY SONARR_URL SONARR_API_KEY
    unset SKIP_RADARR SKIP_SONARR REFRESH FORCE_RESCAN RESCAN_TIMEOUT
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

@test "S14: the cache is v3 and a second run reuses it" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"

    run_scan
    assert_success

    run "$REAL_JQ" -r '.__meta.version' "$CACHE"
    assert_output "3"
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
    assert_output "3"
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
    : > "$FAKE_ARR_LOG"

    run_scan
    assert_failure 2
    # Saved before the next `run` overwrites $output.
    local hit_lines="$output"

    assert_stderr_contains "Sonarr scan failed"
    assert_stderr_contains "scan incomplete: Sonarr unreachable"
    refute_stderr_contains "No files missing Italian audio were found."

    # Sonarr failing does not stop Radarr. The report on disk is the previous
    # run's -- an incomplete run keeps it -- so asserting on the report would
    # prove nothing about this run: the live evidence is the request log and
    # the hit lines this run put on stdout.
    run arr_request_count "/radarr/api/v3/movie"
    assert_output "1"
    if [[ "$hit_lines" != *'[Radarr] Salt and Iron (2018) -> audio: English'* ]]; then
        printf 'Radarr was not scanned; stdout was:\n%s\n' "$hit_lines" >&2
        return 1
    fi

    run diff "$BATS_TEST_TMPDIR/cache-before.json" "$CACHE"
    assert_success
}

@test "S20: a failed episode fetch keeps the previous report and cache" {
    local dir
    dir="$(fixture_copy)"
    start_fake_arr "$dir"

    run_scan
    assert_success
    cp "$OUT" "$BATS_TEST_TMPDIR/report-before.csv"
    cp "$CACHE" "$BATS_TEST_TMPDIR/cache-before.json"

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
    assert_failure 2

    assert_stderr_contains "episode fetch failed for 'Le Colline Silenziose'"
    assert_stderr_contains "episode fetch failed for 'Brand New'"
    run diff "$BATS_TEST_TMPDIR/report-before.csv" "$OUT"
    assert_success
    run diff "$BATS_TEST_TMPDIR/cache-before.json" "$CACHE"
    assert_success

    # The cached series is still reported from its previous rows...
    assert_csv_has 'Sonarr,"Le Colline Silenziose",,"S01E02 - Cold Front","English","/media/tv/Le Colline Silenziose/Season 01/S01E02.mkv"'
    # ...the never-seen one contributes nothing and is not in the cache.
    run "$REAL_JQ" -r 'has("3")' "$CACHE"
    assert_output "false"
    run "$REAL_JQ" -r '."1".sig' "$CACHE"
    assert_output "10:123456"
}

@test "S41: a first-run episode fetch failure publishes no report or cache" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    arr_control '{"fail_count": {"/sonarr/api/v3/episode": 3}}'

    run_scan
    assert_failure 2
    [ ! -e "$OUT" ]
    [ ! -e "$CACHE" ]
    run tmp_leftovers
    assert_output "0"
}

@test "S42: a failed episodefile fallback keeps the report and retries next run" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    run_scan
    assert_success
    cp "$OUT" "$BATS_TEST_TMPDIR/report-before.csv"
    cp "$CACHE" "$BATS_TEST_TMPDIR/cache-before.json"
    arr_control '{"fail_count": {"/sonarr/api/v3/episodefile/77": 2}}'

    run_scan --refresh
    assert_failure 2
    run diff "$BATS_TEST_TMPDIR/report-before.csv" "$OUT"
    assert_success
    run diff "$BATS_TEST_TMPDIR/cache-before.json" "$CACHE"
    assert_success

    run_scan --refresh
    assert_success
    assert_csv_has 'Sonarr,"Le Colline Silenziose",,"S01E04 - Deferred File","German","/tv/s/S01E04.mkv"'
}

@test "S43: a malformed episode payload keeps the report and cache" {
    local dir payload
    dir="$(fixture_copy)"
    start_fake_arr "$dir"
    run_scan
    assert_success
    cp "$OUT" "$BATS_TEST_TMPDIR/report-before.csv"
    cp "$CACHE" "$BATS_TEST_TMPDIR/cache-before.json"

    for payload in '{}' '[{}]' '[{"hasFile":true,"episodeFileId":0}]'; do
        printf '%s\n' "$payload" > "$dir/sonarr/episodes_1.json"
        run_scan --refresh
        assert_failure 2
        run diff "$BATS_TEST_TMPDIR/report-before.csv" "$OUT"
        assert_success
        run diff "$BATS_TEST_TMPDIR/cache-before.json" "$CACHE"
        assert_success
    done
}

@test "S44: malformed list payloads cannot replace a report with empty findings" {
    local dir app payload
    dir="$(fixture_copy)"
    start_fake_arr "$dir"
    run_scan
    assert_success
    cp "$OUT" "$BATS_TEST_TMPDIR/report-before.csv"
    cp "$CACHE" "$BATS_TEST_TMPDIR/cache-before.json"

    for app in radarr/movies sonarr/series; do
        for payload in '{}' '[{}]'; do
            printf '%s\n' "$payload" > "$dir/$app.json"
            run_scan --refresh
            assert_failure 2
            run diff "$BATS_TEST_TMPDIR/report-before.csv" "$OUT"
            assert_success
            run diff "$BATS_TEST_TMPDIR/cache-before.json" "$CACHE"
            assert_success
        done
        cp "$BATS_TESTS_DIR/fixtures/$app.json" "$dir/$app.json"
    done
}

@test "S45: Radarr failure does not commit a newly computed Sonarr cache" {
    local dir
    dir="$(fixture_copy)"
    start_fake_arr "$dir"
    run_scan
    assert_success
    cp "$CACHE" "$BATS_TEST_TMPDIR/cache-before.json"
    cp "$dir/sonarr/series_changed_size.json" "$dir/sonarr/series.json"
    arr_control '{"fail_count": {"/radarr/api/v3/movie": 3}}'

    run_scan
    assert_failure 2
    run diff "$BATS_TEST_TMPDIR/cache-before.json" "$CACHE"
    assert_success
}

@test "S46: a malformed episodefile response is an incomplete scan" {
    local dir payload
    dir="$(fixture_copy)"
    start_fake_arr "$dir"

    for payload in '{}' '{"path":"/tv/x.mkv","mediaInfo":{"audioLanguages":[]}}'; do
        printf '%s\n' "$payload" > "$dir/sonarr/episodefile_77.json"
        run_scan
        assert_failure 2
        [ ! -e "$OUT" ]
        [ ! -e "$CACHE" ]
    done
}

@test "S47: changing the Sonarr server invalidates matching series signatures" {
    local dir
    dir="$(fixture_copy)"
    start_fake_arr "$dir"
    run_scan
    assert_success

    # Same IDs and sizes on another endpoint must never reuse the first library.
    SONARR_URL="${SONARR_URL/127.0.0.1/localhost}"
    export SONARR_URL
    "$REAL_JQ" 'map(.episodeFile.mediaInfo.audioLanguages = "Italian")' \
        "$dir/sonarr/episodes_2.json" > "$dir/sonarr/changed.json"
    mv "$dir/sonarr/changed.json" "$dir/sonarr/episodes_2.json"
    : > "$FAKE_ARR_LOG"

    run_scan
    assert_success
    run episode_requests 2
    assert_output "1"
    run grep -F 'Northbound' "$OUT"
    assert_failure
    run grep -F "$SONARR_API_KEY" "$CACHE"
    assert_failure
}

@test "S48: changes to series identity invalidate unchanged file statistics" {
    local dir field
    dir="$(fixture_copy)"
    start_fake_arr "$dir"
    run_scan
    assert_success

    for field in title path tvdbId added; do
        "$REAL_JQ" --arg field "$field" '.[0][$field] =
            (if $field == "tvdbId" then 9876 else "Changed" end)' \
            "$dir/sonarr/series.json" > "$dir/sonarr/changed.json"
        mv "$dir/sonarr/changed.json" "$dir/sonarr/series.json"
        : > "$FAKE_ARR_LOG"
        run_scan
        assert_success
        run episode_requests 1
        assert_output "1"
        run episode_requests 2
        assert_output "0"
    done
    assert_csv_has 'Sonarr,"Changed",,"S01E04 - Deferred File","German","/tv/s/S01E04.mkv"'
}

@test "S49: an incomplete or corrupt cache entry is rebuilt instead of hiding findings" {
    local expr
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    run_scan
    assert_success
    cp "$OUT" "$BATS_TEST_TMPDIR/report-before.csv"

    for expr in '."1".rows = null' '."1" = 42' \
        '."1".rows = ["Sonarr,forged\nrow"]' '."1".rows = ["not csv"]'; do
        "$REAL_JQ" "$expr" "$CACHE" > "$BATS_TEST_TMPDIR/broken.json"
        mv "$BATS_TEST_TMPDIR/broken.json" "$CACHE"
        : > "$FAKE_ARR_LOG"
        run_scan
        assert_success
        run episode_requests 1
        assert_output "1"
        run diff "$BATS_TEST_TMPDIR/report-before.csv" "$OUT"
        assert_success
    done
}

@test "S50: missing series statistics cannot authorize a cache hit" {
    local dir
    dir="$(fixture_copy)"
    "$REAL_JQ" 'map(del(.statistics))' "$dir/sonarr/series.json" \
        > "$dir/sonarr/changed.json"
    mv "$dir/sonarr/changed.json" "$dir/sonarr/series.json"
    start_fake_arr "$dir"
    run_scan
    assert_success
    : > "$FAKE_ARR_LOG"

    run_scan
    assert_success
    run episode_requests 1
    assert_output "1"
    run episode_requests 2
    assert_output "1"
}

@test "S51: the rescan timeout bounds a slow status request" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    arr_control '{"delay": 3, "command_status": ["started"]}'
    local started elapsed
    started="$(date +%s)"
    run --separate-stderr "$BASH_UNDER_TEST" -c '
        . "$1"
        arr_post() { printf "{\"id\":42}\n"; }
        RESCAN_TIMEOUT=1 RESCAN_POLL_INTERVAL=1
        wait_for_command "$SONARR_URL" "$SONARR_API_KEY" RescanSeries
    ' bash "$SCAN"
    elapsed=$(( $(date +%s) - started ))
    assert_failure 1
    assert_stderr_contains "did not complete within 1s"
    [ "$elapsed" -lt 3 ]
}

@test "S52: rescan sleep is capped to the remaining timeout" {
    run --separate-stderr "$BASH_UNDER_TEST" -c '
        . "$1"
        arr_post() { printf "{\"id\":42}\n"; }
        arr_get() { printf "{\"status\":\"started\"}\n"; }
        sleep() { printf "sleep:%s\n" "$1"; SECONDS=$((SECONDS + $1)); }
        RESCAN_TIMEOUT=1 RESCAN_POLL_INTERVAL=9
        wait_for_command http://example.invalid unused RescanSeries
    ' bash "$SCAN"
    assert_failure 1
    assert_output "sleep:1"
}

@test "S53: an output directory is rejected before making API calls" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    mkdir "$OUT"
    run_scan
    assert_failure 1
    run arr_request_count "/api/"
    assert_output "0"
    run find "$OUT" -type f
    assert_output ""
}

@test "S54: extra positional arguments are rejected without writing a report" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    run_scan ignored.csv
    assert_failure 1
    [ ! -e "$OUT" ]
    run arr_request_count "/api/"
    assert_output "0"
}

@test "S55: rescan durations are decimal and overflow values fall back safely" {
    run --separate-stderr "$BASH_UNDER_TEST" -c '
        . "$1"
        REFRESH_FLAG=false
        RESCAN_TIMEOUT=0008 RESCAN_POLL_INTERVAL=0002
        load_config
        printf "%s:%s\n" "$RESCAN_TIMEOUT" "$RESCAN_POLL_INTERVAL"
        RESCAN_TIMEOUT=99999999999999999999 RESCAN_POLL_INTERVAL=99999999999999999999
        load_config
        printf "%s:%s\n" "$RESCAN_TIMEOUT" "$RESCAN_POLL_INTERVAL"
    ' bash "$SCAN"
    assert_success
    assert_output $'8:2\n900:5'
}

@test "S56: a pre-existing predictable report-temp symlink cannot overwrite another file" {
    printf 'keep this file\n' > "$BATS_TEST_TMPDIR/victim"
    run --separate-stderr "$BASH_UNDER_TEST" -c '
        . "$1"
        ln -s "$3" "$2.tmp.$$"
        SKIP_RADARR=true SKIP_SONARR=true
        main "$2"
    ' bash "$SCAN" "$OUT" "$BATS_TEST_TMPDIR/victim"
    assert_success
    run cat "$BATS_TEST_TMPDIR/victim"
    assert_output "keep this file"
    [ -f "$OUT" ]
    [ ! -L "$OUT" ]
}

@test "S57: a directory at the cache destination is not treated as a cache update" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    mkdir "$CACHE"
    run_scan
    assert_success
    assert_stderr_contains "could not write Sonarr cache"
    run find "$CACHE" -type f
    assert_output ""
}

@test "S58: the report cannot replace a Radarr media path, including unflagged raw paths" {
    local dir language suffix
    dir="$(fixture_copy)"
    start_fake_arr "$dir"
    export SKIP_SONARR=true

    for language in English Italian; do
        for suffix in normal $'trailing \t\n\x1f '; do
            OUT="$BATS_TEST_TMPDIR/movie-$suffix"
            printf 'original media bytes\n' > "$OUT"
            "$REAL_JQ" -n --arg path "$OUT" --arg language "$language" \
                '[{hasFile:true, title:"Collision", movieFile:{path:$path,
                  mediaInfo:{audioLanguages:$language}}}]' > "$dir/radarr/movies.json"

            run_scan
            assert_failure 1
            assert_stderr_contains "would overwrite a media file"
            run cat "$OUT"
            assert_output "original media bytes"
        done
    done
}

@test "S59: report aliases through symlinks and hardlinks cannot replace media" {
    local dir alias
    dir="$(fixture_copy)"
    start_fake_arr "$dir"
    export SKIP_SONARR=true
    printf 'original media bytes\n' > "$BATS_TEST_TMPDIR/movie.mkv"
    "$REAL_JQ" -n --arg path "$BATS_TEST_TMPDIR/movie.mkv" \
        '[{hasFile:true, movieFile:{path:$path, mediaInfo:{audioLanguages:"Italian"}}}]' \
        > "$dir/radarr/movies.json"

    for alias in symbolic hard; do
        rm -f "$OUT"
        if [[ "$alias" == symbolic ]]; then
            ln -s "$BATS_TEST_TMPDIR/movie.mkv" "$OUT"
        else
            ln "$BATS_TEST_TMPDIR/movie.mkv" "$OUT"
        fi
        run_scan
        assert_failure 1
        run cat "$OUT"
        assert_output "original media bytes"
        [[ "$OUT" -ef "$BATS_TEST_TMPDIR/movie.mkv" ]]
    done
}

@test "S60: the cache cannot replace an Italian media file and leaves the report intact" {
    local dir
    dir="$(fixture_copy)"
    start_fake_arr "$dir"
    printf 'previous report\n' > "$OUT"
    printf 'original media bytes\n' > "$CACHE"
    "$REAL_JQ" -n --arg path "$CACHE" \
        '[{hasFile:true, movieFile:{path:$path, mediaInfo:{audioLanguages:"Italian"}}}]' \
        > "$dir/radarr/movies.json"

    run_scan
    assert_failure 1
    run cat "$OUT"
    assert_output "previous report"
    run cat "$CACHE"
    assert_output "original media bytes"
}

@test "S61: episodefile fallback paths are protected even when the file is Italian" {
    local dir
    dir="$(fixture_copy)"
    start_fake_arr "$dir"
    export SKIP_RADARR=true
    printf 'original media bytes\n' > "$OUT"
    "$REAL_JQ" -n --arg path "$OUT" \
        '{path:$path, mediaInfo:{audioLanguages:"Italian"}}' \
        > "$dir/sonarr/episodefile_77.json"

    run_scan
    assert_failure 1
    run cat "$OUT"
    assert_output "original media bytes"
    [ ! -e "$CACHE" ]
}

@test "S62: warm Sonarr cache protects raw paths of files excluded from the CSV" {
    local dir media
    dir="$(fixture_copy)"
    media="$BATS_TEST_TMPDIR/Italian "
    printf 'original media bytes\n' > "$media"
    "$REAL_JQ" --arg path "$media" \
        'map(.episodeFile.path = $path | .episodeFile.mediaInfo.audioLanguages = "Italian")' \
        "$dir/sonarr/episodes_2.json" > "$dir/sonarr/changed.json"
    mv "$dir/sonarr/changed.json" "$dir/sonarr/episodes_2.json"
    start_fake_arr "$dir"
    run_scan
    assert_success
    cp "$CACHE" "$BATS_TEST_TMPDIR/cache-before.json"
    rm "$OUT"
    ln "$media" "$OUT"
    : > "$FAKE_ARR_LOG"

    run_scan
    assert_failure 1
    run episode_request_total
    assert_output "0"
    run cat "$OUT"
    assert_output "original media bytes"
    run diff "$BATS_TEST_TMPDIR/cache-before.json" "$CACHE"
    assert_success
}

@test "S63: a cache missing original media paths is rebuilt before reuse" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    run_scan
    assert_success
    "$REAL_JQ" 'del(."1".paths)' "$CACHE" > "$BATS_TEST_TMPDIR/old-cache.json"
    mv "$BATS_TEST_TMPDIR/old-cache.json" "$CACHE"
    : > "$FAKE_ARR_LOG"
    run_scan
    assert_success
    run episode_requests 1
    assert_output "1"
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
# S9-S11: a failed list fetch, retries, and the report that survives it
# --------------------------------------------------------------------------

@test "S9: a 401 from Radarr exits 2, keeps the report and still scans Sonarr" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"

    # A complete run first, so there is a report worth protecting.
    run_scan
    assert_success
    cp "$OUT" "$BATS_TEST_TMPDIR/before.csv"
    : > "$FAKE_ARR_LOG"

    # REFRESH so Sonarr really is re-scanned and prints its hit lines, rather
    # than replaying the cache silently.
    export RADARR_API_KEY="not-the-key" REFRESH=true

    run_scan
    assert_failure 2
    assert_stderr_contains "Radarr scan failed"
    assert_stderr_contains "scan incomplete: Radarr unreachable; previous report kept"
    refute_stderr_contains "No files missing Italian audio were found."

    # One app failing does not stop the other.
    [[ "$output" == *'[Sonarr] Northbound - S01E01 - Due North -> audio: English'* ]] || {
        printf 'Sonarr was not scanned; stdout was:\n%s\n' "$output" >&2
        return 1
    }
    run arr_request_count "/sonarr/api/v3/series"
    assert_output "1"

    # And the report on disk is exactly the one the previous run left.
    run cmp -s "$BATS_TEST_TMPDIR/before.csv" "$OUT"
    assert_success
    run tmp_leftovers
    assert_output "0"
}

@test "S10: a persistent 500 is tried three times and the previous report survives" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    export SKIP_SONARR=true

    run_scan
    assert_success
    cp "$OUT" "$BATS_TEST_TMPDIR/before.csv"
    : > "$FAKE_ARR_LOG"

    # More scheduled failures than there are attempts: every one gets a 500.
    arr_control '{"fail_count": {"/radarr/api/v3/movie": 9}}'

    run_scan
    assert_failure 2
    assert_stderr_contains "scan incomplete: Radarr unreachable; previous report kept"

    # Three attempts, not one and not forever.
    run arr_request_count "/radarr/api/v3/movie"
    assert_output "3"

    # Byte for byte the previous report, and no temporary file left behind.
    run cmp -s "$BATS_TEST_TMPDIR/before.csv" "$OUT"
    assert_success
    run tmp_leftovers
    assert_output "0"
}

@test "S10 twin: with no previous report a failed run writes none at all" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    export SKIP_SONARR=true
    arr_control '{"fail_count": {"/radarr/api/v3/movie": 9}}'

    run_scan
    assert_failure 2
    assert_stderr_contains "scan incomplete: Radarr unreachable; no report written"
    refute_stderr_contains "previous report kept"

    [ ! -f "$OUT" ]
    run tmp_leftovers
    assert_output "0"
}

@test "S11: two 500s then a 200 is a success, in three requests" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    export SKIP_SONARR=true
    arr_control '{"fail_count": {"/radarr/api/v3/movie": 2}}'

    run_scan
    assert_success

    run arr_request_count "/radarr/api/v3/movie"
    assert_output "3"
    assert_csv_has 'Radarr,"Salt and Iron",2018,,"English","/media/movies/Salt and Iron (2018)/Salt and Iron (2018).mkv"'
}

# --------------------------------------------------------------------------
# S22-S24, S36: FORCE_RESCAN and the command poll
# --------------------------------------------------------------------------

@test "S22: FORCE_RESCAN rescans both apps and defeats the Sonarr cache" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"

    run_scan
    assert_success
    : > "$FAKE_ARR_LOG"

    export FORCE_RESCAN=true

    run_scan
    assert_success

    assert_stderr_contains "FORCE_RESCAN implies --refresh"
    assert_stderr_contains "RescanMovie completed."
    assert_stderr_contains "RescanSeries completed."

    run command_posts radarr
    assert_output '{"name":"RescanMovie"}'
    run command_posts sonarr
    assert_output '{"name":"RescanSeries"}'

    run arr_request_count "/radarr/api/v3/command/42"
    [ "$output" -ge 1 ] || {
        printf 'the command was never polled (%s GETs)\n' "$output" >&2
        return 1
    }

    # The signature has not moved, and the series is fetched anyway: a rescan
    # rewrites tags without changing the file count or the size on disk, so a
    # cache hit would hide exactly what the rescan was asked for.
    run episode_requests 1
    assert_output "1"
    refute_stderr_contains "[cache]"
}

@test "S23: RESCAN_TIMEOUT=0 gives up at once and still writes the report" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    export SKIP_SONARR=true FORCE_RESCAN=true RESCAN_TIMEOUT=0

    local started elapsed
    started="$(date +%s)"
    run_scan
    assert_success
    elapsed=$(( $(date +%s) - started ))

    assert_stderr_contains "RescanMovie did not complete within 0s"
    [ "$elapsed" -lt 2 ] || {
        printf 'a zero timeout still slept: %ss\n' "$elapsed" >&2
        return 1
    }

    run arr_request_count "/radarr/api/v3/command/42"
    assert_output "0"
    assert_csv_has 'Radarr,"Salt and Iron",2018,,"English","/media/movies/Salt and Iron (2018)/Salt and Iron (2018).mkv"'
}

@test "S24: a rescan that reports 'failed' warns and the scan continues" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    export SKIP_SONARR=true FORCE_RESCAN=true
    arr_control '{"command_status": ["failed"]}'

    run_scan
    assert_success

    assert_stderr_contains "RescanMovie reported status 'failed'."
    assert_csv_has 'Radarr,"Salt and Iron",2018,,"English","/media/movies/Salt and Iron (2018)/Salt and Iron (2018).mkv"'
}

@test "S36: a rescan that reports 'aborted' warns and the scan continues" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    export SKIP_SONARR=true FORCE_RESCAN=true
    arr_control '{"command_status": ["aborted"]}'

    run_scan
    assert_success

    assert_stderr_contains "RescanMovie reported status 'aborted'."
    assert_csv_has 'Radarr,"Salt and Iron",2018,,"English","/media/movies/Salt and Iron (2018)/Salt and Iron (2018).mkv"'
}

# --------------------------------------------------------------------------
# S25-S27: where the configuration comes from
# --------------------------------------------------------------------------

@test "S25: the .env supplies the configuration and the environment overrides it" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"

    local envfile="$BATS_TEST_TMPDIR/dot.env"
    fake_env "$envfile"
    grep -qx 'FORCE_RESCAN=false' "$envfile"

    forget_arr_env
    export ALA_DOTENV_FILE="$envfile"
    export FORCE_RESCAN=true

    run_scan
    assert_success

    # The URLs and the keys came from the file...
    run arr_request_count "/radarr/api/v3/movie"
    assert_output "1"
    run arr_request_count "/sonarr/api/v3/series"
    assert_output "1"

    # ...and the environment beat the file's FORCE_RESCAN=false.
    run command_posts radarr
    assert_output '{"name":"RescanMovie"}'

    # The committed .env.example parses without a single complaint.
    refute_stderr_contains "ignoring"
}

@test "S26: a command substitution in a .env value is inert and arrives literally" {
    local marker="$BATS_TEST_TMPDIR/pwned"
    local evil="\$(touch $marker)key"

    export FAKE_RADARR_KEY="$evil"
    start_fake_arr "$BATS_TESTS_DIR/fixtures"

    local envfile="$BATS_TEST_TMPDIR/evil.env"
    printf 'RADARR_URL=%s\n' "$RADARR_URL" > "$envfile"
    printf 'RADARR_API_KEY=%s\n' "$evil" >> "$envfile"

    forget_arr_env
    export SKIP_SONARR=true
    export ALA_DOTENV_FILE="$envfile"

    run_scan
    assert_success

    # Nothing ran.
    [ ! -e "$marker" ]

    # key_ok is the server comparing what arrived against the literal string,
    # so a true here is the key crossing curl unexpanded and unmangled.
    run "$REAL_JQ" -s -r \
        '[.[] | select(.path == "/radarr/api/v3/movie") | .key_ok] | join(",")' \
        "$FAKE_ARR_LOG"
    assert_output "true"
}

@test "S27: <repo>/.env beats <repo>/scan/.env and a .env in the CWD is ignored" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"

    # A copy of the repository layout: the script derives its root from
    # lib/common.sh, so these two files are the whole tree it needs.
    local repo="$BATS_TEST_TMPDIR/repo" cwd="$BATS_TEST_TMPDIR/elsewhere"
    local script="$repo/scan/find-missing-italian-audio.sh"
    mkdir -p "$repo/lib" "$repo/scan" "$cwd"
    cp "$ROOT/lib/common.sh" "$repo/lib/common.sh"
    cp "$SCAN" "$script"

    printf 'RADARR_URL=%s\nRADARR_API_KEY=%s\n' "$RADARR_URL" "$RADARR_API_KEY" \
        > "$repo/.env"
    printf 'RADARR_URL=%s\nRADARR_API_KEY=%s\n' "$RADARR_URL" "wrong-scan-key" \
        > "$repo/scan/.env"
    printf 'RADARR_URL=%s\nRADARR_API_KEY=%s\n' "$RADARR_URL" "wrong-cwd-key" \
        > "$cwd/.env"

    forget_arr_env
    unset ALA_DOTENV_FILE
    export SKIP_SONARR=true

    # The root file wins over scan/, and the .env in the working directory --
    # a directory someone else may be able to write -- is never a candidate.
    run --separate-stderr "$BASH_UNDER_TEST" -c \
        'cd "$1" && exec "$2" "$3" "$4"' bash "$cwd" "$BASH_UNDER_TEST" \
        "$script" "$OUT"
    assert_success
    assert_csv_has 'Radarr,"Salt and Iron",2018,,"English","/media/movies/Salt and Iron (2018)/Salt and Iron (2018).mkv"'

    # With the root file gone scan/.env is next, and its key is the wrong one.
    rm -f "$repo/.env"
    run --separate-stderr "$BASH_UNDER_TEST" -c \
        'cd "$1" && exec "$2" "$3" "$4"' bash "$cwd" "$BASH_UNDER_TEST" \
        "$script" "$OUT"
    assert_failure 2
    assert_stderr_contains "Radarr scan failed"
}

# --------------------------------------------------------------------------
# S28-S29: the command line and the non-interactive contract
# --------------------------------------------------------------------------

@test "S28: an unknown option exits 1 and -- ends the options" {
    run --separate-stderr "$BASH_UNDER_TEST" "$SCAN" --bogus
    assert_failure 1
    assert_stderr_contains "unknown option: --bogus"

    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    export SKIP_SONARR=true

    # A report whose name begins with two dashes is an argument, not a flag,
    # and every command it is handed to has to be told so.
    run --separate-stderr "$BASH_UNDER_TEST" -c \
        'cd "$1" && exec "$2" "$3" -- --weird.csv' bash \
        "$BATS_TEST_TMPDIR" "$BASH_UNDER_TEST" "$SCAN"
    assert_success

    [ -f "$BATS_TEST_TMPDIR/--weird.csv" ]
    run grep -c 'Salt and Iron' "$BATS_TEST_TMPDIR/--weird.csv"
    assert_output "1"
}

@test "S29: with no configuration and no terminal the wizard never runs" {
    forget_arr_env
    export ARR_TIMEOUT=2

    local started elapsed
    started="$(date +%s)"
    run --separate-stderr "$BASH_UNDER_TEST" "$SCAN" "$OUT" < /dev/null
    elapsed=$(( $(date +%s) - started ))

    assert_failure 2
    refute_stderr_contains "starting interactive setup"
    assert_stderr_contains "scan incomplete: Radarr, Sonarr unreachable"
    [ ! -f "$OUT" ]
    [ "$elapsed" -lt 30 ] || {
        printf 'a run with nothing configured took %ss\n' "$elapsed" >&2
        return 1
    }
}

# --------------------------------------------------------------------------
# S31-S32: CRLF responses and where the output lands
# --------------------------------------------------------------------------

@test "S31: CRLF responses leave no carriage return in the report or the cache" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    arr_control '{"crlf": true}'

    run_scan
    assert_success

    run "$REAL_PYTHON3" -c \
        'import sys; sys.exit(1 if b"\r" in open(sys.argv[1], "rb").read() else 0)' \
        "$OUT"
    assert_success
    run "$REAL_PYTHON3" -c \
        'import sys; sys.exit(1 if b"\r" in open(sys.argv[1], "rb").read() else 0)' \
        "$CACHE"
    assert_success

    run "$REAL_JQ" -r 'keys | join(",")' "$CACHE"
    assert_output "1,2,__meta"
    run "$REAL_JQ" -r '."1".sig' "$CACHE"
    assert_output "10:123456"
}

@test "S32: a report path in a new directory is created and the cache lands beside it" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"

    OUT="$BATS_TEST_TMPDIR/new/deeper/report.csv"
    CACHE="$BATS_TEST_TMPDIR/new/deeper/report.cache.json"
    [ ! -d "$BATS_TEST_TMPDIR/new" ]

    run_scan
    assert_success

    [ -f "$OUT" ]
    [ -f "$CACHE" ]
    assert_csv_has 'Radarr,"Salt and Iron",2018,,"English","/media/movies/Salt and Iron (2018)/Salt and Iron (2018).mkv"'
    run tmp_leftovers
    assert_output "0"
}

# --------------------------------------------------------------------------
# S33, S37: the first-run wizard
# --------------------------------------------------------------------------

@test "S33: the wizard writes a 0600 .env from scripted answers" {
    # The wizard accepts letters and digits only, which is what Radarr and
    # Sonarr generate; the fake's default "radarr-key" would be refused.
    export FAKE_RADARR_KEY=radarrkey
    start_fake_arr "$BATS_TESTS_DIR/fixtures"

    local envfile="$BATS_TEST_TMPDIR/wizard.env" url="$RADARR_URL"
    : > "$envfile"

    forget_arr_env
    export SKIP_SONARR=true
    export ALA_DOTENV_FILE="$envfile"
    # ARR_ASSUME_TTY drives the wizard without a terminal; ARR_LOCALHOST keeps
    # the probe off whatever the developer may be running on port 7878.
    export ARR_ASSUME_TTY=1 ARR_LOCALHOST=127.0.0.1

    printf 'y\n%s\nradarrkey\ny\n' "$url" > "$BATS_TEST_TMPDIR/answers"
    run --separate-stderr "$BASH_UNDER_TEST" "$SCAN" "$OUT" \
        < "$BATS_TEST_TMPDIR/answers"
    assert_success
    # Saved before the next `run` overwrites $output.
    local hit_lines="$output"

    # A file holding an API key is readable by its owner and nobody else.
    run file_mode "$envfile"
    assert_output "600"

    run grep -cxF "RADARR_URL=$url" "$envfile"
    assert_output "1"
    run grep -cxF "RADARR_API_KEY=radarrkey" "$envfile"
    assert_output "1"

    # Every line the wizard writes is an allow-listed KEY=value.
    run grep -cvE '^([A-Z_]+=.*)?$' "$envfile"
    assert_output "0"

    # The wizard talks on stderr only: stdout is still just the hit lines.
    [ -n "$hit_lines" ]
    local line
    while IFS= read -r line; do
        if [[ ! "$line" =~ ^\[(Radarr|Sonarr)\]\  ]]; then
            printf 'unexpected stdout line: %s\n' "$line" >&2
            return 1
        fi
    done <<< "$hit_lines"

    # And the configuration it saved is the one the next run reads back.
    : > "$FAKE_ARR_LOG"
    run --separate-stderr "$BASH_UNDER_TEST" "$SCAN" "$OUT" < /dev/null
    assert_success
    run arr_request_count "/radarr/api/v3/movie"
    assert_output "1"
}

@test "S33 twin: an answer with no trailing newline is still an answer" {
    export FAKE_RADARR_KEY=radarrkey
    start_fake_arr "$BATS_TESTS_DIR/fixtures"

    local envfile="$BATS_TEST_TMPDIR/wizard.env" url="$RADARR_URL"
    : > "$envfile"

    forget_arr_env
    export SKIP_SONARR=true
    export ALA_DOTENV_FILE="$envfile"
    export ARR_ASSUME_TTY=1 ARR_LOCALHOST=127.0.0.1

    # No newline after the final "y": read returns 1 at end of input having
    # already assigned it, and a prompt that discarded the value on that rc
    # would read it as "do not save".
    printf 'y\n%s\nradarrkey\ny' "$url" > "$BATS_TEST_TMPDIR/answers"
    run --separate-stderr "$BASH_UNDER_TEST" "$SCAN" "$OUT" \
        < "$BATS_TEST_TMPDIR/answers"
    assert_success

    run grep -cxF "RADARR_API_KEY=radarrkey" "$envfile"
    assert_output "1"
    run file_mode "$envfile"
    assert_output "600"
}

@test "S37: the wizard rejects a URL with a space and saves nothing" {
    local envfile="$BATS_TEST_TMPDIR/wizard.env"
    : > "$envfile"

    forget_arr_env
    export SKIP_SONARR=true
    export ALA_DOTENV_FILE="$envfile"
    export ARR_ASSUME_TTY=1 ARR_LOCALHOST=127.0.0.1 ARR_TIMEOUT=2

    # One re-prompt, then the save is abandoned rather than writing a value
    # that would only fail later.
    printf 'y\nhttp://has a space\nstill not a url\n' \
        > "$BATS_TEST_TMPDIR/answers"
    run --separate-stderr "$BASH_UNDER_TEST" "$SCAN" "$OUT" \
        < "$BATS_TEST_TMPDIR/answers"

    assert_failure 2
    assert_stderr_contains "not a usable URL"
    assert_stderr_contains "configuration not saved"

    [ ! -s "$envfile" ]
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
    assert_output "3"

    # And the rows the old cache claimed were empty are back in the report.
    assert_csv_has 'Sonarr,"Northbound",,"S01E01 - Due North","English","/media/tv/Northbound/Season 01/S01E01.mkv"'
}

@test "S35 twin: a cache built with a different regex is discarded" {
    start_fake_arr "$BATS_TESTS_DIR/fixtures"
    run_scan
    assert_success
    "$REAL_JQ" '.__meta.regex = "italian|ita|it-it"' "$CACHE" \
        > "$BATS_TEST_TMPDIR/old-regex.json"
    mv "$BATS_TEST_TMPDIR/old-regex.json" "$CACHE"
    : > "$FAKE_ARR_LOG"

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
    run tmp_leftovers
    assert_output "0"
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

    # An interrupted run publishes nothing. The report is built in a temporary
    # file and only moved into place by a run that completed, and the signal
    # handler removes that file: there was no previous report here, so there is
    # no report at all, and no half-written one either.
    [ ! -f "$OUT" ]
    run tmp_leftovers
    assert_output "0"
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

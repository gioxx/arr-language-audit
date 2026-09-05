#!/usr/bin/env bash
#
# Phase 1 of arr-language-audit.
#
# Scans Radarr and Sonarr libraries for media files that do NOT have an
# Italian audio track, using the mediaInfo already computed by the *arr
# apps. Nothing on disk is touched: the only output is a CSV report.
#
# Requirements: bash 3.2, curl, jq
#
# Usage:
#   ./scan/find-missing-italian-audio.sh [OUTPUT_CSV] [--refresh]
#
# Design notes that matter when changing this file:
#
#   * One jq invocation formats a whole payload. jq emits the finished CSV
#     row and the finished stdout line, already quoted and escaped, joined by
#     a US byte (\x1f); bash only splits on that byte and writes. The old
#     implementation split jq's @tsv output on tabs, which silently collapses
#     consecutive tabs, so a file with an EMPTY audioLanguages -- the exact
#     case this tool exists to find -- had its path shifted into the language
#     column and was then matched against the Italian regex.
#   * US is the only in-band separator, and every value that crosses the
#     jq/bash boundary has US, CR, LF and TAB scrubbed out of it first.
#   * The Italian test lives inside jq (test($re; "i")) and is anchored, so
#     "Occitan" is no longer read as containing "ita".
#   * bash 3.2 (the /bin/bash macOS ships): no reading a command into an
#     array in one builtin, no associative arrays, no case-converting
#     expansions.
#
# Sonarr is queried once per series (episodes with their file embedded), and
# a small cache file next to OUTPUT_CSV (<name>.cache.json) lets unchanged
# series be skipped on the next run. Radarr is a single request and is not
# cached. See "Sonarr cache" near SONARR_CACHE_FILE below.
#
# On first run (interactive terminal, no saved config found), a setup
# wizard walks you through configuring Radarr/Sonarr: it auto-detects a
# locally running instance on the default port (7878 / 8989) via the
# unauthenticated /ping endpoint, and only asks for the API key in that
# case. Non-interactive runs (cron, CI, piped input) skip the wizard and
# rely purely on environment variables / an existing .env file.
#
# Environment variables (also read from a .env file, see usage()):
#   RADARR_URL RADARR_API_KEY SKIP_RADARR
#   SONARR_URL SONARR_API_KEY SKIP_SONARR
#   FORCE_RESCAN RESCAN_TIMEOUT REFRESH
#
# Exit codes:
#   0   completed (with or without findings)
#   1   missing dependency (jq / curl) or bad arguments
#   2   an enabled app could not be listed; the CSV holds what was scanned

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" > /dev/null 2>&1 && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

# ---------------------------------------------------------------------------
# CONSTANTS
# ---------------------------------------------------------------------------

# The unit separator. It is the only byte that separates fields between jq and
# bash, and jq scrubs it out of every value it emits, so no title, path or
# language tag can forge a field boundary.
US=$'\x1f'

# "Italian audio present". Anchored on both sides so a language name that
# merely contains the letters ("Occitan", "Sanskrit") is not a false match.
# Applied only inside jq, with test($re; "i") -- never with grep.
ITALIAN_REGEX='(^|[^a-z])(italian|ita|it-it)([^a-z]|$)'

CSV_HEADER='App,Title,Year,Episode,AudioLanguages,Path'

# --- jq programs -----------------------------------------------------------
#
# Single-quoted, so bash passes them through untouched and every escape below
# is jq's own. Each is used as "$JQ_DEFS$JQ_SOMETHING".

# clean:   removes what may not cross the jq/bash boundary -- the separator
#          and the three whitespace bytes that break a line-oriented reader.
#          U+001F is in the class for the same reason the separator exists.
# logsafe: clean, plus the remaining control characters, which have no
#          business on a terminal.
# csvq:    RFC 4180 quoting on top of clean.
JQ_DEFS='
def clean: tostring | gsub("[\r\n\t\u001f]"; " ");
def logsafe: clean | gsub("[\u0001-\u001f\u007f]"; "");
def csvq: "\"" + (clean | gsub("\""; "\"\"")) + "\"";
def pad2: if length < 2 then "0" + . else . end;
def us: "\u001f";
def audio_label($al): if $al == "" then "<none>" else ($al | logsafe) end;
'

# Radarr: the whole /movie payload in one pass. Emits "<csv row>US<log line>".
JQ_RADARR='
.[]
| select(.hasFile == true)
| (.movieFile.mediaInfo.audioLanguages // "") as $al
| select($al | test($re; "i") | not)
| ("Radarr," + ((.title // "") | csvq) + "," + ((.year // "") | tostring)
   + ",," + ($al | csvq) + "," + ((.movieFile.path // "") | csvq))
  + us
  + ("[Radarr] " + ((.title // "") | logsafe) + " (" + ((.year // "") | tostring)
     + ") -> audio: " + audio_label($al))
'

# Sonarr, pass 1: join /series with the cache in one go. Emits
# "<id>US<title>US<sig>US<HIT|STALE|MISS>". STALE means "the cache holds an
# entry for this series but its signature moved", which is the only state
# where a failed episode fetch may fall back to the previous rows.
JQ_SERIES='
($cache[0] // {}) as $c
| .[]
| ((.id // "") | tostring) as $id
| "\((.statistics.episodeFileCount // 0)):\((.statistics.sizeOnDisk // 0))" as $sig
| ($c[$id] // null) as $entry
| $id + us + ((.title // "") | logsafe) + us + $sig + us
  + (if $entry == null then "MISS"
     elif (($entry.sig // "") == $sig) then "HIT"
     else "STALE"
     end)
'

# Sonarr, pass 2: every cached row of every cache hit, in one pass over the
# cache, as "<id>US<row>". $ids is in series order, so the reader walks the
# result with a single index.
JQ_CACHED_ROWS='
. as $c
| $ids[]
| . as $id
| ($c[$id].rows[]? | $id + us + .)
'

# Sonarr, per uncached series: the whole /episode payload in one pass. Emits
# either "<csv row>US<log line>" or, for the rare episode flagged hasFile with
# no embedded file object, "NEEDFILE" US <episodeFileId> US <label>.
JQ_EPISODES='
.[]
| select(.hasFile == true)
| ((.episodeFileId // 0) | tostring) as $efid
| select($efid != "0" and $efid != "")
| ("S" + ((.seasonNumber // 0) | tostring | pad2)
   + "E" + ((.episodeNumber // 0) | tostring | pad2)
   + " - " + ((.title // "") | clean)) as $label
| (.episodeFile.path // "") as $path
| if $path == "" then
    "NEEDFILE" + us + $efid + us + $label
  else
    (.episodeFile.mediaInfo.audioLanguages // "") as $al
    | select($al | test($re; "i") | not)
    | ("Sonarr," + ($title | csvq) + ",," + ($label | csvq) + ","
       + ($al | csvq) + "," + ($path | csvq))
      + us
      + ("[Sonarr] " + ($title | logsafe) + " - " + ($label | logsafe)
         + " -> audio: " + audio_label($al))
  end
'

# The NEEDFILE fallback: one /episodefile/<id> body into the same pair of
# fields. Fed "{}" when even that request failed, which reproduces the
# previous behaviour of reporting the episode with no language and no path
# rather than dropping it.
JQ_EPISODEFILE='
(.mediaInfo.audioLanguages // "") as $al
| (.path // "") as $path
| select($al | test($re; "i") | not)
| ("Sonarr," + ($title | csvq) + ",," + ($label | csvq) + ","
   + ($al | csvq) + "," + ($path | csvq))
  + us
  + ("[Sonarr] " + ($title | logsafe) + " - " + ($label | logsafe)
     + " -> audio: " + audio_label($al))
'

# One rescanned series -> one JSONL cache fragment. Input is its raw rows.
JQ_CACHE_ENTRY='
{ id: $id, entry: { sig: $sig, rows: (split("\n") | map(select(length > 0))) } }
'

# The whole cache, from the JSONL fragments: a fragment carrying an "entry"
# was rescanned, one without it carries the previous entry forward.
JQ_CACHE_MERGE='
($cache[0] // {}) as $old
| reduce .[] as $f ({};
    (if ($f | has("entry")) then $f.entry else $old[$f.id] end) as $e
    | if $e == null then . else .[$f.id] = $e end)
| . + { "__meta": { "version": 2, "regex": $re } }
'

# Cache readability and schema in one pass: the payload without __meta when it
# is a v2 cache built with this regex, the string "FORMAT" when it is not.
JQ_CACHE_LOAD='
if ((.__meta? | type) == "object") and (.__meta.version == 2) and (.__meta.regex == $re)
then del(.__meta)
else "FORMAT"
end
'

# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------

usage() {
    cat <<'EOF'
Phase 1 of arr-language-audit -- find media files without an Italian audio tag.

Scans Radarr and Sonarr libraries via their APIs, reads the mediaInfo the
apps already computed for each downloaded file, and exports to CSV every
file whose audioLanguages tag is not explicitly Italian. Nothing on disk
is modified; the only output is the CSV report.

Usage:
  find-missing-italian-audio.sh [OUTPUT_CSV] [--refresh]
  find-missing-italian-audio.sh -h | --help

Arguments:
  OUTPUT_CSV          report path
                      (default: <repo>/reports/missing-italian-audio.csv).
                      With zero findings the file is still written, with its
                      header row and nothing else.

Options:
  --refresh           ignore the Sonarr per-series cache and re-fetch every
                      series (same as REFRESH=true)

Environment variables (also read from a .env file, see below):
  RADARR_URL          Radarr base URL          (default: http://localhost:7878)
  RADARR_API_KEY      Radarr API key
  SONARR_URL          Sonarr base URL          (default: http://localhost:8989)
  SONARR_API_KEY      Sonarr API key
  SKIP_RADARR         true to skip Radarr entirely            (default: false)
  SKIP_SONARR         true to skip Sonarr entirely            (default: false)
  FORCE_RESCAN        true to run RescanMovie / RescanSeries before reading
                      mediaInfo, so stale cached tags are refreshed from
                      disk. Implies REFRESH=true: a rescan that changes only
                      the tags leaves the per-series signature untouched, and
                      a cache hit would hide exactly what was rescanned for
                                                              (default: false)
  RESCAN_TIMEOUT      seconds to wait for a rescan to finish  (default: 300)
  REFRESH             true to ignore the Sonarr per-series cache
                                                              (default: false)

Sonarr is fetched once per series (episodes with the file embedded). A cache
file next to OUTPUT_CSV (<name>.cache.json) records a per-series signature
(file count + size on disk) and the rows that series produced; an unchanged
series is not re-fetched on the next run. The cache carries a "__meta" block
with its schema version and the Italian regex it was built with; a cache
written by another version is discarded and rebuilt. Radarr is one request
and is not cached.

.env file: looked up in <repo>/.env, then <repo>/scan/.env; first match wins.
The current working directory is deliberately not searched. A value already
in the environment wins over the file, the file wins over the defaults above,
and --refresh wins over both. Format is KEY=value, one per line. See
.env.example in the repo root.

On first interactive run with no config, a wizard auto-detects local
Radarr/Sonarr via the unauthenticated /ping endpoint and can save a .env.

Exit codes:
  0   completed (with or without findings)
  1   missing dependency (jq / curl) or bad arguments
  2   an enabled app could not be listed after retries; the other app was
      still scanned and the CSV holds everything that was
EOF
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

# parse_args "$@" -- sets REFRESH_FLAG and the POSITIONAL array. Exits 0 on
# --help and 1 on an unknown option, as the exit codes above promise.
parse_args() {
    REFRESH_FLAG=false
    POSITIONAL=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --refresh) REFRESH_FLAG=true; shift ;;
            --)        shift
                       while [[ $# -gt 0 ]]; do POSITIONAL+=("$1"); shift; done ;;
            -*)        err "unknown option: $1"
                       echo "Try --help." >&2
                       exit 1 ;;
            *)         POSITIONAL+=("$1"); shift ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------------

# load_config -- the environment first, then the .env file for whatever the
# environment left unset, then the --refresh flag, then the defaults.
# load_dotenv never overwrites a set, non-empty variable, so it has to run
# before any "${VAR:-default}" of ours would fill one in.
load_config() {
    local candidate
    candidate="$(find_dotenv || true)"
    if [[ -n "$candidate" ]]; then
        load_dotenv "$candidate" || true
        ENV_FILE="$candidate"
    else
        # Where the wizard offers to save.
        ENV_FILE="$ALA_ENV_FILE"
    fi

    RADARR_URL="$(normalize_url "${RADARR_URL:-}")"
    SONARR_URL="$(normalize_url "${SONARR_URL:-}")"
    RADARR_API_KEY="${RADARR_API_KEY:-}"
    SONARR_API_KEY="${SONARR_API_KEY:-}"

    SKIP_RADARR="${SKIP_RADARR:-false}"
    SKIP_SONARR="${SKIP_SONARR:-false}"
    FORCE_RESCAN="${FORCE_RESCAN:-false}"
    RESCAN_TIMEOUT="${RESCAN_TIMEOUT:-300}"
    REFRESH="${REFRESH:-false}"

    if [[ "$REFRESH_FLAG" == "true" ]]; then
        REFRESH=true
    fi
    # A rescan can change a file's tags without changing the file count or the
    # size on disk, so the signature would still match and the cache would hide
    # the very thing the rescan was asked for.
    if is_true "$FORCE_RESCAN"; then
        REFRESH=true
    fi
}

# apply_defaults -- last-resort placeholders, after the wizard has had its
# chance. A placeholder simply fails its API call and is reported.
apply_defaults() {
    RADARR_URL="${RADARR_URL:-http://localhost:7878}"
    RADARR_API_KEY="${RADARR_API_KEY:-YOUR_RADARR_API_KEY}"
    SONARR_URL="${SONARR_URL:-http://localhost:8989}"
    SONARR_API_KEY="${SONARR_API_KEY:-YOUR_SONARR_API_KEY}"
}

# ---------------------------------------------------------------------------
# SETUP WIZARD
# ---------------------------------------------------------------------------

is_interactive() { [[ -t 0 && -t 1 ]]; }

# The unauthenticated /ping endpoint both apps expose: a local instance can be
# detected without an API key.
probe_local_port() {
    local port="$1"
    curl -sf -m 2 "http://localhost:$port/ping" 2>/dev/null |
        grep -q '"status"[[:space:]]*:[[:space:]]*"OK"'
}

# prompt_app_config <label> <port> <url-var> <key-var> <skip-var> -- fills the
# named variables in for one app.
prompt_app_config() {
    local app_label="$1" default_port="$2" url_var="$3" key_var="$4" skip_var="$5"
    local ans detected_url="" input_url input_key

    echo ""
    echo "--- $app_label setup ---"
    read -r -p "Configure $app_label? [Y/n]: " ans
    if [[ "${ans:-Y}" =~ ^[Nn] ]]; then
        printf -v "$skip_var" "true"
        return 0
    fi

    log "Looking for a local $app_label instance on port $default_port..."
    if probe_local_port "$default_port"; then
        detected_url="http://localhost:$default_port"
        log "  Found: $detected_url"
    else
        log "  Not detected automatically."
    fi

    if [[ -n "$detected_url" ]]; then
        read -r -p "$app_label URL [$detected_url]: " input_url
        printf -v "$url_var" "%s" "${input_url:-$detected_url}"
    else
        read -r -p "Enter the full $app_label URL (e.g. http://192.168.1.10:$default_port): " input_url
        printf -v "$url_var" "%s" "$input_url"
    fi

    read -r -s -p "$app_label API key: " input_key
    echo ""
    printf -v "$key_var" "%s" "$input_key"
}

# run_wizard -- interactive first-run setup. A no-op unless stdin and stdout
# are both a terminal and something an enabled app needs is missing.
run_wizard() {
    local need_radarr=false need_sonarr=false save_ans

    is_interactive || return 0

    if ! is_true "$SKIP_RADARR" && [[ -z "$RADARR_URL" || -z "$RADARR_API_KEY" ]]; then
        need_radarr=true
    fi
    if ! is_true "$SKIP_SONARR" && [[ -z "$SONARR_URL" || -z "$SONARR_API_KEY" ]]; then
        need_sonarr=true
    fi
    [[ "$need_radarr" == "true" || "$need_sonarr" == "true" ]] || return 0

    echo "No complete configuration found -- starting interactive setup."
    if [[ "$need_radarr" == "true" ]]; then
        prompt_app_config "Radarr" 7878 RADARR_URL RADARR_API_KEY SKIP_RADARR
    fi
    if [[ "$need_sonarr" == "true" ]]; then
        prompt_app_config "Sonarr" 8989 SONARR_URL SONARR_API_KEY SKIP_SONARR
    fi

    echo ""
    read -r -p "Save this configuration to $ENV_FILE for next time? [y/N]: " save_ans
    if [[ "${save_ans:-N}" =~ ^[Yy] ]]; then
        {
            echo "RADARR_URL=$RADARR_URL"
            echo "RADARR_API_KEY=$RADARR_API_KEY"
            echo "SKIP_RADARR=$SKIP_RADARR"
            echo ""
            echo "SONARR_URL=$SONARR_URL"
            echo "SONARR_API_KEY=$SONARR_API_KEY"
            echo "SKIP_SONARR=$SKIP_SONARR"
        } > "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        log "Configuration saved to $ENV_FILE (permissions restricted to your user)."
    fi
}

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

# wait_for_command <url> <key> <command> -- queue a RescanMovie/RescanSeries
# and poll /api/v3/command/<id> until it settles, so the app re-reads the
# files on disk instead of serving cached mediaInfo.
wait_for_command() {
    local base_url="$1" api_key="$2" command_name="$3"
    local cmd_id body status elapsed=0 interval=5

    if ! body=$(arr_post "$base_url/api/v3/command" "$api_key" \
        "{\"name\":\"$command_name\"}"); then
        warn "failed to trigger $command_name."
        return 1
    fi
    cmd_id=$(printf '%s' "$body" | jq -r '.id // empty' | tr -d '\r')
    if [[ -z "$cmd_id" ]]; then
        warn "failed to trigger $command_name."
        return 1
    fi

    log "  Triggered $command_name (command id $cmd_id), waiting for completion..."

    while [[ "$elapsed" -lt "$RESCAN_TIMEOUT" ]]; do
        status=""
        if body=$(arr_get "$base_url/api/v3/command/$cmd_id" "$api_key" 1); then
            status=$(printf '%s' "$body" | jq -r '.status // empty' | tr -d '\r')
        fi
        if [[ "$status" == "completed" ]]; then
            log "  $command_name completed."
            return 0
        fi
        if [[ "$status" == "failed" ]]; then
            warn "$command_name reported status 'failed'."
            return 1
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    warn "$command_name did not complete within ${RESCAN_TIMEOUT}s, continuing anyway."
    return 1
}

# write_row <csv-line> -- the single place a report row is written. Task 8
# redirects CSV_TARGET at a temporary file so a failed run keeps the previous
# report; nothing else in this script touches the output.
write_row() {
    printf '%s\n' "$1" >> "$CSV_TARGET"
}

# record <csv-line> <log-line> -- write the row, echo the hit, count it.
record() {
    write_row "$1"
    printf '%s\n' "$2"
    found_count=$((found_count + 1))
}

# ---------------------------------------------------------------------------
# RADARR
# ---------------------------------------------------------------------------

scan_radarr() {
    local movies_json row hit

    if is_true "$FORCE_RESCAN"; then
        log "Forcing Radarr to rescan all movie files on disk..."
        wait_for_command "$RADARR_URL" "$RADARR_API_KEY" "RescanMovie" || true
    fi

    log "Scanning Radarr library..."

    if ! movies_json=$(arr_get "$RADARR_URL/api/v3/movie" "$RADARR_API_KEY"); then
        warn "Radarr scan failed (check URL/API key)."
        radarr_failed=true
        return 0
    fi

    if ! jq -r --arg re "$ITALIAN_REGEX" "$JQ_DEFS$JQ_RADARR" \
        <<< "$movies_json" > "$TMP_DIR/radarr.lines"; then
        warn "could not read the Radarr response."
        radarr_failed=true
        return 0
    fi

    while IFS="$US" read -r row hit; do
        [[ -n "$row" ]] || continue
        record "$row" "$hit"
    done < "$TMP_DIR/radarr.lines"
}

# ---------------------------------------------------------------------------
# SONARR
# ---------------------------------------------------------------------------

# load_sonarr_cache -- leave the effective cache (without __meta) in
# $CACHE_JSON_FILE. An absent, unreadable or foreign cache leaves "{}" there,
# which makes every series a miss.
load_sonarr_cache() {
    local payload

    printf '{}\n' > "$CACHE_JSON_FILE"

    if is_true "$REFRESH"; then
        return 0
    fi
    [[ -f "$SONARR_CACHE_FILE" ]] || return 0

    payload=$(jq -c --arg re "$ITALIAN_REGEX" "$JQ_CACHE_LOAD" \
        "$SONARR_CACHE_FILE" 2>/dev/null) || payload=""

    if [[ -z "$payload" ]]; then
        warn "Sonarr cache $SONARR_CACHE_FILE is unreadable, ignoring it."
        return 0
    fi
    if [[ "$payload" == '"FORMAT"' ]]; then
        warn "cache format changed, rebuilding"
        return 0
    fi

    printf '%s\n' "$payload" > "$CACHE_JSON_FILE"
    log "Loaded Sonarr cache: $SONARR_CACHE_FILE"
}

# ids_json <id>... -- a JSON array of the ids. They are validated as digits
# before they get here, so no escaping is involved.
ids_json() {
    local out="[" first=1 id
    for id in ${1+"$@"}; do
        if [[ "$first" -eq 1 ]]; then first=0; else out="$out,"; fi
        out="$out\"$id\""
    done
    printf '%s]\n' "$out"
}

# emit_cached_rows <series-id> -- re-emit the rows the cache holds for one
# series. The failure path only; the hit path reads them all in one pass.
emit_cached_rows() {
    local sid="$1" row
    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        write_row "$row"
        found_count=$((found_count + 1))
    done < <(jq -r --arg id "$sid" '.[$id].rows[]?' "$CACHE_JSON_FILE")
}

# carry_series <series-id> -- keep this series' previous cache entry.
carry_series() {
    printf '{"id":"%s"}\n' "$1" >> "$FRAG_FILE"
}

# scan_series <id> <title> <sig> <state> -- one uncached (or stale) series:
# one episode request, one jq to format it, one jq to build its cache entry.
scan_series() {
    local sid="$1" stitle="$2" ssig="$3" sstate="$4"
    local episodes_json epfile_json line f1 f2 f3

    if ! episodes_json=$(arr_get \
        "$SONARR_URL/api/v3/episode?seriesId=$sid&includeEpisodeFile=true" \
        "$SONARR_API_KEY"); then
        if [[ "$sstate" == "STALE" ]]; then
            warn "episode fetch failed for '$stitle'; keeping its previous cache entry."
            emit_cached_rows "$sid"
            carry_series "$sid"
        else
            warn "episode fetch failed for '$stitle'; skipping it this run."
        fi
        return 0
    fi

    if ! jq -r --arg re "$ITALIAN_REGEX" --arg title "$stitle" \
        "$JQ_DEFS$JQ_EPISODES" <<< "$episodes_json" > "$TMP_DIR/episodes.lines"; then
        warn "could not read the episode list for '$stitle'; skipping it this run."
        return 0
    fi

    : > "$TMP_DIR/series.rows"
    while IFS="$US" read -r f1 f2 f3; do
        if [[ "$f1" == "NEEDFILE" ]]; then
            # hasFile with no embedded episodeFile: one extra request, and an
            # empty object when even that fails, so the episode is still
            # reported instead of silently dropped.
            if ! epfile_json=$(arr_get \
                "$SONARR_URL/api/v3/episodefile/$f2" "$SONARR_API_KEY" 2); then
                epfile_json='{}'
            fi
            line=$(jq -r --arg re "$ITALIAN_REGEX" --arg title "$stitle" \
                --arg label "$f3" "$JQ_DEFS$JQ_EPISODEFILE" \
                <<< "$epfile_json") || line=""
            [[ -n "$line" ]] || continue
            f1="${line%%"$US"*}"
            f2="${line#*"$US"}"
        fi
        [[ -n "$f1" ]] || continue
        record "$f1" "$f2"
        printf '%s\n' "$f1" >> "$TMP_DIR/series.rows"
    done < "$TMP_DIR/episodes.lines"

    # An empty rows array is meaningful: "checked, nothing flagged".
    if ! jq -R -s -c --arg id "$sid" --arg sig "$ssig" "$JQ_CACHE_ENTRY" \
        < "$TMP_DIR/series.rows" >> "$FRAG_FILE"; then
        warn "could not record '$stitle' in the Sonarr cache."
    fi
}

scan_sonarr() {
    local series_json sid stitle ssig sstate row
    local i idx total reused
    local -a series_ids series_titles series_sigs series_states
    local -a hits hit_ids hit_rows

    if is_true "$FORCE_RESCAN"; then
        log "Forcing Sonarr to rescan all series files on disk..."
        wait_for_command "$SONARR_URL" "$SONARR_API_KEY" "RescanSeries" || true
    fi

    log "Scanning Sonarr library..."

    if ! series_json=$(arr_get "$SONARR_URL/api/v3/series" "$SONARR_API_KEY"); then
        warn "Sonarr scan failed (check URL/API key)."
        sonarr_failed=true
        return 0
    fi

    load_sonarr_cache

    if ! jq -r --slurpfile cache "$CACHE_JSON_FILE" "$JQ_DEFS$JQ_SERIES" \
        <<< "$series_json" > "$TMP_DIR/series.lines"; then
        warn "could not read the Sonarr series list."
        sonarr_failed=true
        return 0
    fi

    series_ids=(); series_titles=(); series_sigs=(); series_states=(); hits=()
    while IFS="$US" read -r sid stitle ssig sstate; do
        if [[ ! "$sid" =~ ^[0-9]+$ ]]; then
            warn "skipping a series with an unusable id."
            continue
        fi
        series_ids+=("$sid")
        series_titles+=("$stitle")
        series_sigs+=("$ssig")
        series_states+=("$sstate")
        if [[ "$sstate" == "HIT" ]]; then
            hits+=("$sid")
        fi
    done < "$TMP_DIR/series.lines"

    # Every cached row of every hit, in one pass over the cache. They come back
    # grouped in $hits order, which is series order, so a single index walks
    # them below.
    hit_ids=(); hit_rows=()
    if [[ ${#hits[@]} -gt 0 ]]; then
        if jq -r --argjson ids "$(ids_json ${hits[@]+"${hits[@]}"})" \
            "$JQ_DEFS$JQ_CACHED_ROWS" "$CACHE_JSON_FILE" \
            > "$TMP_DIR/cached.lines"; then
            while IFS="$US" read -r sid row; do
                [[ -n "$sid" ]] || continue
                hit_ids+=("$sid")
                hit_rows+=("$row")
            done < "$TMP_DIR/cached.lines"
        else
            warn "could not read the cached rows; re-fetching every series."
            i=0
            while [[ "$i" -lt "${#series_states[@]}" ]]; do
                series_states[$i]="STALE"
                i=$((i + 1))
            done
        fi
    fi

    : > "$FRAG_FILE"
    idx=0
    total=${#hit_ids[@]}
    i=0
    while [[ "$i" -lt "${#series_ids[@]}" ]]; do
        sid="${series_ids[$i]}"
        if [[ "${series_states[$i]}" == "HIT" ]]; then
            reused=0
            while [[ "$idx" -lt "$total" && "${hit_ids[$idx]}" == "$sid" ]]; do
                write_row "${hit_rows[$idx]}"
                found_count=$((found_count + 1))
                reused=$((reused + 1))
                idx=$((idx + 1))
            done
            log "  [cache] ${series_titles[$i]} unchanged (${series_sigs[$i]}); reused $reused flagged file(s)."
            carry_series "$sid"
        else
            scan_series "$sid" "${series_titles[$i]}" "${series_sigs[$i]}" \
                "${series_states[$i]}"
        fi
        i=$((i + 1))
    done

    # The whole cache in one pass over the fragments, through a temporary file
    # so an interrupted run cannot leave a truncated cache behind.
    if jq -s --slurpfile cache "$CACHE_JSON_FILE" --arg re "$ITALIAN_REGEX" \
        "$JQ_CACHE_MERGE" "$FRAG_FILE" > "$TMP_DIR/cache.new" &&
        mv -f "$TMP_DIR/cache.new" "$SONARR_CACHE_FILE"; then
        log "Sonarr cache updated: $SONARR_CACHE_FILE"
    else
        warn "could not write Sonarr cache to $SONARR_CACHE_FILE."
    fi
}

# ---------------------------------------------------------------------------
# SUMMARY
# ---------------------------------------------------------------------------

# report_summary -- rc 2 when an enabled app could not be listed.
report_summary() {
    local failed=""

    if [[ "$radarr_failed" == "true" ]]; then failed="Radarr"; fi
    if [[ "$sonarr_failed" == "true" ]]; then
        if [[ -n "$failed" ]]; then failed="$failed, Sonarr"; else failed="Sonarr"; fi
    fi

    log ""
    if [[ -n "$failed" ]]; then
        # Never "nothing was found": nothing was found *here*, and the part of
        # the library nobody reached is exactly the part nobody checked.
        log "Found $found_count file(s) without Italian audio in what was scanned."
        log "Results exported to $OUTPUT_CSV"
        log "scan incomplete: $failed unreachable"
        return 2
    fi

    if [[ "$found_count" -eq 0 ]]; then
        log "No files missing Italian audio were found."
        log "Results exported to $OUTPUT_CSV"
    else
        log "Found $found_count file(s) without Italian audio."
        log "Results exported to $OUTPUT_CSV"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

cleanup() {
    if [[ -n "${TMP_DIR:-}" ]]; then
        rm -rf "$TMP_DIR"
        TMP_DIR=""
    fi
    return 0
}

# on_signal <name> -- clean up and *stop*. A bare `trap cleanup INT` would
# delete the temporary directory and let the run carry on with nowhere left to
# write; the EXIT trap is cleared first so the removal is not attempted twice.
on_signal() {
    cleanup
    trap - EXIT
    case "${1:-TERM}" in
        INT) exit 130 ;;
        *)   exit 143 ;;
    esac
}

main() {
    local rc=0

    parse_args "$@"
    require jq curl
    load_config
    run_wizard
    apply_defaults

    if [[ ${#POSITIONAL[@]} -gt 0 ]]; then
        OUTPUT_CSV="${POSITIONAL[0]}"
    else
        OUTPUT_CSV="$ALA_PHASE1_CSV"
    fi
    mkdir -p "$(dirname -- "$OUTPUT_CSV")"

    # The Sonarr per-series cache lives next to the report: a signature
    # (episode file count + size on disk, straight from Sonarr's own
    # statistics) and the rows that series produced last time.
    SONARR_CACHE_FILE="${OUTPUT_CSV%.csv}.cache.json"

    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ala-scan.XXXXXX")"
    trap cleanup EXIT
    trap 'on_signal INT' INT
    trap 'on_signal TERM' TERM
    CACHE_JSON_FILE="$TMP_DIR/cache.json"
    FRAG_FILE="$TMP_DIR/cache-fragments.jsonl"

    # Zero findings still leaves a report: a header-only CSV says "this ran and
    # found nothing", where a missing file says nothing at all.
    CSV_TARGET="$OUTPUT_CSV"
    printf '%s\n' "$CSV_HEADER" > "$CSV_TARGET"

    found_count=0
    radarr_failed=false
    sonarr_failed=false

    if ! is_true "$SKIP_RADARR"; then
        scan_radarr
    fi
    if ! is_true "$SKIP_SONARR"; then
        scan_sonarr
    fi

    report_summary || rc=$?
    return "$rc"
}

# `main "$@"` and nothing else: putting it on the left of a `||` would place
# the whole run inside a tested command, and errexit is disabled there -- a
# failed mkdir or a report that cannot be written would be reported as a clean
# run. The script's exit status is main's either way.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

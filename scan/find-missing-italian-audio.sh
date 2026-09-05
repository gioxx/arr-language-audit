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
# The report is written to "<OUTPUT_CSV>.tmp.<pid>" and moved into place only
# by a run that completed. A run that could not list an enabled app, or that
# was interrupted, therefore leaves the previous report exactly as it was: a
# half-scanned library must never overwrite a good report.
#
# Environment variables (also read from a .env file, see usage()):
#   RADARR_URL RADARR_API_KEY SKIP_RADARR
#   SONARR_URL SONARR_API_KEY SKIP_SONARR
#   FORCE_RESCAN RESCAN_TIMEOUT RESCAN_POLL_INTERVAL REFRESH
#
# Exit codes:
#   0   completed (with or without findings); the report was replaced
#   1   missing dependency (jq / curl) or bad arguments
#   2   an enabled app could not be listed; any previous report is untouched

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

# What the wizard accepts. A base URL with a space in it is not a typo the
# operator can be talked out of later: curl would reject it on every run, so it
# is refused at the prompt. An API key is what both apps generate -- letters and
# digits -- and anything else is a paste that picked up quotes or whitespace.
WIZARD_URL_REGEX='^https?://[^[:space:]]+$'
WIZARD_KEY_REGEX='^[A-Za-z0-9]+$'

# The keys the wizard may write, and the only lines it writes.
WIZARD_ENV_KEYS="RADARR_URL RADARR_API_KEY SKIP_RADARR \
SONARR_URL SONARR_API_KEY SKIP_SONARR"

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
  RESCAN_TIMEOUT      seconds to wait for a rescan to finish. A rescan that
                      reports failed, aborted, cancelled or orphaned is not
                      waited out; the scan warns and carries on
                                                              (default: 900)
  RESCAN_POLL_INTERVAL
                      seconds between two rescan status polls (default: 5)
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
The current working directory is deliberately not searched -- running the
audit from a directory someone else can write must not change what it does.
ALA_DOTENV_FILE, when set and non-empty, replaces that search with the file it
names, and reports "no .env" rather than falling back if that file is absent.

A value already in the environment wins over the file, the file wins over the
defaults above, and --refresh wins over both. Format is KEY=value, one per
line. See .env.example in the repo root.

On first interactive run with no config, a wizard auto-detects local
Radarr/Sonarr via the unauthenticated /ping endpoint and can save a .env with
permissions 600. ARR_ASSUME_TTY=1 runs it without a terminal; ARR_LOCALHOST
(default "localhost") is the host the /ping probe tries.

Exit codes:
  0   completed (with or without findings). The report is built in
      "<OUTPUT_CSV>.tmp.<pid>" and moved into place here, so a reader never
      sees a partial file. Being a rename, it gives the report a new file's
      permissions rather than those of the one it replaces.
  1   missing dependency (jq / curl) or bad arguments.
  2   an enabled app could not be listed after retries. The temporary file is
      discarded, so a previous report survives untouched rather than being
      replaced by a half-scanned one; with no previous report, none is
      written. The findings that were made are still on stdout.
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
    RESCAN_TIMEOUT="${RESCAN_TIMEOUT:-900}"
    RESCAN_POLL_INTERVAL="${RESCAN_POLL_INTERVAL:-5}"
    REFRESH="${REFRESH:-false}"

    # Both are used in arithmetic and one of them bounds a loop: a value that
    # is not a number, or a zero interval, would spin forever.
    if [[ ! "$RESCAN_TIMEOUT" =~ ^[0-9]+$ ]]; then
        warn "RESCAN_TIMEOUT is not a whole number of seconds; using 900."
        RESCAN_TIMEOUT=900
    fi
    if [[ ! "$RESCAN_POLL_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
        warn "RESCAN_POLL_INTERVAL must be at least 1 second; using 5."
        RESCAN_POLL_INTERVAL=5
    fi

    if [[ "$REFRESH_FLAG" == "true" ]]; then
        REFRESH=true
    fi
    # A rescan can change a file's tags without changing the file count or the
    # size on disk, so the signature would still match and the cache would hide
    # the very thing the rescan was asked for.
    if is_true "$FORCE_RESCAN"; then
        REFRESH=true
        log "FORCE_RESCAN implies --refresh"
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

# is_interactive -- may the wizard prompt? A terminal on both ends, or an
# explicit ARR_ASSUME_TTY=1 for a caller that drives the prompts itself.
is_interactive() {
    [[ "${ARR_ASSUME_TTY:-}" == "1" ]] && return 0
    [[ -t 0 && -t 1 ]]
}

# The unauthenticated /ping endpoint both apps expose: a local instance can be
# detected without an API key. ARR_LOCALHOST is what "local" means, so a test
# can point the probe somewhere that is not the developer's own Radarr.
probe_local_port() {
    local port="$1"
    curl -sf -m 2 "http://${ARR_LOCALHOST:-localhost}:$port/ping" 2>/dev/null |
        grep -q '"status"[[:space:]]*:[[:space:]]*"OK"'
}

# ask <out-var> <prompt> <regex> <default> <secret> <hint> -- read one value,
# validate it, and re-prompt exactly once before giving up with rc 1. One
# retry, not a loop: a scripted stdin that keeps answering wrongly must end,
# and a human who has typed the same mistake twice wants to go and look it up.
ask() {
    local out_var="$1" prompt="$2" regex="$3" default="$4" secret="$5" hint="$6"
    local attempt=1 value

    while [[ "$attempt" -le 2 ]]; do
        value=""
        # "|| true", never "|| value=\"\"": read returns 1 at end of input, but
        # it has already assigned what it read. A scripted stdin whose last
        # answer has no trailing newline is still an answer, and discarding it
        # here would silently turn it into the empty string.
        if [[ -n "$secret" ]]; then
            # The prompt goes to stderr on its own: -s means the answer never
            # reaches the terminal, so nothing closes the line.
            read -r -s -p "$prompt" value || true
            echo "" >&2
        else
            read -r -p "$prompt" value || true
        fi
        [[ -n "$value" ]] || value="$default"
        if [[ "$value" =~ $regex ]]; then
            printf -v "$out_var" '%s' "$value"
            return 0
        fi
        # The value itself is never echoed back: one of the two this function
        # asks for is an API key.
        warn "$hint"
        attempt=$((attempt + 1))
    done
    return 1
}

# prompt_app_config <label> <port> <url-var> <key-var> <skip-var> -- fills the
# named variables in for one app. rc 1 when a value was rejected twice, which
# is what abandons the save.
prompt_app_config() {
    local app_label="$1" default_port="$2" url_var="$3" key_var="$4" skip_var="$5"
    local ans detected_url="" url_prompt url_value key_value

    log ""
    log "--- $app_label setup ---"
    read -r -p "Configure $app_label? [Y/n]: " ans || true
    if [[ "${ans:-Y}" =~ ^[Nn] ]]; then
        printf -v "$skip_var" "true"
        return 0
    fi

    log "Looking for a local $app_label instance on port $default_port..."
    if probe_local_port "$default_port"; then
        detected_url="http://${ARR_LOCALHOST:-localhost}:$default_port"
        log "  Found: $detected_url"
    else
        log "  Not detected automatically."
    fi

    if [[ -n "$detected_url" ]]; then
        url_prompt="$app_label URL [$detected_url]: "
    else
        url_prompt="Enter the full $app_label URL (e.g. http://192.168.1.10:$default_port): "
    fi
    ask url_value "$url_prompt" "$WIZARD_URL_REGEX" "$detected_url" "" \
        "not a usable URL: it must start with http:// or https:// and hold no spaces." ||
        return 1
    printf -v "$url_var" '%s' "$(normalize_url "$url_value")"

    ask key_value "$app_label API key: " "$WIZARD_KEY_REGEX" "" secret \
        "not a usable API key: letters and digits only, and it may not be empty." ||
        return 1
    printf -v "$key_var" '%s' "$key_value"
}

# write_env_file -- the allow-listed keys, one KEY=value per line.
#
# The redirection is INSIDE the subshell, after the umask: "( ... ) > file"
# opens the file before the umask runs and the key would exist world-readable
# for as long as the write takes. The chmod after it covers the other case --
# ">" keeps an existing file's mode, which umask has no say over.
write_env_file() {
    local key
    (
        umask 077
        {
            for key in $WIZARD_ENV_KEYS; do
                printf '%s=%s\n' "$key" "${!key:-}"
            done
        } > "$ENV_FILE"
    )
    chmod 600 "$ENV_FILE"
}

# run_wizard -- interactive first-run setup. A no-op unless the session is
# interactive and something an enabled app needs is missing.
run_wizard() {
    local need_radarr=false need_sonarr=false save_ans ok=true

    is_interactive || return 0

    if ! is_true "$SKIP_RADARR" && [[ -z "$RADARR_URL" || -z "$RADARR_API_KEY" ]]; then
        need_radarr=true
    fi
    if ! is_true "$SKIP_SONARR" && [[ -z "$SONARR_URL" || -z "$SONARR_API_KEY" ]]; then
        need_sonarr=true
    fi
    [[ "$need_radarr" == "true" || "$need_sonarr" == "true" ]] || return 0

    log "No complete configuration found -- starting interactive setup."
    if [[ "$need_radarr" == "true" ]]; then
        prompt_app_config "Radarr" 7878 RADARR_URL RADARR_API_KEY SKIP_RADARR ||
            ok=false
    fi
    if [[ "$ok" == "true" && "$need_sonarr" == "true" ]]; then
        prompt_app_config "Sonarr" 8989 SONARR_URL SONARR_API_KEY SKIP_SONARR ||
            ok=false
    fi

    # A rejected value stops the save, not the run: the scan goes on and fails
    # its own API call, which says more than a .env full of something that
    # cannot work.
    if [[ "$ok" != "true" ]]; then
        warn "configuration not saved: a value was rejected twice."
        return 0
    fi

    log ""
    read -r -p "Save this configuration to $ENV_FILE for next time? [y/N]: " save_ans ||
        true
    if [[ "${save_ans:-N}" =~ ^[Yy] ]]; then
        write_env_file
        log "Configuration saved to $ENV_FILE (permissions restricted to your user)."
    fi
}

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

# wait_for_command <url> <key> <command> -- queue a RescanMovie/RescanSeries
# and poll /api/v3/command/<id> until it settles, so the app re-reads the
# files on disk instead of serving cached mediaInfo.
#
# Each poll is a single attempt (arr_get ... 1): retrying a status read three
# times inside a loop that is already a retry only makes the timeout mean
# three different things, and -m still bounds each one.
#
# rc 0 only for "completed". Every other terminal state, and the timeout, warn
# and return 1: the caller carries on with whatever mediaInfo the app has, on
# the grounds that a stale tag is still worth reporting.
wait_for_command() {
    local base_url="$1" api_key="$2" command_name="$3"
    local cmd_id body request status elapsed=0
    local interval="${RESCAN_POLL_INTERVAL:-5}"

    # jq builds the body rather than string interpolation. Every caller passes
    # a literal today, so nothing is broken; a helper that produces JSON should
    # not be one careless argument away from producing something else.
    request=$(jq -n -c --arg name "$command_name" '{name: $name}')

    if ! body=$(arr_post "$base_url/api/v3/command" "$api_key" "$request"); then
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
        case "$status" in
            completed)
                log "  $command_name completed."
                return 0
                ;;
            failed | aborted | cancelled | orphaned)
                # Terminal, and it will not become "completed" by waiting:
                # polling on to the timeout would cost RESCAN_TIMEOUT seconds
                # to learn what this poll already said.
                warn "$command_name reported status '$status'."
                return 1
                ;;
        esac
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

# failed_apps -- the enabled apps whose list fetch failed, "" if none. The
# order is fixed so the message does not depend on which one failed first.
failed_apps() {
    local failed=""

    if [[ "$radarr_failed" == "true" ]]; then failed="Radarr"; fi
    if [[ "$sonarr_failed" == "true" ]]; then
        if [[ -n "$failed" ]]; then failed="$failed, Sonarr"; else failed="Sonarr"; fi
    fi
    printf '%s\n' "$failed"
}

# report_summary <failed-apps> <kept-previous> -- the closing lines. main owns
# the exit code and the file, this only says what happened.
report_summary() {
    local failed="$1" kept="$2"

    log ""
    if [[ -n "$failed" ]]; then
        # Never "nothing was found": nothing was found *here*, and the part of
        # the library nobody reached is exactly the part nobody checked. The
        # rows are on stdout; they are deliberately not on disk, because a
        # half-scanned library replacing a complete report is a silent
        # regression in the report nobody would notice.
        log "Found $found_count file(s) without Italian audio in what was scanned."
        if [[ "$kept" == "true" ]]; then
            log "scan incomplete: $failed unreachable; previous report kept"
        else
            log "scan incomplete: $failed unreachable; no report written"
        fi
        return 0
    fi

    if [[ "$found_count" -eq 0 ]]; then
        log "No files missing Italian audio were found."
    else
        log "Found $found_count file(s) without Italian audio."
    fi
    log "Results exported to $OUTPUT_CSV"
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
    # The half-written report. main clears OUT_TMP once it has moved it into
    # place, so a completed run has nothing here to remove.
    if [[ -n "${OUT_TMP:-}" ]]; then
        rm -f -- "$OUT_TMP"
        OUT_TMP=""
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
    local rc=0 failed kept=false

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

    # Was there a report before this run? It decides what an incomplete run
    # has to say for itself, and it is read before anything is written.
    if [[ -f "$OUTPUT_CSV" ]]; then
        kept=true
    fi

    # The report is built beside its destination -- same directory, so the move
    # is a rename and never a copy across filesystems -- and moved into place
    # only by a run that completed. A reader therefore sees either the previous
    # report or the new one, never half of either.
    OUT_TMP="$OUTPUT_CSV.tmp.$$"

    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ala-scan.XXXXXX")"
    trap cleanup EXIT
    trap 'on_signal INT' INT
    trap 'on_signal TERM' TERM
    CACHE_JSON_FILE="$TMP_DIR/cache.json"
    FRAG_FILE="$TMP_DIR/cache-fragments.jsonl"

    # Zero findings still leaves a report: a header-only CSV says "this ran and
    # found nothing", where a missing file says nothing at all.
    CSV_TARGET="$OUT_TMP"
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

    failed="$(failed_apps)"
    if [[ -n "$failed" ]]; then
        rm -f -- "$OUT_TMP"
        rc=2
    else
        # "--": OUTPUT_CSV comes from the command line and may start with a
        # dash. Both paths are in the same directory, so this is atomic.
        mv -f -- "$OUT_TMP" "$OUTPUT_CSV"
    fi
    OUT_TMP=""

    report_summary "$failed" "$kept"
    return "$rc"
}

# `main "$@"` and nothing else: putting it on the left of a `||` would place
# the whole run inside a tested command, and errexit is disabled there -- a
# failed mkdir or a report that cannot be written would be reported as a clean
# run. The script's exit status is main's either way.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

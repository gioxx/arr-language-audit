#!/usr/bin/env bash
#
# Phase 1 of arr-language-audit.
#
# Scans Radarr and Sonarr libraries for media files that do NOT have an
# Italian audio track, using the mediaInfo already computed by the *arr
# apps. Nothing on disk is touched: the only output is a CSV report.
#
# Requirements: bash, curl, jq
#
# Usage:
#   ./scan/find-missing-italian-audio.sh [OUTPUT_CSV] [--refresh]
#
#   OUTPUT_CSV   where to write the report
#                (default: <repo>/reports/missing-italian-audio.csv)
#   --refresh    ignore the Sonarr per-series cache and re-fetch everything
#
# Sonarr is queried once per series (episodes with their file embedded), and
# a small cache file next to OUTPUT_CSV (<name>.cache.json) lets unchanged
# series be skipped on the next run. Radarr is a single request and is not
# cached. See "Sonarr cache" note near SONARR_CACHE_FILE below.
#
# On first run (interactive terminal, no saved config found), a setup
# wizard walks you through configuring Radarr/Sonarr: it auto-detects a
# locally running instance on the default port (7878 / 8989) via the
# unauthenticated /ping endpoint, and only asks for the API key in that
# case. If nothing is detected locally, it asks for the full URL instead.
# You can always type a different URL when prompted, even if one was
# auto-detected. At the end it offers to save your answers to a .env
# file in the repo root, so future runs skip the wizard entirely.
#
# Non-interactive runs (cron, CI, piped input) skip the wizard and rely
# purely on environment variables / an existing .env file.
#
# Environment variables (also read from a .env file, see below):
#   RADARR_URL          Radarr base URL          (default: http://localhost:7878)
#   RADARR_API_KEY      Radarr API key
#   SONARR_URL          Sonarr base URL          (default: http://localhost:8989)
#   SONARR_API_KEY      Sonarr API key
#   SKIP_RADARR         true to skip Radarr entirely            (default: false)
#   SKIP_SONARR         true to skip Sonarr entirely            (default: false)
#   FORCE_RESCAN        true to make Radarr/Sonarr re-read every file on disk
#                       (RescanMovie / RescanSeries) BEFORE reading mediaInfo.
#                       Fixes stale/cached data, slower on large libraries.
#                                                               (default: false)
#   RESCAN_TIMEOUT      seconds to wait for a rescan command to finish
#                                                               (default: 300)
#   REFRESH             true to ignore the Sonarr per-series cache and
#                       re-fetch every series (same as --refresh)  (default: false)
#
# .env file: looked up (in order) in scan/, the repo root, and the current
# working directory. Format is KEY=value, one per line, no quotes, no
# spaces around '='. See .env.example in the repo root.
#
# Exit codes:
#   0   completed (with or without findings)
#   1   missing dependency (jq / curl) or bad arguments

set -euo pipefail

# ---------------------------------------------------------------------------
# OUTPUT HELPERS
# ---------------------------------------------------------------------------
# All diagnostics go to stderr so stdout stays reserved for the per-file
# "hit" lines. No emoji, consistent prefixes across the toolkit.
log()  { echo "$@" >&2; }
warn() { echo "WARN: $*" >&2; }
err()  { echo "ERROR: $*" >&2; }

# jq wrapper for extracting scalar values / line lists: strips carriage
# returns so results are clean everywhere (jq on Windows emits CRLF, which
# otherwise sneaks a \r onto ids, paths, signatures, etc.). Use plain `jq`
# for JSON-in/JSON-out steps where the CR sits harmlessly in whitespace.
jqr() { jq "$@" | tr -d '\r'; }

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
                      The file is deleted again if there are zero findings.

Options:
  --refresh          ignore the Sonarr per-series cache and re-fetch every
                     series (same as REFRESH=true)

Environment variables (also read from a .env file, see below):
  RADARR_URL          Radarr base URL          (default: http://localhost:7878)
  RADARR_API_KEY      Radarr API key
  SONARR_URL          Sonarr base URL          (default: http://localhost:8989)
  SONARR_API_KEY      Sonarr API key
  SKIP_RADARR         true to skip Radarr entirely            (default: false)
  SKIP_SONARR         true to skip Sonarr entirely            (default: false)
  FORCE_RESCAN        true to run RescanMovie / RescanSeries before reading
                      mediaInfo, so stale cached tags are refreshed from disk
                                                              (default: false)
  RESCAN_TIMEOUT      seconds to wait for a rescan to finish  (default: 300)
  REFRESH            true to ignore the Sonarr per-series cache (default: false)

Sonarr is fetched once per series (episodes with the file embedded). A
cache file next to OUTPUT_CSV (<name>.cache.json) records a per-series
signature (file count + size on disk); an unchanged series is not
re-fetched on the next run. Radarr is one request and is not cached.

.env file: looked up in order in scan/, the repo root, then the current
directory; first match wins. Format is KEY=value, one per line, no quotes,
no spaces around '='. See .env.example in the repo root.

On first interactive run with no config, a wizard auto-detects local
Radarr/Sonarr via the unauthenticated /ping endpoint and can save a .env.

Exit codes:
  0   completed (with or without findings)
  1   missing dependency (jq / curl) or bad arguments
EOF
}

# Parse CLI: an optional OUTPUT_CSV positional plus a few flags. The
# --refresh flag is remembered here and applied after the .env file is
# loaded, so an explicit flag always wins over an env/.env value.
_refresh_flag=false
_positional=()
while (( $# )); do
    case "$1" in
        -h|--help)  usage; exit 0 ;;
        --refresh)  _refresh_flag=true; shift ;;
        --)         shift; while (( $# )); do _positional+=("$1"); shift; done ;;
        -*)         err "unknown option: $1"; echo "Try --help." >&2; exit 1 ;;
        *)          _positional+=("$1"); shift ;;
    esac
done
set -- "${_positional[@]+"${_positional[@]}"}"

# ---------------------------------------------------------------------------
# CONFIG / .env LOADING
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." &> /dev/null && pwd)"

# Look for a .env in (in order): the script's own dir, the repo root, the
# current working directory. First match wins. If none exists, the setup
# wizard will offer to create one in the repo root.
ENV_FILE=""
for candidate in "$SCRIPT_DIR/.env" "$REPO_ROOT/.env" "./.env"; do
    if [[ -f "$candidate" ]]; then
        ENV_FILE="$candidate"
        break
    fi
done
if [[ -n "$ENV_FILE" ]]; then
    set -a  # auto-export everything sourced below
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi
# Default target for the wizard's "save" step when no .env was found.
: "${ENV_FILE:=$REPO_ROOT/.env}"

RADARR_URL="${RADARR_URL:-}"
RADARR_API_KEY="${RADARR_API_KEY:-}"
SONARR_URL="${SONARR_URL:-}"
SONARR_API_KEY="${SONARR_API_KEY:-}"

SKIP_RADARR="${SKIP_RADARR:-false}"
SKIP_SONARR="${SKIP_SONARR:-false}"
FORCE_RESCAN="${FORCE_RESCAN:-false}"
RESCAN_TIMEOUT="${RESCAN_TIMEOUT:-300}"  # seconds to wait for a rescan command

# REFRESH may come from the environment or the .env file; the --refresh CLI
# flag (parsed above) overrides it. When true, the Sonarr per-series cache
# is ignored and every series is re-fetched.
REFRESH="${REFRESH:-false}"
[[ "$_refresh_flag" == "true" ]] && REFRESH=true

# Output CSV. Defaults to <repo>/reports/ (not the current directory) so that
# phase 2 and the HTML report all read/write the same place no matter which
# directory a script is launched from. An explicit path argument still wins.
OUTPUT_CSV="${1:-$REPO_ROOT/reports/missing-italian-audio.csv}"
mkdir -p "$(dirname -- "$OUTPUT_CSV")"

# Sonarr per-series cache lives next to the output CSV. It records, per
# series, a signature (episode file count + total size on disk as reported
# by Sonarr) and the CSV rows that series produced. On the next run, a
# series whose signature is unchanged is not re-fetched: its cached rows
# are re-emitted as-is. Use --refresh (or REFRESH=true) to force a full
# re-scan. Radarr needs no cache -- /api/v3/movie already embeds movieFile.
SONARR_CACHE_FILE="${OUTPUT_CSV%.csv}.cache.json"

# Matches "Italian audio present" in the audioLanguages field (covers
# "Italian", "ita", "it-IT"). Plain POSIX ERE, used with `grep -iE`, so it
# works with both GNU grep and the BSD grep on macOS (which has no -P);
# case-insensitivity comes from grep -i.
ITALIAN_REGEX='italian|ita|it-it'

command -v jq   >/dev/null 2>&1 || { err "jq is required but not installed.";   exit 1; }
command -v curl >/dev/null 2>&1 || { err "curl is required but not installed."; exit 1; }

# ---------------------------------------------------------------------------
# SETUP WIZARD
# ---------------------------------------------------------------------------

is_interactive() { [[ -t 0 && -t 1 ]]; }

# Checks the unauthenticated /ping endpoint that both Radarr and Sonarr
# expose, to detect a locally running instance without needing an API key.
probe_local_port() {
    local port="$1"
    curl -sf -m 2 "http://localhost:$port/ping" 2>/dev/null | grep -q '"status"[[:space:]]*:[[:space:]]*"OK"'
}

# Interactively fills in url_var/key_var/skip_var (passed by name) for one
# app, auto-detecting a local instance when possible. Leaves already-set
# values untouched.
prompt_app_config() {
    local app_label="$1" default_port="$2" url_var="$3" key_var="$4" skip_var="$5"

    echo ""
    echo "--- $app_label setup ---"
    read -r -p "Configure $app_label? [Y/n]: " ans
    if [[ "${ans:-Y}" =~ ^[Nn] ]]; then
        printf -v "$skip_var" "true"
        return
    fi

    local detected_url=""
    log "Looking for a local $app_label instance on port $default_port..."
    if probe_local_port "$default_port"; then
        detected_url="http://localhost:$default_port"
        log "  Found: $detected_url"
    else
        log "  Not detected automatically."
    fi

    local input_url
    if [[ -n "$detected_url" ]]; then
        read -r -p "$app_label URL [$detected_url]: " input_url
        printf -v "$url_var" "%s" "${input_url:-$detected_url}"
    else
        read -r -p "Enter the full $app_label URL (e.g. http://192.168.1.10:$default_port): " input_url
        printf -v "$url_var" "%s" "$input_url"
    fi

    local input_key
    read -r -s -p "$app_label API key: " input_key
    echo ""
    printf -v "$key_var" "%s" "$input_key"
}

if is_interactive; then
    need_radarr_wizard=false
    need_sonarr_wizard=false
    [[ "$SKIP_RADARR" != "true" && ( -z "$RADARR_URL" || -z "$RADARR_API_KEY" ) ]] && need_radarr_wizard=true
    [[ "$SKIP_SONARR" != "true" && ( -z "$SONARR_URL" || -z "$SONARR_API_KEY" ) ]] && need_sonarr_wizard=true

    if [[ "$need_radarr_wizard" == "true" || "$need_sonarr_wizard" == "true" ]]; then
        echo "No complete configuration found -- starting interactive setup."
        [[ "$need_radarr_wizard" == "true" ]] && prompt_app_config "Radarr" 7878 RADARR_URL RADARR_API_KEY SKIP_RADARR
        [[ "$need_sonarr_wizard" == "true" ]] && prompt_app_config "Sonarr" 8989 SONARR_URL SONARR_API_KEY SKIP_SONARR

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
    fi
fi

# Fallback defaults for anything still unset (non-interactive runs, an app
# left unconfigured, etc.). Placeholder values will simply fail the API
# calls below and be reported as warnings.
RADARR_URL="${RADARR_URL:-http://localhost:7878}"
RADARR_API_KEY="${RADARR_API_KEY:-YOUR_RADARR_API_KEY}"
SONARR_URL="${SONARR_URL:-http://localhost:8989}"
SONARR_API_KEY="${SONARR_API_KEY:-YOUR_SONARR_API_KEY}"

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

# Triggers a Radarr/Sonarr command (e.g. RescanMovie / RescanSeries) and waits
# for it to complete, polling /api/v3/command/{id}. This forces the app to
# re-read the actual file on disk instead of relying on cached mediaInfo.
wait_for_command() {
    local base_url="$1"
    local api_key="$2"
    local command_name="$3"

    local cmd_id
    cmd_id=$(curl -sf -X POST -H "X-Api-Key: $api_key" -H "Content-Type: application/json" \
        -d "{\"name\":\"$command_name\"}" \
        "$base_url/api/v3/command" | jqr -r '.id // empty')

    if [[ -z "$cmd_id" ]]; then
        warn "failed to trigger $command_name."
        return 1
    fi

    log "  Triggered $command_name (command id $cmd_id), waiting for completion..."

    local elapsed=0
    local interval=5
    while (( elapsed < RESCAN_TIMEOUT )); do
        local status
        status=$(curl -sf -H "X-Api-Key: $api_key" "$base_url/api/v3/command/$cmd_id" | jqr -r '.status // empty')

        if [[ "$status" == "completed" ]]; then
            log "  $command_name completed."
            return 0
        elif [[ "$status" == "failed" ]]; then
            warn "$command_name reported status 'failed'."
            return 1
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    warn "$command_name did not complete within ${RESCAN_TIMEOUT}s, continuing anyway."
    return 1
}

# GET an *arr API URL, retrying a few times on transient curl failures
# (a connection reset on a busy instance, a brief network blip). Echoes the
# response body on success; returns non-zero once the last attempt fails.
api_get() {
    local url="$1" api_key="$2" tries="${3:-3}"
    local attempt=1 body
    while (( attempt <= tries )); do
        if body=$(curl -sf -m 120 -H "X-Api-Key: $api_key" "$url"); then
            printf '%s' "$body"
            return 0
        fi
        (( attempt < tries )) && sleep 2
        attempt=$((attempt + 1))
    done
    return 1
}

# Append the CSV rows a Sonarr series produced on a previous run (read from
# the cache) to the output, bumping found_count. Sets _reused to the count.
# Not run in a subshell, so the found_count update sticks.
emit_cached_rows() {
    local sid="$1" row
    _reused=0
    while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        echo "$row" >> "$OUTPUT_CSV"
        found_count=$((found_count + 1))
        _reused=$((_reused + 1))
    done < <(jqr -r --arg id "$sid" '.[$id].rows[]?' <<< "$sonarr_cache_json")
}

# Copy a series' previous cache entry (sig + rows) into the cache being rebuilt.
carry_cache_entry() {
    local sid="$1" entry
    entry=$(jq -c --arg id "$sid" '.[$id]' <<< "$sonarr_cache_json")
    sonarr_new_cache=$(jq -c --arg id "$sid" --argjson entry "$entry" \
        '.[$id] = $entry' <<< "$sonarr_new_cache")
}

# CSV header
echo "App,Title,Year,Episode,AudioLanguages,Path" > "$OUTPUT_CSV"

found_count=0

# ---------------------------------------------------------------------------
# RADARR (movies)
# ---------------------------------------------------------------------------
if [[ "$SKIP_RADARR" != "true" ]]; then
    if [[ "$FORCE_RESCAN" == "true" ]]; then
        log "Forcing Radarr to rescan all movie files on disk..."
        wait_for_command "$RADARR_URL" "$RADARR_API_KEY" "RescanMovie" || true
    fi

    log "Scanning Radarr library..."

    movies_json=$(api_get "$RADARR_URL/api/v3/movie" "$RADARR_API_KEY") || {
        warn "Radarr scan failed (check URL/API key)."
        movies_json="[]"
    }

    # Iterate movies that have a file, extract title/year/audioLanguages/path.
    while IFS=$'\t' read -r title year audioLangs path; do
        [[ -z "$title" ]] && continue

        if ! grep -qiE "$ITALIAN_REGEX" <<< "$audioLangs"; then
            found_count=$((found_count + 1))
            # Escape double quotes for CSV.
            title_csv=$(sed 's/"/""/g' <<< "$title")
            path_csv=$(sed 's/"/""/g' <<< "$path")
            echo "Radarr,\"$title_csv\",$year,,\"$audioLangs\",\"$path_csv\"" >> "$OUTPUT_CSV"
            echo "[Radarr] $title ($year) -> audio: ${audioLangs:-<none>}"
        fi
    done < <(jqr -r '.[] | select(.hasFile == true) |
        [.title, .year, (.movieFile.mediaInfo.audioLanguages // ""), .movieFile.path] | @tsv' <<< "$movies_json")
fi

# ---------------------------------------------------------------------------
# SONARR (TV episodes)
# ---------------------------------------------------------------------------
if [[ "$SKIP_SONARR" != "true" ]]; then
    if [[ "$FORCE_RESCAN" == "true" ]]; then
        log "Forcing Sonarr to rescan all series files on disk..."
        wait_for_command "$SONARR_URL" "$SONARR_API_KEY" "RescanSeries" || true
    fi

    log "Scanning Sonarr library..."

    if series_json=$(api_get "$SONARR_URL/api/v3/series" "$SONARR_API_KEY"); then
        sonarr_fetch_ok=true
    else
        warn "Sonarr scan failed (check URL/API key)."
        series_json="[]"
        sonarr_fetch_ok=false
    fi

    # Load the previous cache (unless --refresh). A malformed file is ignored.
    if [[ "$REFRESH" == "true" ]]; then
        sonarr_cache_json='{}'
    elif [[ -f "$SONARR_CACHE_FILE" ]] && sonarr_cache_json=$(jq -e . "$SONARR_CACHE_FILE" 2>/dev/null); then
        log "Loaded Sonarr cache: $SONARR_CACHE_FILE"
    else
        [[ -f "$SONARR_CACHE_FILE" ]] && warn "Sonarr cache $SONARR_CACHE_FILE is unreadable, ignoring it."
        sonarr_cache_json='{}'
    fi
    sonarr_new_cache='{}'

    mapfile -t series_ids < <(jqr -r '.[].id' <<< "$series_json")

    for series_id in "${series_ids[@]+"${series_ids[@]}"}"; do
        series_title=$(jqr -r --arg id "$series_id" '.[] | select(.id == ($id | tonumber)) | .title' <<< "$series_json")

        # Signature = files on disk + their total size, straight from Sonarr's
        # own per-series statistics. If both are unchanged since last run, the
        # library almost certainly did not change and we can trust the cache.
        sig=$(jqr -r --arg id "$series_id" \
            '.[] | select(.id == ($id | tonumber)) |
             "\(.statistics.episodeFileCount // 0):\(.statistics.sizeOnDisk // 0)"' <<< "$series_json")
        cached_sig=$(jqr -r --arg id "$series_id" '.[$id].sig // empty' <<< "$sonarr_cache_json")

        if [[ "$REFRESH" != "true" && -n "$cached_sig" && "$cached_sig" == "$sig" ]]; then
            # Cache hit: re-emit the rows this series produced last time,
            # without fetching its episodes again.
            emit_cached_rows "$series_id"
            log "  [cache] $series_title unchanged ($sig); reused $_reused flagged file(s)."
            carry_cache_entry "$series_id"
            continue
        fi

        # Cache miss (or --refresh): one request for the whole series, with
        # the episode file embedded (includeEpisodeFile=true). This replaces
        # the old one-request-per-episode-file loop; the mediaInfo and path
        # come from the same EpisodeFileResource, so the result is identical.
        episodes_json=$(api_get "$SONARR_URL/api/v3/episode?seriesId=$series_id&includeEpisodeFile=true" "$SONARR_API_KEY") || {
            if [[ -n "$cached_sig" ]]; then
                warn "episode fetch failed for '$series_title'; keeping its previous cache entry."
                emit_cached_rows "$series_id"
                carry_cache_entry "$series_id"
            else
                warn "episode fetch failed for '$series_title'; skipping it this run."
            fi
            continue
        }

        series_rows=()
        while IFS=$'\t' read -r episodeFileId seasonNum epNum epTitle audioLangs path; do
            [[ -z "$episodeFileId" || "$episodeFileId" == "0" ]] && continue

            # Rare: an episode marked hasFile but with no embedded file object.
            # Fall back to the single-file endpoint just for this one.
            if [[ -z "$path" ]]; then
                epfile_json=$(api_get "$SONARR_URL/api/v3/episodefile/$episodeFileId" "$SONARR_API_KEY" 2) || epfile_json=""
                if [[ -n "$epfile_json" ]]; then
                    audioLangs=$(jqr -r '.mediaInfo.audioLanguages // ""' <<< "$epfile_json")
                    path=$(jqr -r '.path // ""' <<< "$epfile_json")
                fi
            fi

            if ! grep -qiE "$ITALIAN_REGEX" <<< "$audioLangs"; then
                found_count=$((found_count + 1))
                ep_label=$(printf "S%02dE%02d - %s" "$seasonNum" "$epNum" "$epTitle")
                title_csv=$(sed 's/"/""/g' <<< "$series_title")
                ep_csv=$(sed 's/"/""/g' <<< "$ep_label")
                path_csv=$(sed 's/"/""/g' <<< "$path")
                row="Sonarr,\"$title_csv\",,\"$ep_csv\",\"$audioLangs\",\"$path_csv\""
                echo "$row" >> "$OUTPUT_CSV"
                echo "[Sonarr] $series_title - $ep_label -> audio: ${audioLangs:-<none>}"
                series_rows+=("$row")
            fi
        done < <(jqr -r '.[] | select(.hasFile == true) |
            [.episodeFileId, .seasonNumber, .episodeNumber, .title,
             (.episodeFile.mediaInfo.audioLanguages // ""), (.episodeFile.path // "")] | @tsv' <<< "$episodes_json")

        # Record this series in the rebuilt cache (empty rows array is fine:
        # it means "checked, nothing flagged").
        if (( ${#series_rows[@]} > 0 )); then
            rows_json=$(printf '%s\n' "${series_rows[@]}" | jq -R . | jq -s .)
        else
            rows_json='[]'
        fi
        sonarr_new_cache=$(jq -c --arg id "$series_id" --arg sig "$sig" --argjson rows "$rows_json" \
            '.[$id] = {sig: $sig, rows: $rows}' <<< "$sonarr_new_cache")
    done

    # Persist the rebuilt cache, but only if the series list was actually
    # fetched -- otherwise a transient API failure would wipe a good cache.
    if [[ "$sonarr_fetch_ok" == "true" ]]; then
        if echo "$sonarr_new_cache" | jq . > "$SONARR_CACHE_FILE" 2>/dev/null; then
            log "Sonarr cache updated: $SONARR_CACHE_FILE"
        else
            warn "could not write Sonarr cache to $SONARR_CACHE_FILE."
        fi
    fi
fi

# ---------------------------------------------------------------------------
# SUMMARY
# ---------------------------------------------------------------------------
log ""
if [[ "$found_count" -eq 0 ]]; then
    log "No files missing Italian audio were found."
    rm -f "$OUTPUT_CSV"
else
    log "Found $found_count file(s) without Italian audio."
    log "Results exported to $OUTPUT_CSV"
fi

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
#   ./scan/find-missing-italian-audio.sh [OUTPUT_CSV]
#
#   OUTPUT_CSV   where to write the report (default: ./missing-italian-audio.csv,
#                relative to the current working directory)
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

usage() {
    cat <<'EOF'
Phase 1 of arr-language-audit -- find media files without an Italian audio tag.

Scans Radarr and Sonarr libraries via their APIs, reads the mediaInfo the
apps already computed for each downloaded file, and exports to CSV every
file whose audioLanguages tag is not explicitly Italian. Nothing on disk
is modified; the only output is the CSV report.

Usage:
  find-missing-italian-audio.sh [OUTPUT_CSV]
  find-missing-italian-audio.sh -h | --help

Arguments:
  OUTPUT_CSV          report path (default: ./missing-italian-audio.csv).
                      The file is deleted again if there are zero findings.

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

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

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

OUTPUT_CSV="${1:-./missing-italian-audio.csv}"

# Regex matching "Italian present" in the audioLanguages field
# (covers "Italian", "ita", "it-IT", case-insensitive).
ITALIAN_REGEX='(?i)(italian|ita|it-it)'

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
        "$base_url/api/v3/command" | jq -r '.id // empty')

    if [[ -z "$cmd_id" ]]; then
        warn "failed to trigger $command_name."
        return 1
    fi

    log "  Triggered $command_name (command id $cmd_id), waiting for completion..."

    local elapsed=0
    local interval=5
    while (( elapsed < RESCAN_TIMEOUT )); do
        local status
        status=$(curl -sf -H "X-Api-Key: $api_key" "$base_url/api/v3/command/$cmd_id" | jq -r '.status // empty')

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

    movies_json=$(curl -sf -H "X-Api-Key: $RADARR_API_KEY" "$RADARR_URL/api/v3/movie") || {
        warn "Radarr scan failed (check URL/API key)."
        movies_json="[]"
    }

    # Iterate movies that have a file, extract title/year/audioLanguages/path.
    while IFS=$'\t' read -r title year audioLangs path; do
        [[ -z "$title" ]] && continue

        if ! grep -qiP "$ITALIAN_REGEX" <<< "$audioLangs"; then
            found_count=$((found_count + 1))
            # Escape double quotes for CSV.
            title_csv=$(sed 's/"/""/g' <<< "$title")
            path_csv=$(sed 's/"/""/g' <<< "$path")
            echo "Radarr,\"$title_csv\",$year,,\"$audioLangs\",\"$path_csv\"" >> "$OUTPUT_CSV"
            echo "[Radarr] $title ($year) -> audio: ${audioLangs:-<none>}"
        fi
    done < <(jq -r '.[] | select(.hasFile == true) |
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

    series_json=$(curl -sf -H "X-Api-Key: $SONARR_API_KEY" "$SONARR_URL/api/v3/series") || {
        warn "Sonarr scan failed (check URL/API key)."
        series_json="[]"
    }

    series_ids=$(jq -r '.[].id' <<< "$series_json")

    for series_id in $series_ids; do
        series_title=$(jq -r --arg id "$series_id" '.[] | select(.id == ($id | tonumber)) | .title' <<< "$series_json")

        episodes_json=$(curl -sf -H "X-Api-Key: $SONARR_API_KEY" \
            "$SONARR_URL/api/v3/episode?seriesId=$series_id") || {
            warn "failed to fetch episodes for series '$series_title'."
            continue
        }

        # Get episodeFileId + season/episode/title for downloaded episodes only.
        while IFS=$'\t' read -r episodeFileId seasonNum epNum epTitle; do
            [[ -z "$episodeFileId" || "$episodeFileId" == "0" ]] && continue

            epfile_json=$(curl -sf -H "X-Api-Key: $SONARR_API_KEY" \
                "$SONARR_URL/api/v3/episodefile/$episodeFileId") || continue

            audioLangs=$(jq -r '.mediaInfo.audioLanguages // ""' <<< "$epfile_json")
            path=$(jq -r '.path // ""' <<< "$epfile_json")

            if ! grep -qiP "$ITALIAN_REGEX" <<< "$audioLangs"; then
                found_count=$((found_count + 1))
                ep_label=$(printf "S%02dE%02d - %s" "$seasonNum" "$epNum" "$epTitle")
                title_csv=$(sed 's/"/""/g' <<< "$series_title")
                ep_csv=$(sed 's/"/""/g' <<< "$ep_label")
                path_csv=$(sed 's/"/""/g' <<< "$path")
                echo "Sonarr,\"$title_csv\",,\"$ep_csv\",\"$audioLangs\",\"$path_csv\"" >> "$OUTPUT_CSV"
                echo "[Sonarr] $series_title - $ep_label -> audio: ${audioLangs:-<none>}"
            fi
        done < <(jq -r '.[] | select(.hasFile == true) |
            [.episodeFileId, .seasonNumber, .episodeNumber, .title] | @tsv' <<< "$episodes_json")
    done
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

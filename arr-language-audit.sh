#!/usr/bin/env bash
#
# arr-language-audit -- interactive orchestrator.
#
# A single entry point that drives the whole two-phase workflow:
#
#   phase 1  scan/find-missing-italian-audio.sh   (Radarr/Sonarr API -> CSV)
#   phase 2  verify/verify-audio-language.sh      (ffmpeg + faster-whisper -> CSV)
#   report   verify/report.py                     (CSV -> HTML, optional viewer)
#
# On launch it runs a pre-flight: loads .env, checks the tools each phase
# needs, and actually queries Radarr/Sonarr (/api/v3/system/status) so the
# menu can show what is connected, which version, and where the libraries
# live. It always passes explicit paths under <repo>/reports/, so it does
# not matter which directory you launch it from.
#
# The menu uses whiptail if it is installed (ncurses dialogs) and falls
# back to a plain numbered prompt otherwise. Nothing is installed
# automatically.
#
# Usage:
#   ./arr-language-audit.sh            # interactive menu
#   ./arr-language-audit.sh -h         # this help
#
# All the underlying scripts remain usable on their own; see their --help.

# No 'errexit' here on purpose: this is an interactive loop where a menu
# choice or a "no" answer routinely yields a non-zero status that must not
# abort the session. Errors from the real work are handled explicitly.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
REPORTS_DIR="$ROOT/reports"

SCAN_SH="$ROOT/scan/find-missing-italian-audio.sh"
VERIFY_SH="$ROOT/verify/verify-audio-language.sh"
REPORT_PY="$ROOT/verify/report.py"

CSV="$REPORTS_DIR/missing-italian-audio.csv"
VERIFIED_CSV="$REPORTS_DIR/verified-language-results.csv"
HTML="$REPORTS_DIR/verified-language-results.html"
ENV_FILE="$ROOT/.env"

mkdir -p "$REPORTS_DIR"

# Project identity, shown in the menu header / whiptail backtitle / About.
PROJECT_NAME="arr-language-audit"
PROJECT_URL="https://github.com/gioxx/arr-language-audit"
PROJECT_VERSION="$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || true)"
[[ -z "$PROJECT_VERSION" ]] && PROJECT_VERSION="(version unknown)"
PROJECT_BANNER="$PROJECT_NAME  $PROJECT_VERSION  -  $PROJECT_URL"

log() { echo "$@" >&2; }
err() { echo "ERROR: $*" >&2; }

case "${1:-}" in
    -h|--help)
        sed -n '2,/^# All the underlying scripts/{s/^# \{0,1\}//; p}' "$0"
        exit 0
        ;;
esac

HAVE_WHIPTAIL=false
command -v whiptail >/dev/null 2>&1 && HAVE_WHIPTAIL=true

# Common whiptail prefix: project banner on top, dialog title in the frame.
WT=(whiptail --backtitle "$PROJECT_BANNER" --title "$PROJECT_NAME")

# ---------------------------------------------------------------------------
# ask_* helpers: whiptail when available, plain read otherwise. Each echoes
# its result (ask_input / ask_menu) or returns 0/1 (ask_yesno), so the
# action functions stay readable.
# ---------------------------------------------------------------------------

ask_yesno() {
    # ask_yesno "question" [yes|no]   (default answer when the user just hits Enter)
    local q="$1" def="${2:-no}"
    if [[ "$HAVE_WHIPTAIL" == "true" ]]; then
        local flag=(--defaultno)
        [[ "$def" == "yes" ]] && flag=()
        "${WT[@]}" --yesno "$q" "${flag[@]}" 12 74
        return $?
    fi
    local hint="[y/N]"
    [[ "$def" == "yes" ]] && hint="[Y/n]"
    local a
    read -r -p "$q $hint: " a
    a="${a:-$def}"
    [[ "$a" =~ ^[Yy] || "$a" == "yes" ]]
}

ask_input() {
    # ask_input "prompt" "default"  -> echoes entered value (may be empty)
    local prompt="$1" def="${2:-}"
    if [[ "$HAVE_WHIPTAIL" == "true" ]]; then
        "${WT[@]}" --inputbox "$prompt" 12 74 "$def" 3>&1 1>&2 2>&3
        return
    fi
    local a
    read -r -p "$prompt [${def:-empty}]: " a
    echo "${a:-$def}"
}

ask_menu() {
    # ask_menu "default_tag" "title" tag1 "desc1" tag2 "desc2" ...  -> echoes chosen tag.
    # "default_tag" is pre-selected in whiptail and used when the plain
    # prompt gets an empty line.
    local default_tag="$1" title="$2"; shift 2
    if [[ "$HAVE_WHIPTAIL" == "true" ]]; then
        local count=$(( $# / 2 ))
        local pre=()
        [[ -n "$default_tag" ]] && pre=(--default-item "$default_tag")
        "${WT[@]}" "${pre[@]}" --menu "$title" 24 78 "$count" "$@" 3>&1 1>&2 2>&3
        return
    fi
    echo "" >&2
    echo "$title" >&2
    echo "" >&2
    while (( $# )); do
        printf '  %s) %s\n' "$1" "$2" >&2
        shift 2
    done
    local a
    read -r -p "Select [Enter = ${default_tag:-0}]: " a
    echo "${a:-$default_tag}"
}

info_box() {
    # Show a block of text; whiptail msgbox or plain print + pause.
    local text="$1"
    if [[ "$HAVE_WHIPTAIL" == "true" ]]; then
        "${WT[@]}" --scrolltext --msgbox "$text" 24 78
    else
        echo "" >&2
        echo "$text" >&2
        echo "" >&2
        read -r -p "Press Enter to continue... " _ || true
    fi
}

pause() {
    # Always a plain prompt (even under whiptail): the actions that call
    # pause stream command output to the real terminal, and a whiptail
    # dialog here would wipe it before the user can read it.
    read -r -p "Press Enter to continue... " _ || true
}

# ---------------------------------------------------------------------------
# Pre-flight: environment + connectivity
# ---------------------------------------------------------------------------

# Filled in by run_preflight(). *_LINE is a human-readable status string;
# *_OK is true only when the app answered an authenticated request.
RADARR_LINE="" ; RADARR_OK=false
SONARR_LINE="" ; SONARR_OK=false
ENV_READY=false
TOOLS_LINE=""
PHASE2_READY=false ; PHASE2_NOTE=""

# Query one app's /api/v3/system/status. Echoes "OK  vX  [instance]  url"
# on success (return 0), or a short reason otherwise (return 1).
probe_app() {
    local url="$1" key="$2"
    if [[ -z "$url" || -z "$key" || "$key" == YOUR_* ]]; then
        echo "not configured"; return 1
    fi
    if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        echo "unknown (need curl + jq to probe)"; return 1
    fi
    local body="" attempt
    for attempt in 1 2 3; do
        body=$(curl -sf -m 5 -H "X-Api-Key: $key" "$url/api/v3/system/status" 2>/dev/null) && break
        body=""
        sleep 1
    done
    if [[ -z "$body" ]]; then
        echo "UNREACHABLE ($url) -- check URL / API key / that it is running"
        return 1
    fi
    local ver inst
    ver=$(jq -r '.version // "?"' <<< "$body" | tr -d '\r')
    inst=$(jq -r '.instanceName // .appName // "?"' <<< "$body" | tr -d '\r')
    echo "OK   v$ver   [$inst]   $url"
    return 0
}

# List an app's root folders (path + accessibility + free space). Best effort.
app_rootfolders() {
    local url="$1" key="$2"
    command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
    curl -sf -m 5 -H "X-Api-Key: $key" "$url/api/v3/rootfolder" 2>/dev/null \
        | jq -r '.[] | "    \(.path)  (accessible: \(.accessible // "?"), free: \(((.freeSpace // 0) / 1073741824) | floor) GiB)"' 2>/dev/null \
        | tr -d '\r'
}

# Count active health warnings. Echoes a number or "?".
app_health_count() {
    local url="$1" key="$2"
    command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "?"; return; }
    curl -sf -m 5 -H "X-Api-Key: $key" "$url/api/v3/health" 2>/dev/null \
        | jq -r 'length' 2>/dev/null | tr -d '\r' || echo "?"
}

run_preflight() {
    # Load .env the same way the scan script does.
    if [[ -f "$ENV_FILE" ]]; then
        set -a
        # shellcheck disable=SC1090
        . "$ENV_FILE"
        set +a
    fi
    RADARR_URL="${RADARR_URL:-}"       ; RADARR_API_KEY="${RADARR_API_KEY:-}"
    SONARR_URL="${SONARR_URL:-}"       ; SONARR_API_KEY="${SONARR_API_KEY:-}"
    SKIP_RADARR="${SKIP_RADARR:-false}"; SKIP_SONARR="${SKIP_SONARR:-false}"

    # Tool readiness.
    local need_scan=() need_verify=()
    command -v curl    >/dev/null 2>&1 || need_scan+=(curl)
    command -v jq      >/dev/null 2>&1 || need_scan+=(jq)
    command -v python3 >/dev/null 2>&1 || need_verify+=(python3)
    command -v ffmpeg  >/dev/null 2>&1 || need_verify+=(ffmpeg)
    command -v ffprobe >/dev/null 2>&1 || need_verify+=(ffprobe)
    local t="tools: "
    if (( ${#need_scan[@]} == 0 )); then t+="phase 1 ready"; else t+="phase 1 MISSING ${need_scan[*]}"; fi
    if (( ${#need_verify[@]} == 0 )); then t+="  |  phase 2 tools ready"; else t+="  |  phase 2 missing ${need_verify[*]}"; fi
    [[ "$HAVE_WHIPTAIL" == "true" ]] && t+="  |  whiptail" || t+="  |  plain menu"
    TOOLS_LINE="$t"

    # faster-whisper (the phase 2 Python dependency): system python, or the
    # local verify/venv. This is separate from the CLI tools above.
    PHASE2_READY=false
    if ! command -v python3 >/dev/null 2>&1; then
        PHASE2_NOTE="faster-whisper: python3 missing"
    elif python3 -c "import faster_whisper" >/dev/null 2>&1; then
        PHASE2_READY=true; PHASE2_NOTE="faster-whisper: OK (system python3)"
    elif [[ -x "$ROOT/verify/venv/bin/python" ]] \
         && "$ROOT/verify/venv/bin/python" -c "import faster_whisper" >/dev/null 2>&1; then
        PHASE2_READY=true; PHASE2_NOTE="faster-whisper: OK (verify/venv)"
    else
        PHASE2_NOTE="faster-whisper: NOT installed -- use 'Set up phase 2'"
    fi

    # Radarr.
    RADARR_OK=false
    if [[ "$SKIP_RADARR" == "true" ]]; then
        RADARR_LINE="skipped (SKIP_RADARR=true)"
    else
        RADARR_LINE=$(probe_app "$RADARR_URL" "$RADARR_API_KEY") && RADARR_OK=true
    fi

    # Sonarr.
    SONARR_OK=false
    if [[ "$SKIP_SONARR" == "true" ]]; then
        SONARR_LINE="skipped (SKIP_SONARR=true)"
    else
        SONARR_LINE=$(probe_app "$SONARR_URL" "$SONARR_API_KEY") && SONARR_OK=true
    fi

    ENV_READY=false
    { [[ "$RADARR_OK" == "true" ]] || [[ "$SONARR_OK" == "true" ]]; } && ENV_READY=true
}

# ---------------------------------------------------------------------------
# Status helpers for the menu header
# ---------------------------------------------------------------------------

csv_row_count() {
    local f="$1"
    [[ -f "$f" ]] || { echo "-"; return; }
    local n
    n=$(( $(wc -l < "$f") - 1 ))
    (( n < 0 )) && n=0
    echo "$n"
}

verdict_summary() {
    [[ -f "$VERIFIED_CSV" ]] || { echo "not run yet"; return; }
    local mis conf errs
    mis=$(grep -c ',MISTAGGED_IS_ITALIAN,' "$VERIFIED_CSV" 2>/dev/null || true)
    conf=$(grep -c ',CONFIRMED_NOT_ITALIAN,' "$VERIFIED_CSV" 2>/dev/null || true)
    errs=$(grep -Ec ',(FILE_NOT_FOUND|EXTRACTION_FAILED|DETECTION_FAILED),' "$VERIFIED_CSV" 2>/dev/null || true)
    echo "${mis:-0} mistagged / ${conf:-0} confirmed not Italian / ${errs:-0} errors"
}

# Echo the menu tag for the most sensible next step given the current state,
# so the menu can pre-select it and label it "(recommended)".
#   8 reconfigure   1 scan   6 set up phase 2   2 verify   3 report   4 serve
recommended_action() {
    [[ "$ENV_READY" == "true" ]]                        || { echo 8; return; }
    [[ -f "$CSV" ]]                                     || { echo 1; return; }
    [[ "$PHASE2_READY" == "true" ]]                     || { echo 6; return; }
    [[ -f "$VERIFIED_CSV" && ! "$CSV" -nt "$VERIFIED_CSV" ]] || { echo 2; return; }
    [[ -f "$HTML" && ! "$VERIFIED_CSV" -nt "$HTML" ]]   || { echo 3; return; }
    echo 4
}

# Human-readable one-liner for the recommended step.
recommended_hint() {
    case "$1" in
        1) echo "run 'Scan library (phase 1)'" ;;
        2) echo "run 'Verify suspects (phase 2)' -- there is a newer phase 1 CSV" ;;
        3) echo "run 'Build HTML report' -- there are newer phase 2 results" ;;
        4) echo "everything is up to date -- 'Serve HTML report' to view it" ;;
        6) echo "install faster-whisper via 'Set up phase 2' before verifying" ;;
        8) echo "configure Radarr/Sonarr via 'Reconfigure (.env)'" ;;
        *) echo "" ;;
    esac
}

status_text() {
    # whiptail shows PROJECT_BANNER as its backtitle already; repeat it here
    # so the plain-text menu carries the same identity line.
    [[ "$HAVE_WHIPTAIL" == "true" ]] || printf '%s\n\n' "$PROJECT_BANNER"
    printf 'Radarr : %s\nSonarr : %s\n%s\n%s\n\nPhase 1 CSV : %s rows\nPhase 2     : %s\nHTML report : %s\n' \
        "$RADARR_LINE" \
        "$SONARR_LINE" \
        "$TOOLS_LINE" \
        "$PHASE2_NOTE" \
        "$(csv_row_count "$CSV")" \
        "$(verdict_summary)" \
        "$([[ -f "$HTML" ]] && echo "built ($HTML)" || echo "not built")"
    if [[ "$ENV_READY" != "true" ]]; then
        printf '\n>> No Radarr/Sonarr reachable. Use "Reconfigure (.env)" first.\n'
    fi
    printf '\nNext: %s\n' "$(recommended_hint "$(recommended_action)")"
    printf '\nChoose an action:'
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

action_scan() {
    if [[ "$ENV_READY" != "true" ]]; then
        ask_yesno "No Radarr/Sonarr reachable right now. Run the scan anyway?" no || return
    fi

    local force=false refresh=false
    ask_yesno "Force Radarr/Sonarr to rescan files on disk first (FORCE_RESCAN)? Slower." no && force=true
    ask_yesno "Ignore the Sonarr per-series cache and re-fetch every series (--refresh)?" no && refresh=true

    local args=("$CSV")
    [[ "$refresh" == "true" ]] && args+=(--refresh)

    log ""
    log "Running phase 1 (scan)..."
    FORCE_RESCAN="$force" "$SCAN_SH" "${args[@]}" || err "phase 1 exited with an error."
    pause
}

action_verify() {
    if [[ ! -f "$CSV" ]]; then
        info_box "No phase 1 CSV yet at:
  $CSV

Run 'Scan library (phase 1)' first."
        return
    fi

    if [[ "$PHASE2_READY" != "true" ]]; then
        info_box "faster-whisper is not installed, so phase 2 cannot run yet.

  $PHASE2_NOTE

Use the menu item 'Set up phase 2 (faster-whisper)': it creates
verify/venv and installs the package, with your confirmation. Or install
it yourself -- 'verify/verify-audio-language.sh --check' prints exactly
what is missing."
        return
    fi

    local model
    model=$(ask_menu "small" "faster-whisper model (bigger = more accurate, slower):" \
        small  "balanced (default)" \
        tiny   "fastest, least accurate" \
        base   "fast" \
        medium "most accurate, slowest")
    [[ -z "$model" ]] && return   # cancelled

    local limit
    limit=$(ask_input "Process only the first N files (blank = all, for a quick test):" "")

    local retry=false
    if [[ -f "$VERIFIED_CSV" ]]; then
        ask_yesno "Output exists. Also retry rows that previously errored (RETRY_ERRORS)?" no && retry=true
    fi

    log ""
    log "Running phase 2 (verify) with model '$model'..."
    WHISPER_MODEL="$model" LIMIT="$limit" RETRY_ERRORS="$retry" \
        "$VERIFY_SH" "$CSV" "$VERIFIED_CSV" || err "phase 2 exited with an error."
    pause
}

action_setup_phase2() {
    if ! command -v python3 >/dev/null 2>&1; then
        info_box "python3 is not installed. Install it (and ffmpeg) first."
        return
    fi

    log ""
    log "Checking the phase 2 environment..."
    if "$VERIFY_SH" --check; then
        info_box "Phase 2 environment is already ready. Nothing to do."
        run_preflight
        pause
        return
    fi

    local venv="$ROOT/verify/venv"
    ask_yesno "Create $venv and 'pip install faster-whisper' now?
(a few hundred MB, downloads CPU Torch etc.)" no || return

    log ""
    if [[ ! -x "$venv/bin/python" ]]; then
        log "Creating virtual environment: $venv"
        if ! python3 -m venv "$venv"; then
            local pv
            pv=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)
            info_box "Could not create the venv (ensurepip / python3-venv missing).
On Debian/Ubuntu install it first, then run this again:

  sudo apt install -y python${pv:-3}-venv"
            return
        fi
    fi

    log "Installing faster-whisper into the venv..."
    "$venv/bin/pip" install --upgrade pip && "$venv/bin/pip" install faster-whisper
    local irc=$?

    run_preflight
    if [[ "$irc" -eq 0 && "$PHASE2_READY" == "true" ]]; then
        log ""
        log "Done. $PHASE2_NOTE"
    else
        err "the install did not finish cleanly (exit $irc); see the output above."
    fi
    pause
}

action_report() {
    if [[ ! -f "$VERIFIED_CSV" ]]; then
        info_box "No phase 2 CSV yet at:
  $VERIFIED_CSV

Run 'Verify suspects (phase 2)' first."
        return
    fi
    command -v python3 >/dev/null 2>&1 || { err "python3 not found."; pause; return; }
    python3 "$REPORT_PY" "$VERIFIED_CSV" || err "report generation failed."
    log "HTML report: $HTML"
    pause
}

action_serve() {
    if [[ ! -f "$VERIFIED_CSV" ]]; then
        info_box "No phase 2 CSV yet at:
  $VERIFIED_CSV

Run 'Verify suspects (phase 2)' first."
        return
    fi
    command -v python3 >/dev/null 2>&1 || { err "python3 not found."; pause; return; }

    local port
    port=$(ask_input "Port to serve on (blank = pick a free one):" "")
    local extra=()
    [[ -n "$port" ]] && extra=(--port "$port")

    log ""
    log "Starting the report webserver. Press Enter in this terminal to stop it."
    python3 "$REPORT_PY" "$VERIFIED_CSV" --serve "${extra[@]}" || err "the report server exited with an error."
    pause
}

action_pipeline() {
    ask_yesno "Full pipeline: scan -> verify -> HTML report. Continue?" yes || return
    action_scan
    [[ -f "$CSV" ]] || { info_box "Phase 1 produced no CSV; stopping the pipeline."; return; }
    action_verify
    [[ -f "$VERIFIED_CSV" ]] || { info_box "Phase 2 produced no CSV; stopping the pipeline."; return; }
    action_report
}

action_connection_details() {
    local out="Connection details"
    out+=$'\n'"=================="$'\n\n'

    out+="Radarr: $RADARR_LINE"$'\n'
    if [[ "$RADARR_OK" == "true" ]]; then
        out+="  health warnings: $(app_health_count "$RADARR_URL" "$RADARR_API_KEY")"$'\n'
        out+="  root folders:"$'\n'
        out+="$(app_rootfolders "$RADARR_URL" "$RADARR_API_KEY")"$'\n'
    fi
    out+=$'\n'

    out+="Sonarr: $SONARR_LINE"$'\n'
    if [[ "$SONARR_OK" == "true" ]]; then
        out+="  health warnings: $(app_health_count "$SONARR_URL" "$SONARR_API_KEY")"$'\n'
        out+="  root folders:"$'\n'
        out+="$(app_rootfolders "$SONARR_URL" "$SONARR_API_KEY")"$'\n'
    fi
    out+=$'\n'"$TOOLS_LINE"$'\n'
    out+=$'\n'"Reminder: phase 2 needs to SEE the root-folder paths above on"$'\n'
    out+="this machine (same host, or the same mounts)."

    info_box "$out"
}

action_about() {
    info_box "$PROJECT_NAME
$PROJECT_VERSION

Find media files in Radarr/Sonarr libraries that have no Italian audio,
then verify the real spoken language locally with faster-whisper. The
scripts only produce CSV/HTML reports; no media file is ever modified.

Project page : $PROJECT_URL
License       : MIT
Update        : run 'git pull' in $ROOT

Two phases, all driven from this menu:
  1  scan/find-missing-italian-audio.sh   Radarr/Sonarr API  -> reports/missing-italian-audio.csv
  2  verify/verify-audio-language.sh      ffmpeg + whisper   -> reports/verified-language-results.csv
     verify/report.py                     CSV -> HTML report (+ optional viewer)

Each script also runs on its own; see its --help."
}

action_reset() {
    shopt -s nullglob
    local files=( "$REPORTS_DIR"/*.csv "$REPORTS_DIR"/*.html "$REPORTS_DIR"/*.cache.json )
    shopt -u nullglob

    if (( ${#files[@]} == 0 )); then
        info_box "Nothing to reset -- reports/ holds no CSV, HTML or cache files:
  $REPORTS_DIR"
        return
    fi

    local list
    list=$(printf '  %s\n' "${files[@]##*/}")
    ask_yesno "Delete these ${#files[@]} file(s) from reports/ and start completely over?

$list
This wipes the phase 1 / phase 2 CSVs, the HTML report and the Sonarr
per-series cache. The next scan and verify run from scratch. It cannot
be undone." no || return

    rm -f -- "${files[@]}"
    log ""
    log "Removed ${#files[@]} file(s) from $REPORTS_DIR."
    run_preflight
    pause
}

action_configure() {
    if [[ ! -f "$ENV_FILE" ]]; then
        cp "$ROOT/.env.example" "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        log "Created $ENV_FILE from .env.example."
    fi
    local editor="${EDITOR:-${VISUAL:-}}"
    if [[ -z "$editor" ]]; then
        for e in nano vim vi; do command -v "$e" >/dev/null 2>&1 && { editor="$e"; break; }; done
    fi
    if [[ -n "$editor" ]] && command -v "$editor" >/dev/null 2>&1; then
        "$editor" "$ENV_FILE"
    else
        info_box "No editor found (set \$EDITOR). Edit this file by hand:
  $ENV_FILE"
    fi
    log "Re-checking Radarr/Sonarr..."
    run_preflight
    pause
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

main() {
    run_preflight

    while true; do
        local choice rec
        rec=$(recommended_action)
        # Append "(recommended)" to whichever item rec points at.
        _lbl() { [[ "$1" == "$rec" ]] && echo "$2   (recommended)" || echo "$2"; }

        choice=$(ask_menu "$rec" "$(status_text)" \
            1 "$(_lbl 1 'Scan library (phase 1)')" \
            2 "$(_lbl 2 'Verify suspects (phase 2)')" \
            3 "$(_lbl 3 'Build HTML report')" \
            4 "$(_lbl 4 'Serve HTML report')" \
            5 "$(_lbl 5 'Run full pipeline')" \
            6 "$(_lbl 6 'Set up phase 2 (faster-whisper)')" \
            7 "Connection details" \
            8 "$(_lbl 8 'Reconfigure (.env) + re-check')" \
            R "Reset reports (delete CSV/HTML/cache, start over)" \
            9 "About / project page" \
            0 "Quit") || break   # whiptail Cancel / Esc

        case "${choice:-}" in
            1) action_scan ;;
            2) action_verify ;;
            3) action_report ;;
            4) action_serve ;;
            5) action_pipeline ;;
            6) action_setup_phase2 ;;
            7) action_connection_details ;;
            8) action_configure ;;
            R|r) action_reset ;;
            9) action_about ;;
            0|q|Q|"") break ;;
            *) err "unknown choice: $choice" ;;
        esac
    done
    log "Bye."
}

main

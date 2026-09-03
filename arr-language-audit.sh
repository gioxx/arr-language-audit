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
# It always passes explicit paths under <repo>/reports/, so it does not
# matter which directory you launch it from, and the phases always agree on
# where the files are.
#
# The menu uses whiptail if it is installed (nicer, ncurses dialogs) and
# falls back to a plain numbered prompt otherwise. Nothing is installed
# automatically.
#
# Usage:
#   ./arr-language-audit.sh            # interactive menu
#   ./arr-language-audit.sh -h         # this help
#
# All the underlying scripts remain usable on their own; see their --help.

# No 'errexit' here on purpose: this is an interactive loop where a menu
# choice or a "no" answer routinely yields a non-zero status that must not
# abort the session. Errors from the real work are handled explicitly below.
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

# ---------------------------------------------------------------------------
# Small ask_* helpers: whiptail when available, plain read otherwise. Each
# echoes its result on stdout (ask_input / ask_menu) or returns 0/1
# (ask_yesno), so the action functions below stay readable.
# ---------------------------------------------------------------------------

ask_yesno() {
    # ask_yesno "question" [default:yes|no]
    local q="$1" def="${2:-no}"
    if [[ "$HAVE_WHIPTAIL" == "true" ]]; then
        local flag=(--defaultno)
        [[ "$def" == "yes" ]] && flag=()
        whiptail --title "arr-language-audit" --yesno "$q" "${flag[@]}" 10 70
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
    # ask_input "prompt" "default" -> echoes the entered value (may be empty)
    local prompt="$1" def="${2:-}"
    if [[ "$HAVE_WHIPTAIL" == "true" ]]; then
        whiptail --title "arr-language-audit" --inputbox "$prompt" 10 70 "$def" 3>&1 1>&2 2>&3
        return
    fi
    local a
    read -r -p "$prompt [${def:-empty}]: " a
    echo "${a:-$def}"
}

ask_menu() {
    # ask_menu "title" tag1 "desc1" tag2 "desc2" ...  -> echoes chosen tag
    local title="$1"; shift
    if [[ "$HAVE_WHIPTAIL" == "true" ]]; then
        local count=$(( $# / 2 ))
        whiptail --title "arr-language-audit" --menu "$title" 20 74 "$count" "$@" 3>&1 1>&2 2>&3
        return
    fi
    echo "$title" >&2
    local i=1 tag desc
    local tags=()
    while (( $# )); do
        tag="$1"; desc="$2"; shift 2
        tags+=("$tag")
        printf '  %s) %s\n' "$tag" "$desc" >&2
    done
    local a
    read -r -p "Select: " a
    echo "$a"
}

pause() {
    [[ "$HAVE_WHIPTAIL" == "true" ]] && return 0
    read -r -p "Press Enter to continue... " _ || true
}

# ---------------------------------------------------------------------------
# Status helpers
# ---------------------------------------------------------------------------

csv_row_count() {
    # data rows (excludes the header); "-" if the file is missing
    local f="$1"
    [[ -f "$f" ]] || { echo "-"; return; }
    local n
    n=$(( $(wc -l < "$f") - 1 ))
    (( n < 0 )) && n=0
    echo "$n"
}

verdict_summary() {
    # "12 mistagged / 30 confirmed / 3 errors" from the verified CSV
    [[ -f "$VERIFIED_CSV" ]] || { echo "not run yet"; return; }
    local mis conf errs
    mis=$(grep -c ',MISTAGGED_IS_ITALIAN,' "$VERIFIED_CSV" || true)
    conf=$(grep -c ',CONFIRMED_NOT_ITALIAN,' "$VERIFIED_CSV" || true)
    errs=$(grep -Ec ',(FILE_NOT_FOUND|EXTRACTION_FAILED|DETECTION_FAILED),' "$VERIFIED_CSV" || true)
    echo "${mis:-0} mistagged / ${conf:-0} confirmed not Italian / ${errs:-0} errors"
}

status_text() {
    local cfg="missing"
    [[ -f "$ENV_FILE" ]] && cfg="present"
    printf 'Config .env: %s\nPhase 1 CSV: %s rows\nPhase 2:     %s\nHTML report: %s\n\nChoose an action:' \
        "$cfg" \
        "$(csv_row_count "$CSV")" \
        "$(verdict_summary)" \
        "$([[ -f "$HTML" ]] && echo "$HTML" || echo "not built")"
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

action_configure() {
    if [[ ! -f "$ENV_FILE" ]]; then
        cp "$ROOT/.env.example" "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        log "Created $ENV_FILE from .env.example."
    fi
    local editor="${EDITOR:-${VISUAL:-nano}}"
    if command -v "$editor" >/dev/null 2>&1; then
        "$editor" "$ENV_FILE"
    else
        log "No editor found (set \$EDITOR). Edit this file by hand:"
        log "  $ENV_FILE"
    fi
    log "Tip: leaving RADARR_*/SONARR_* blank makes phase 1 run its"
    log "auto-detect wizard on the next scan."
    pause
}

action_scan() {
    local refresh=false force=false
    ask_yesno "Force Radarr/Sonarr to rescan files on disk first (FORCE_RESCAN)? Slower." no && force=true
    ask_yesno "Ignore the Sonarr per-series cache and re-fetch every series (--refresh)?" no && refresh=true

    log ""
    log "Running phase 1 (scan)..."
    local args=("$CSV")
    [[ "$refresh" == "true" ]] && args+=(--refresh)
    FORCE_RESCAN="$force" "$SCAN_SH" "${args[@]}" || err "phase 1 exited with an error."
    pause
}

action_verify() {
    if [[ ! -f "$CSV" ]]; then
        err "No phase 1 CSV at $CSV. Run 'Scan library' first."
        pause
        return
    fi

    local model
    model=$(ask_menu "faster-whisper model (bigger = more accurate, slower):" \
        small  "balanced (default)" \
        tiny   "fastest, least accurate" \
        base   "fast" \
        medium "most accurate, slowest")
    [[ -z "$model" ]] && model=small

    local limit
    limit=$(ask_input "Process only the first N files (blank = all, for a quick test):" "")

    local retry=false
    if [[ -f "$VERIFIED_CSV" ]]; then
        ask_yesno "Output already exists. Also retry rows that previously errored (RETRY_ERRORS)?" no && retry=true
    fi

    log ""
    log "Running phase 2 (verify) with model '$model'..."
    WHISPER_MODEL="$model" \
    LIMIT="${limit}" \
    RETRY_ERRORS="$retry" \
        "$VERIFY_SH" "$CSV" "$VERIFIED_CSV" || err "phase 2 exited with an error."
    pause
}

action_report() {
    if [[ ! -f "$VERIFIED_CSV" ]]; then
        err "No phase 2 CSV at $VERIFIED_CSV. Run 'Verify suspects' first."
        pause
        return
    fi
    command -v python3 >/dev/null 2>&1 || { err "python3 not found."; pause; return; }
    python3 "$REPORT_PY" "$VERIFIED_CSV" || err "report generation failed."
    log "HTML report: $HTML"
    pause
}

action_serve() {
    if [[ ! -f "$VERIFIED_CSV" ]]; then
        err "No phase 2 CSV at $VERIFIED_CSV. Run 'Verify suspects' first."
        pause
        return
    fi
    command -v python3 >/dev/null 2>&1 || { err "python3 not found."; pause; return; }

    local port
    port=$(ask_input "Port to serve on (blank = pick a free one):" "")

    local extra=()
    [[ -n "$port" ]] && extra=(--port "$port")

    log ""
    log "Starting the report webserver. Press Enter in this terminal to stop it."
    # report.py builds the HTML, serves it, and blocks until Enter.
    python3 "$REPORT_PY" "$VERIFIED_CSV" --serve "${extra[@]}" || err "the report server exited with an error."
    pause
}

action_pipeline() {
    log "Full pipeline: scan -> verify -> HTML report."
    ask_yesno "Continue?" yes || return
    action_scan
    [[ -f "$CSV" ]] || { err "phase 1 produced no CSV; stopping."; return; }
    action_verify
    [[ -f "$VERIFIED_CSV" ]] || { err "phase 2 produced no CSV; stopping."; return; }
    action_report
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

main() {
    while true; do
        local choice
        choice=$(ask_menu "$(status_text)" \
            1 "Configure (.env)" \
            2 "Scan library (phase 1)" \
            3 "Verify suspects (phase 2)" \
            4 "Build HTML report" \
            5 "Serve HTML report" \
            6 "Run full pipeline" \
            0 "Quit") || break   # whiptail Cancel / Esc

        case "${choice:-}" in
            1) action_configure ;;
            2) action_scan ;;
            3) action_verify ;;
            4) action_report ;;
            5) action_serve ;;
            6) action_pipeline ;;
            0|q|Q|"") break ;;
            *) err "unknown choice: $choice" ;;
        esac
    done
    log "Bye."
}

main

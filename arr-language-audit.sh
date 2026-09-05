#!/usr/bin/env bash
#
# arr-language-audit -- interactive orchestrator: one menu driving phase 1,
# phase 2 and the report. What it is and how it is used: -h / usage() below.
#
# Design notes that matter when changing this file:
#
#   * Sourcing this file has NO side effects: no directory is created, no
#     command is run, nothing is printed. Everything that acts lives in main(),
#     behind the BASH_SOURCE guard at the bottom, so the bats suite can source
#     the script and call one function at a time.
#   * bash 3.2 (the /bin/bash macOS ships): "${arr[@]}" on an EMPTY array under
#     `set -u` is an error before bash 4.4. The ask_* helpers therefore branch
#     instead of building option arrays, and the one place that really needs an
#     array expands it as ${arr[@]+"${arr[@]}"}.
#   * The .env file is PARSED by lib/common.sh, never sourced: a .env is often
#     world-readable, and sourcing it is arbitrary code execution as the user
#     running the audit. Nothing from it is exported either -- the API keys stay
#     in this shell and are explicitly removed from the environment of ffmpeg,
#     whisper and the report.
#   * The *arr API key never reaches curl's argv (ps would show it to every
#     user on the box); arr_curl passes it through a --config file on stdin.
#   * Whether phase 2 can run is decided by ONE thing: what
#     `verify-audio-language.sh --check` says. Importing faster_whisper here
#     too would let the menu and the launcher disagree.
#
# Usage, options and exit codes: -h (the usage() below is the single copy).

# No 'errexit' here on purpose: this is an interactive loop where a menu
# choice or a "no" answer routinely yields a non-zero status that must not
# abort the session. Errors from the real work are handled explicitly.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"

REPORTS_DIR="$ROOT/reports"

SCAN_SH="$ROOT/scan/find-missing-italian-audio.sh"
VERIFY_SH="$ROOT/verify/verify-audio-language.sh"
REPORT_PY="$ROOT/verify/report.py"
REQUIREMENTS="$ROOT/verify/requirements.txt"
VENV_DIR="$ROOT/verify/venv"

CSV="$REPORTS_DIR/missing-italian-audio.csv"
VERIFIED_CSV="$REPORTS_DIR/verified-language-results.csv"
HTML="$REPORTS_DIR/verified-language-results.html"
ENV_FILE="$ROOT/.env"

# Project identity, shown in the menu header / whiptail backtitle / About.
PROJECT_NAME="arr-language-audit"
PROJECT_URL="https://github.com/gioxx/arr-language-audit"
PROJECT_VERSION=""

usage() {
    cat <<'EOF'
arr-language-audit -- interactive orchestrator.

A single entry point that drives the whole two-phase workflow:

  phase 1  scan/find-missing-italian-audio.sh   (Radarr/Sonarr API -> CSV)
  phase 2  verify/verify-audio-language.sh      (ffmpeg + faster-whisper -> CSV)
  report   verify/report.py                     (CSV -> HTML, optional viewer)

On launch it runs a pre-flight: it reads .env, checks the tools each phase
needs, asks the phase 2 launcher whether its environment is ready, and
queries Radarr and Sonarr (/api/v3/system/status, both at once, one attempt)
so the menu can show what is connected, which version, and where the
libraries live. It always passes explicit paths under <repo>/reports/, so it
does not matter which directory you launch it from.

The menu uses whiptail if it is installed (ncurses dialogs) and falls back to
a plain numbered prompt otherwise. Nothing is installed automatically.

Usage:
  ./arr-language-audit.sh            # interactive menu
  ./arr-language-audit.sh -h         # this help

Environment:
  ARR_PLAIN_MENU     set to anything to force the plain menu even when
                     whiptail is installed
  ALA_DOTENV_FILE    read this .env instead of searching the repository

Exit codes:
  0   the menu was left with "Quit" (or Esc / Cancel)
  1   the reports directory could not be created

All the underlying scripts remain usable on their own; see their --help.
EOF
}

# The version is a git call, so it is made once, on demand: sourcing this file
# must not shell out, and `-h` must not either.
project_version() {
    if [[ -z "$PROJECT_VERSION" ]]; then
        PROJECT_VERSION="$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || true)"
        [[ -n "$PROJECT_VERSION" ]] || PROJECT_VERSION="(version unknown)"
    fi
    printf '%s\n' "$PROJECT_VERSION"
}

project_banner() {
    printf '%s  %s  -  %s\n' "$PROJECT_NAME" "$(project_version)" "$PROJECT_URL"
}

# whiptail is used when it is installed, unless ARR_PLAIN_MENU asks for the
# plain prompt (which is also how the tests drive the menu).
HAVE_WHIPTAIL=false
if [[ -z "${ARR_PLAIN_MENU:-}" ]] && have whiptail; then
    HAVE_WHIPTAIL=true
fi

# wt <whiptail-args>... -- whiptail with the project banner on top and the
# dialog title in the frame. A function rather than an array, so building the
# banner (a git call) is deferred to the first dialog.
wt() {
    whiptail --backtitle "$(project_banner)" --title "$PROJECT_NAME" "$@"
}

# ---------------------------------------------------------------------------
# ask_* helpers: whiptail when available, plain read otherwise. Each echoes
# its result (ask_input / ask_menu) or returns 0/1 (ask_yesno), so the
# action functions stay readable.
#
# All three report a Cancel, an Esc or an exhausted stdin as a non-zero status
# and print nothing: a cancelled dialog must abandon the action, never fall
# through to a default that runs something the operator did not ask for.
# ---------------------------------------------------------------------------

ask_yesno() {
    # ask_yesno "question" [yes|no]   (default answer when the user just hits Enter)
    local q="$1" def="${2:-no}"
    if [[ "$HAVE_WHIPTAIL" == "true" ]]; then
        # Branch rather than build a flag array: an empty "${flag[@]}" under
        # `set -u` is an error on bash 3.2.
        if [[ "$def" == "yes" ]]; then
            wt --yesno "$q" 12 74
        else
            wt --yesno "$q" --defaultno 12 74
        fi
        return $?
    fi
    local hint="[y/N]"
    [[ "$def" == "yes" ]] && hint="[Y/n]"
    local a
    read -r -p "$q $hint: " a || return 1
    a="${a:-$def}"
    [[ "$a" =~ ^[Yy] || "$a" == "yes" ]]
}

ask_input() {
    # ask_input "prompt" "default"  -> echoes the entered value (may be empty),
    # rc 1 when the dialog was cancelled.
    local prompt="$1" def="${2:-}" out rc=0
    if [[ "$HAVE_WHIPTAIL" == "true" ]]; then
        out=$(wt --inputbox "$prompt" 12 74 "$def" 3>&1 1>&2 2>&3) || rc=$?
        [[ "$rc" -eq 0 ]] || return 1
        printf '%s\n' "$out"
        return 0
    fi
    local a
    read -r -p "$prompt [${def:-empty}]: " a || return 1
    printf '%s\n' "${a:-$def}"
}

ask_menu() {
    # ask_menu "default_tag" "title" tag1 "desc1" tag2 "desc2" ...  -> echoes
    # the chosen tag, rc 1 when the dialog was cancelled. "default_tag" is
    # pre-selected in whiptail and used when the plain prompt gets an empty
    # line.
    local default_tag="$1" title="$2"; shift 2
    if [[ "$HAVE_WHIPTAIL" == "true" ]]; then
        local count=$(( $# / 2 ))
        if [[ -n "$default_tag" ]]; then
            wt --default-item "$default_tag" --menu "$title" 24 78 "$count" "$@" 3>&1 1>&2 2>&3
        else
            wt --menu "$title" 24 78 "$count" "$@" 3>&1 1>&2 2>&3
        fi
        return $?
    fi
    echo "" >&2
    echo "$title" >&2
    echo "" >&2
    while (( $# )); do
        printf '  %s) %s\n' "$1" "$2" >&2
        shift 2
    done
    local a
    read -r -p "Select [Enter = ${default_tag:-0}]: " a || return 1
    printf '%s\n' "${a:-$default_tag}"
}

info_box() {
    # Show a block of text; whiptail msgbox or plain print + pause.
    local text="$1"
    if [[ "$HAVE_WHIPTAIL" == "true" ]]; then
        wt --scrolltext --msgbox "$text" 24 78
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
PHASE2_READY=false ; PHASE2_NOTE="" ; PHASE2_PYTHON="" ; PHASE2_HINT=""

# The *arr configuration. Seeded from the environment (never overwritten with
# an empty string: load_dotenv treats set-but-empty as unset, so a .env can
# still fill in what the environment left out).
RADARR_URL="${RADARR_URL:-}" ; RADARR_API_KEY="${RADARR_API_KEY:-}"
SONARR_URL="${SONARR_URL:-}" ; SONARR_API_KEY="${SONARR_API_KEY:-}"
SKIP_RADARR="${SKIP_RADARR:-false}" ; SKIP_SONARR="${SKIP_SONARR:-false}"

# How long a single pre-flight probe may take. One attempt, a short timeout:
# this runs before the menu is drawn, and the retries that a real scan needs
# belong to the scan script, which is where a slow *arr actually matters.
PROBE_TIMEOUT="${ALA_PROBE_TIMEOUT:-3}"

# Query one app's /api/v3/system/status. Echoes "OK  vX  [instance]  url"
# on success (return 0), or a short reason otherwise (return 1).
probe_app() {
    local url="$1" key="$2"
    if [[ -z "$url" || -z "$key" || "$key" == YOUR_* ]]; then
        echo "not configured"; return 1
    fi
    if ! have curl || ! have jq; then
        echo "unknown (need curl + jq to probe)"; return 1
    fi
    local body="" ver inst
    body=$(arr_curl "$key" -m "$PROBE_TIMEOUT" "$url/api/v3/system/status" 2>/dev/null) || body=""
    if [[ -z "$body" ]]; then
        echo "UNREACHABLE ($url) -- check URL / API key / that it is running"
        return 1
    fi
    ver=$(jq -r '.version // "?"' <<< "$body" 2>/dev/null)
    inst=$(jq -r '.instanceName // .appName // "?"' <<< "$body" 2>/dev/null)
    strip_cr ver
    strip_cr inst
    echo "OK   v$ver   [$inst]   $url"
    return 0
}

# List an app's root folders (path + accessibility + free space). Best effort.
app_rootfolders() {
    local url="$1" key="$2"
    have curl && have jq || return 0
    arr_curl "$key" -m "$PROBE_TIMEOUT" "$url/api/v3/rootfolder" 2>/dev/null \
        | jq -r '.[] | "    \(.path)  (accessible: \(.accessible // "?"), free: \(((.freeSpace // 0) / 1073741824) | floor) GiB)"' 2>/dev/null \
        | tr -d '\r'
}

# Count active health warnings. Echoes a number or "?".
app_health_count() {
    local url="$1" key="$2"
    if ! have curl || ! have jq; then
        echo "?"
        return
    fi
    arr_curl "$key" -m "$PROBE_TIMEOUT" "$url/api/v3/health" 2>/dev/null \
        | jq -r 'length' 2>/dev/null | tr -d '\r' || echo "?"
}

# preflight_tools -- the one-line summary of what each phase can run.
preflight_tools() {
    local need_scan="" need_verify="" t="tools: "
    have curl    || need_scan="$need_scan curl"
    have jq      || need_scan="$need_scan jq"
    have python3 || need_verify="$need_verify python3"
    have ffmpeg  || need_verify="$need_verify ffmpeg"
    have ffprobe || need_verify="$need_verify ffprobe"
    if [[ -z "$need_scan" ]]; then t+="phase 1 ready"; else t+="phase 1 MISSING${need_scan}"; fi
    if [[ -z "$need_verify" ]]; then t+="  |  phase 2 tools ready"; else t+="  |  phase 2 missing${need_verify}"; fi
    if [[ "$HAVE_WHIPTAIL" == "true" ]]; then t+="  |  whiptail"; else t+="  |  plain menu"; fi
    TOOLS_LINE="$t"
}

# preflight_phase2 -- ask the launcher, and only the launcher, whether phase 2
# can run. Its answer also names the interpreter, which is the one the report
# is then built with: a venv that has faster-whisper usually has the rest too.
preflight_phase2() {
    PHASE2_READY=false
    PHASE2_PYTHON=""
    PHASE2_HINT=""
    local out=""
    if out="$(env -u RADARR_API_KEY -u SONARR_API_KEY "$VERIFY_SH" --check 2>&1)"; then
        PHASE2_READY=true
        PHASE2_PYTHON="$(printf '%s\n' "$out" | sed -n 's/.*python via: \([^)]*\)).*/\1/p' | head -1)"
        PHASE2_NOTE="phase 2: ready (python: ${PHASE2_PYTHON:-unknown})"
    else
        PHASE2_NOTE="phase 2: NOT ready -- use 'Set up phase 2 (faster-whisper)'"
    fi
    PHASE2_HINT="$out"
}

# preflight_apps -- probe Radarr and Sonarr AT THE SAME TIME. Sequentially,
# with retries, two unreachable apps used to hold the menu for half a minute.
preflight_apps() {
    local tmp radarr_pid=0 sonarr_pid=0
    if ! tmp="$(mktemp -d "${TMPDIR:-/tmp}/ala-preflight.XXXXXX")"; then
        RADARR_LINE="unknown (no temp directory to run the pre-flight in)"
        SONARR_LINE="$RADARR_LINE"
        return 1
    fi

    RADARR_OK=false
    if is_true "$SKIP_RADARR"; then
        RADARR_LINE="skipped (SKIP_RADARR=true)"
    else
        probe_app "$RADARR_URL" "$RADARR_API_KEY" > "$tmp/radarr" 2>/dev/null &
        radarr_pid=$!
    fi

    SONARR_OK=false
    if is_true "$SKIP_SONARR"; then
        SONARR_LINE="skipped (SKIP_SONARR=true)"
    else
        probe_app "$SONARR_URL" "$SONARR_API_KEY" > "$tmp/sonarr" 2>/dev/null &
        sonarr_pid=$!
    fi

    if [[ "$radarr_pid" -ne 0 ]]; then
        wait "$radarr_pid" && RADARR_OK=true
        RADARR_LINE="$(cat "$tmp/radarr" 2>/dev/null)"
    fi
    if [[ "$sonarr_pid" -ne 0 ]]; then
        wait "$sonarr_pid" && SONARR_OK=true
        SONARR_LINE="$(cat "$tmp/sonarr" 2>/dev/null)"
    fi

    rm -rf "$tmp"
}

run_preflight() {
    local dotenv
    if dotenv="$(find_dotenv)"; then
        load_dotenv "$dotenv" || warn "could not read $dotenv"
    fi
    SKIP_RADARR="${SKIP_RADARR:-false}"
    SKIP_SONARR="${SKIP_SONARR:-false}"

    preflight_tools
    preflight_phase2
    preflight_apps

    ENV_READY=false
    { [[ "$RADARR_OK" == "true" ]] || [[ "$SONARR_OK" == "true" ]]; } && ENV_READY=true
    return 0
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
    local mis conf low errs
    mis=$(grep -c ',MISTAGGED_IS_ITALIAN,' "$VERIFIED_CSV" 2>/dev/null || true)
    conf=$(grep -c ',CONFIRMED_NOT_ITALIAN,' "$VERIFIED_CSV" 2>/dev/null || true)
    low=$(grep -c ',LOW_CONFIDENCE,' "$VERIFIED_CSV" 2>/dev/null || true)
    errs=$(grep -Ec ',(FILE_NOT_FOUND|EXTRACTION_FAILED|DETECTION_FAILED),' "$VERIFIED_CSV" 2>/dev/null || true)
    echo "${mis:-0} mistagged / ${conf:-0} confirmed not Italian / ${low:-0} low confidence / ${errs:-0} errors"
}

# Echo the menu tag for the most sensible next step given the current state,
# so the menu can pre-select it and label it "(recommended)".
#   8 reconfigure   1 scan   6 set up phase 2   2 verify   3 report   4 serve
#
# A phase 1 CSV with only its header counts as scanned: the scan ran and found
# nothing, and telling the operator to run it again would be a loop.
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
    # whiptail shows the banner as its backtitle already; repeat it here
    # so the plain-text menu carries the same identity line.
    [[ "$HAVE_WHIPTAIL" == "true" ]] || printf '%s\n\n' "$(project_banner)"
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

    log ""
    log "Running phase 1 (scan)..."
    local rc=0
    if [[ "$refresh" == "true" ]]; then
        FORCE_RESCAN="$force" "$SCAN_SH" "$CSV" --refresh || rc=$?
    else
        FORCE_RESCAN="$force" "$SCAN_SH" "$CSV" || rc=$?
    fi
    case "$rc" in
        0) ;;
        2) err "phase 1 finished with an unreachable app; previous report kept" ;;
        *) err "phase 1 exited with an error." ;;
    esac
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
verify/venv and installs verify/requirements.txt, with your confirmation.
Or install it yourself -- this is what the launcher reports:

$PHASE2_HINT"
        return
    fi

    local model
    model=$(ask_menu "small" "faster-whisper model (bigger = more accurate, slower):" \
        small  "balanced (default)" \
        tiny   "fastest, least accurate" \
        base   "fast" \
        medium "most accurate, slowest") || return
    [[ -z "$model" ]] && return   # cancelled

    local limit
    limit=$(ask_input "Process only the first N files (blank = all, for a quick test):" "") || return

    local retry=false
    if [[ -f "$VERIFIED_CSV" ]]; then
        ask_yesno "Output exists. Also retry rows that previously errored (RETRY_ERRORS)?" no && retry=true
    fi

    log ""
    log "Running phase 2 (verify) with model '$model'..."
    local rc=0
    # The keys are of no use to ffmpeg and whisper, and phase 2 shells out for
    # every single file.
    env -u RADARR_API_KEY -u SONARR_API_KEY \
        WHISPER_MODEL="$model" LIMIT="$limit" RETRY_ERRORS="$retry" \
        "$VERIFY_SH" "$CSV" "$VERIFIED_CSV" || rc=$?
    case "$rc" in
        0) ;;
        3) err "phase 2 finished but every file errored (are the media paths mounted here?)" ;;
        *) err "phase 2 exited with an error." ;;
    esac
    pause
}

action_setup_phase2() {
    if ! have python3; then
        info_box "python3 is not installed. Install it (and ffmpeg) first."
        return
    fi

    log ""
    log "Checking the phase 2 environment..."
    if env -u RADARR_API_KEY -u SONARR_API_KEY "$VERIFY_SH" --check; then
        info_box "Phase 2 environment is already ready. Nothing to do."
        run_preflight
        pause
        return
    fi

    ask_yesno "Create $VENV_DIR and install $REQUIREMENTS now?
(a few hundred MB, downloads CPU Torch etc.)" no || return

    log ""
    if [[ ! -x "$VENV_DIR/bin/python" ]]; then
        log "Creating virtual environment: $VENV_DIR"
        if ! python3 -m venv "$VENV_DIR"; then
            local pv
            pv=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)
            info_box "Could not create the venv (ensurepip / python3-venv missing).
On Debian/Ubuntu install it first, then run this again:

  sudo apt install -y python${pv:-3}-venv"
            return
        fi
    fi

    # A pip that cannot upgrade itself is not a reason to stop: the pinned
    # requirements install perfectly well with the pip the venv already has.
    log "Installing the phase 2 requirements into the venv..."
    "$VENV_DIR/bin/pip" install --upgrade pip \
        || warn "could not upgrade pip inside the venv; continuing with the one it has."
    local irc=0
    "$VENV_DIR/bin/pip" install -r "$REQUIREMENTS" || irc=$?

    run_preflight
    if [[ "$irc" -eq 0 && "$PHASE2_READY" == "true" ]]; then
        log ""
        log "Done. $PHASE2_NOTE"
    else
        err "the install did not finish cleanly (exit $irc); see the output above."
    fi
    pause
}

# require_phase2_csv -- rc 0 when phase 2 has produced its CSV, otherwise say
# where it should be and rc 1.
require_phase2_csv() {
    [[ -f "$VERIFIED_CSV" ]] && return 0
    info_box "No phase 2 CSV yet at:
  $VERIFIED_CSV

Run 'Verify suspects (phase 2)' first."
    return 1
}

# phase2_python -- echo the interpreter the report runs under: the one the
# launcher named, so a venv build is not rendered by a bare system python3.
phase2_python() {
    local py="${PHASE2_PYTHON:-python3}"
    have "$py" || { err "no usable python3 found ($py)."; return 1; }
    printf '%s\n' "$py"
}

action_report() {
    require_phase2_csv || return 0   # explained, not a failure
    local py
    py=$(phase2_python) || { pause; return; }

    env -u RADARR_API_KEY -u SONARR_API_KEY "$py" "$REPORT_PY" "$VERIFIED_CSV" \
        || err "report generation failed."
    log "HTML report: $HTML"
    pause
}

action_serve() {
    require_phase2_csv || return 0   # explained, not a failure
    local py
    py=$(phase2_python) || { pause; return; }

    local port
    port=$(ask_input "Port to serve on (blank = pick a free one):" "") || return

    # The report lists every path in the library, so it stays on the loopback
    # interface unless the operator asks for the LAN in so many words.
    local extra=()
    [[ -n "$port" ]] && extra=(--port "$port")
    if ask_yesno "Expose the report on the LAN (bind 0.0.0.0)?" no; then
        extra=(${extra[@]+"${extra[@]}"} --host 0.0.0.0)
    fi

    log ""
    log "Starting the report webserver. Press Enter in this terminal to stop it."
    env -u RADARR_API_KEY -u SONARR_API_KEY \
        "$py" "$REPORT_PY" "$VERIFIED_CSV" --serve ${extra[@]+"${extra[@]}"} \
        || err "the report server exited with an error."
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
$(project_version)

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
        local e
        for e in nano vim vi; do have "$e" && { editor="$e"; break; }; done
    fi
    if [[ -n "$editor" ]] && have "$editor"; then
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
    case "${1:-}" in
        -h|--help)
            usage
            return 0
            ;;
    esac

    mkdir -p "$REPORTS_DIR" 2>/dev/null \
        || die 1 "cannot create the reports directory: $REPORTS_DIR"

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
            0 "Quit") || break   # whiptail Cancel / Esc, or no more input

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

# Sourcing this file defines everything and runs nothing: that is what lets the
# bats suite exercise one function at a time.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

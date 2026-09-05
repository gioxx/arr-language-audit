#!/usr/bin/env bash
#
# One entry point for the checks CI runs.
#
#   scripts/test.sh lint   shellcheck + ruff
#   scripts/test.sh bats   the bats suite, forced onto /bin/bash
#   scripts/test.sh py     pytest on 3.12 and on the 3.9 floor
#   scripts/test.sh ui     report interactions in jsdom (Node.js 22+)
#   scripts/test.sh contract  real faster-whisper API/decoder, without model weights
#   scripts/test.sh all    lint, py, bats, ui, then contract
#
# ruff and pytest run through uvx; UI dependencies stay in tests/report-ui.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

stage() { printf '\n== %s ==\n' "$1"; }
summary() { printf '%-6s %s\n' "$1" "$2"; }

# Product scripts, the check runner and the shell test helpers.
product_scripts() {
    local candidate
    for candidate in arr-language-audit.sh scan/*.sh verify/*.sh lib/*.sh scripts/*.sh \
        tests/bats/fakes/bin/* tests/bats/helpers/*.bash; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
        fi
    done
}

run_lint() {
    stage "lint: shellcheck"
    local files=()
    while IFS= read -r line; do
        files+=("$line")
    done < <(product_scripts)
    shellcheck -S warning "${files[@]}"
    summary lint "shellcheck clean (${#files[@]} files)"

    stage "lint: ruff"
    uvx ruff check .
    summary lint "ruff clean"
}

run_py() {
    stage "py: pytest 3.12"
    uvx --python 3.12 pytest -q
    summary py "pytest 3.12 passed"

    stage "py: pytest 3.9 (declared floor)"
    if uv python find 3.9 >/dev/null 2>&1; then
        uvx --python 3.9 pytest -q
        summary py "pytest 3.9 passed"
    else
        printf 'WARNING: no Python 3.9 available; the floor was not exercised.\n' >&2
        summary py "pytest 3.9 SKIPPED (interpreter not found)"
    fi
}

run_bats() {
    stage "bats"
    PATH="/bin:/usr/bin:$PATH" BASH_UNDER_TEST=/bin/bash bats -r tests/bats
    summary bats "bats suite passed"
}

run_ui() {
    stage "ui: report interactions"
    npm ci --prefix tests/report-ui --ignore-scripts --no-audit --no-fund
    npm test --prefix tests/report-ui
    summary ui "report interaction tests passed"
}

run_contract() {
    stage "contract: installed faster-whisper (no model download)"
    # The normal pytest path deliberately installs a fake faster_whisper.
    # Override it here so this check exercises the pinned real dependency.
    HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
        uvx --python "${CONTRACT_PYTHON:-3.12}" --with-requirements verify/requirements.txt \
        pytest -q -o pythonpath=verify tests/integration
    summary contract "real faster-whisper contract passed"
}

case "${1:-all}" in
    lint) run_lint ;;
    bats) run_bats ;;
    py)   run_py ;;
    ui)   run_ui ;;
    contract) run_contract ;;
    all)  run_lint; run_py; run_bats; run_ui; run_contract ;;
    *)
        printf 'usage: %s {lint|bats|py|ui|contract|all}\n' "$0" >&2
        exit 2
        ;;
esac

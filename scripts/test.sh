#!/usr/bin/env bash
#
# One entry point for the checks CI runs.
#
#   scripts/test.sh lint   shellcheck + ruff
#   scripts/test.sh bats   the bats suite, forced onto /bin/bash
#   scripts/test.sh py     pytest on 3.12 and on the 3.9 floor
#   scripts/test.sh all    lint, then py, then bats
#
# Nothing is installed into the project: ruff and pytest run through uvx.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

stage() { printf '\n== %s ==\n' "$1"; }
summary() { printf '%-6s %s\n' "$1" "$2"; }

# Only pass shellcheck files that exist: lib/ arrives in a later task.
product_scripts() {
    local candidate
    for candidate in arr-language-audit.sh scan/*.sh verify/*.sh lib/*.sh \
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

case "${1:-all}" in
    lint) run_lint ;;
    bats) run_bats ;;
    py)   run_py ;;
    all)  run_lint; run_py; run_bats ;;
    *)
        printf 'usage: %s {lint|bats|py|all}\n' "$0" >&2
        exit 2
        ;;
esac

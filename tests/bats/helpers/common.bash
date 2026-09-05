#!/usr/bin/env bash
#
# Shared bats setup: repository paths, the bats-support/bats-assert libraries
# and the small primitives every suite needs.
#
# `load helpers/common` sources this once per test, so anything at file scope
# runs before each test body.

# Repository root, derived from this file's location (tests/bats/helpers).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BATS_TESTS_DIR="$ROOT/tests/bats"

# Every product script is executed as `"$BASH_UNDER_TEST" script ...` so that
# macOS really exercises bash 3.2 instead of whatever Homebrew put on PATH.
BASH_UNDER_TEST="${BASH_UNDER_TEST:-/bin/bash}"

# Absolute paths to the real tools, resolved before make_bin narrows PATH.
# The shims and the fake server are started through these, so a test that
# shadows `python3` or `jq` cannot break the harness itself.
REAL_JQ="${REAL_JQ:-$(command -v jq || true)}"
REAL_CURL="${REAL_CURL:-$(command -v curl || true)}"
REAL_PYTHON3="${REAL_PYTHON3:-$(command -v python3 || true)}"
export REAL_JQ REAL_CURL REAL_PYTHON3

# Load one bats helper library: vendored copy first (tests/bats/lib), then
# $BATS_LIB_PATH (what bats-core/bats-action sets up in CI), then Homebrew.
_load_bats_lib() {
    local name="$1" dir saved_ifs

    if [[ -f "$BATS_TESTS_DIR/lib/$name/load.bash" ]]; then
        . "$BATS_TESTS_DIR/lib/$name/load.bash"
        return 0
    fi

    saved_ifs="$IFS"
    IFS=':'
    for dir in ${BATS_LIB_PATH:-}; do
        IFS="$saved_ifs"
        if [[ -f "$dir/$name/load.bash" ]]; then
            . "$dir/$name/load.bash"
            return 0
        fi
        IFS=':'
    done
    IFS="$saved_ifs"

    if command -v brew >/dev/null 2>&1; then
        dir="$(brew --prefix)/lib/$name"
        if [[ -f "$dir/load.bash" ]]; then
            . "$dir/load.bash"
            return 0
        fi
    fi

    printf 'helpers/common.bash: cannot find bats library %s\n' "$name" >&2
    return 1
}

_load_bats_lib bats-support
_load_bats_lib bats-assert

# Create the per-test bin directory and point PATH at it. The developer's PATH
# is deliberately dropped: a real ffmpeg, whiptail or apt must never leak into
# a test. jq and curl have no shim -- the scripts need the real ones -- so they
# are linked in explicitly when they live outside /usr/bin or /bin.
make_bin() {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    _link_real_tool jq "$REAL_JQ"
    _link_real_tool curl "$REAL_CURL"
    PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin"
    export PATH
}

_link_real_tool() {
    local name="$1" real="$2"
    if [[ -n "$real" && ! -e "$BATS_TEST_TMPDIR/bin/$name" ]]; then
        ln -s "$real" "$BATS_TEST_TMPDIR/bin/$name"
    fi
}

# wait_for_file <path> [seconds] -- poll until the file exists and is non-empty.
wait_for_file() {
    local path="$1" seconds="${2:-5}" waited=0
    while [[ ! -s "$path" ]]; do
        if [[ $waited -ge $((seconds * 20)) ]]; then
            printf 'wait_for_file: %s did not appear within %ss\n' "$path" "$seconds" >&2
            return 1
        fi
        sleep 0.05
        waited=$((waited + 1))
    done
    return 0
}

# write_csv <path> <line>... -- write CRLF-terminated lines, the way Python's
# csv.DictWriter does, so fixtures match what the scripts actually produce.
write_csv() {
    local path="$1" line
    shift
    : > "$path"
    for line in "$@"; do
        printf '%s\r\n' "$line" >> "$path"
    done
}

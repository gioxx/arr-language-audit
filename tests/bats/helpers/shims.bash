#!/usr/bin/env bash
#
# Install PATH shims from tests/bats/fakes/bin into the per-test bin directory.
# Every shim is driven entirely by environment variables, so a test scripts the
# outside world without touching the script under test.

# install_shim <name>... -- e.g. install_shim ffmpeg ffprobe python3
install_shim() {
    local name
    if [[ ! -d "$BATS_TEST_TMPDIR/bin" ]]; then
        make_bin
    fi
    for name in "$@"; do
        if [[ ! -f "$BATS_TESTS_DIR/fakes/bin/$name" ]]; then
            printf 'install_shim: no such shim: %s\n' "$name" >&2
            return 1
        fi
        cp "$BATS_TESTS_DIR/fakes/bin/$name" "$BATS_TEST_TMPDIR/bin/$name"
        chmod +x "$BATS_TEST_TMPDIR/bin/$name"
    done
}

# install_recorder <target-path> -- install the generic recorder anywhere, so it
# can stand in for SCAN_SH / VERIFY_SH in the orchestrator tests. It appends its
# argv and the interesting environment to $RECORDER_LOG.
install_recorder() {
    local target="$1"
    mkdir -p "$(dirname "$target")"
    cp "$BATS_TESTS_DIR/fakes/bin/recorder" "$target"
    chmod +x "$target"
}

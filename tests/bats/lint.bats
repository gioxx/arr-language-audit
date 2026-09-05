#!/usr/bin/env bats
#
# Static gates that do not need a fake server: bash 3.2 portability of the
# product scripts (L3), the bash version bats itself runs under (L4) and the
# --help contract of the entry points (L6).

load helpers/common

@test "L3: no bash 4 builtins in the product scripts" {
    skip "fixed in Task 7"

    run bash -c "cd '$ROOT' && grep -nE 'mapfile|readarray|declare -A|\\\$\\{[A-Za-z_]+(,,|\\^\\^)|\\|&|&>>|local -n' arr-language-audit.sh scan/*.sh verify/*.sh lib/*.sh 2>/dev/null"
    assert_output ""
}

@test "L4: bats runs under bash 3 on macOS" {
    [[ "${RUNNER_OS:-}" != "macOS" ]] || [[ ${BASH_VERSINFO[0]} -eq 3 ]]
}

@test "L6: scan --help exits 0 and prints Usage" {
    run "$BASH_UNDER_TEST" "$ROOT/scan/find-missing-italian-audio.sh" --help
    assert_success
    assert_output --partial "Usage:"
}

@test "L6: verify launcher --help exits 0 and prints Usage" {
    run "$BASH_UNDER_TEST" "$ROOT/verify/verify-audio-language.sh" --help
    assert_success
    assert_output --partial "Usage:"
}

@test "L6: orchestrator -h exits 0 and prints Usage" {
    skip "fixed in Task 10: the -h sed script is GNU-only and prints nothing on BSD sed"

    run "$BASH_UNDER_TEST" "$ROOT/arr-language-audit.sh" -h
    assert_success
    assert_output --partial "Usage:"
}

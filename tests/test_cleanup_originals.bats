#!/usr/bin/env bats
# Acceptance tests for cleanup-originals.sh

TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="${CLEANUP_SCRIPT:-cleanup-originals.sh}"

load "$TESTS_DIR/test_helper/bats-support/load"
load "$TESTS_DIR/test_helper/bats-assert/load"

setup() {
    TEST_DIR=$(mktemp -d)
}

teardown() {
    if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}

# ============================================================================
# End-to-end: main() acceptance tests
# ============================================================================

@test "main: trashes original with .fmpg counterpart, skips original without, when user confirms" {
    cd "$TEST_DIR"
    touch movie.mkv
    touch movie.fmpg.8.00.Mbps.mp4  # counterpart for movie.mkv
    touch other.mkv                  # no counterpart

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        CLEANUP_CONFIRM=y main
    "
    assert_success
    assert_line --partial "trashed:movie.mkv"
    refute_line --partial "trashed:other.mkv"
    assert_line --partial "1 file(s) skipped (no counterpart)"
}

@test "main: trashes original with .orig counterpart when user confirms" {
    cd "$TEST_DIR"
    touch movie.mkv
    touch movie.orig.7.50.Mbps.mp4  # counterpart for movie.mkv

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        CLEANUP_CONFIRM=y main
    "
    assert_success
    assert_line --partial "trashed:movie.mkv"
}

@test "main: trashes original with .hbrk counterpart when user confirms" {
    cd "$TEST_DIR"
    touch movie.mkv
    touch movie.hbrk.9.00.Mbps.mp4  # counterpart for movie.mkv

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        CLEANUP_CONFIRM=y main
    "
    assert_success
    assert_line --partial "trashed:movie.mkv"
}

@test "main: trashes original with .remux counterpart when user confirms" {
    cd "$TEST_DIR"
    touch movie.mp4
    touch movie.remux.mp4  # counterpart for movie.mp4

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        CLEANUP_CONFIRM=y main
    "
    assert_success
    assert_line --partial "trashed:movie.mp4"
}

@test "main: trashes nothing when user declines confirmation" {
    cd "$TEST_DIR"
    touch movie.mkv
    touch movie.fmpg.8.00.Mbps.mp4

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        CLEANUP_CONFIRM=n main
    "
    assert_success
    refute_line --partial "trashed:"
    assert_line --partial "Cancelled"
}

@test "main: exits cleanly with no eligible files when no counterparts exist" {
    cd "$TEST_DIR"
    touch movie.mkv
    touch other.mkv

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        main
    "
    assert_success
    assert_line --partial "Nothing to trash"
}

@test "main: cancels gracefully when stdin is closed and no CLEANUP_CONFIRM set" {
    cd "$TEST_DIR"
    touch movie.mkv
    touch movie.fmpg.8.00.Mbps.mp4

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        main
    " </dev/null
    assert_success
    assert_line --partial "Cancelled"
    refute_line --partial "trashed:"
}

@test "main: reports originals without counterparts in warn list" {
    cd "$TEST_DIR"
    touch orphan.mkv   # no counterpart

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        cd '$TEST_DIR'
        main
    "
    assert_success
    assert_line --partial "will NOT be trashed"
    assert_line --partial "orphan.mkv"
}

@test "main: does not treat peer file without marker as counterpart" {
    cd "$TEST_DIR"
    touch movie.mkv
    touch movie.mp4  # same base, no marker — not a counterpart

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        main
    "
    assert_success
    assert_line --partial "Nothing to trash"
}

@test "main: handles filenames with brackets and special characters" {
    cd "$TEST_DIR"
    touch "[belize] vacation footage (07.10.15).mp4"
    touch "[belize] vacation footage (07.10.15).fmpg.8.03.Mbps.mp4"

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        CLEANUP_CONFIRM=y main
    "
    assert_success
    assert_line --partial "trashed:[belize] vacation footage (07.10.15).mp4"
}

# ============================================================================
# Depth traversal tests
# ============================================================================

@test "main: depth 1 scans only current directory" {
    cd "$TEST_DIR"
    mkdir -p level1
    touch movie.mkv
    touch movie.fmpg.8.00.Mbps.mp4
    touch level1/deep.mkv
    touch level1/deep.fmpg.8.00.Mbps.mp4

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        CLEANUP_CONFIRM=y main
    "
    assert_success
    assert_line --partial "trashed:movie.mkv"
    refute_line --partial "trashed:deep.mkv"
}

@test "main: depth 2 scans current directory and one subdirectory level" {
    cd "$TEST_DIR"
    mkdir -p level1/level2
    touch movie.mkv
    touch movie.fmpg.8.00.Mbps.mp4
    touch level1/deep.mkv
    touch level1/deep.fmpg.8.00.Mbps.mp4
    touch level1/level2/deeper.mkv
    touch level1/level2/deeper.fmpg.8.00.Mbps.mp4

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=2
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        CLEANUP_CONFIRM=y main
    "
    assert_success
    assert_line --partial "trashed:movie.mkv"
    assert_line --partial "trashed:deep.mkv"
    refute_line --partial "trashed:deeper.mkv"
}

@test "main: depth 0 scans all directories recursively" {
    cd "$TEST_DIR"
    mkdir -p level1/level2/level3
    touch movie.mkv
    touch movie.fmpg.8.00.Mbps.mp4
    touch level1/level2/level3/deep.mkv
    touch level1/level2/level3/deep.fmpg.8.00.Mbps.mp4

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=0
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        CLEANUP_CONFIRM=y main
    "
    assert_success
    assert_line --partial "trashed:movie.mkv"
    assert_line --partial "trashed:deep.mkv"
}

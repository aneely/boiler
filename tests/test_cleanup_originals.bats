#!/usr/bin/env bats
# Tests for cleanup-originals.sh has_processed_counterpart() and end-to-end behavior

TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

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
# has_processed_counterpart() unit tests
# ============================================================================

@test "has_processed_counterpart: returns true when .fmpg.*.mp4 counterpart exists" {
    cd "$TEST_DIR"
    touch movie.mkv
    touch movie.fmpg.8.00.Mbps.mp4

    run bash -c "
        export CLEANUP_TEST_MODE=1
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        cd '$TEST_DIR'
        has_processed_counterpart './movie.mkv' && echo 'found' || echo 'not_found'
    "
    assert_success
    assert_output "found"
}

@test "has_processed_counterpart: returns true when .orig.*.mp4 counterpart exists" {
    cd "$TEST_DIR"
    touch movie.mkv
    touch movie.orig.7.50.Mbps.mp4

    run bash -c "
        export CLEANUP_TEST_MODE=1
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        cd '$TEST_DIR'
        has_processed_counterpart './movie.mkv' && echo 'found' || echo 'not_found'
    "
    assert_success
    assert_output "found"
}

@test "has_processed_counterpart: returns true when .remux.* counterpart exists" {
    cd "$TEST_DIR"
    touch movie.mp4
    touch movie.remux.mp4

    run bash -c "
        export CLEANUP_TEST_MODE=1
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        cd '$TEST_DIR'
        has_processed_counterpart './movie.mp4' && echo 'found' || echo 'not_found'
    "
    assert_success
    assert_output "found"
}

@test "has_processed_counterpart: returns false when no counterpart exists" {
    cd "$TEST_DIR"
    touch movie.mkv

    run bash -c "
        export CLEANUP_TEST_MODE=1
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        cd '$TEST_DIR'
        has_processed_counterpart './movie.mkv' && echo 'found' || echo 'not_found'
    "
    assert_success
    assert_output "not_found"
}

@test "has_processed_counterpart: returns false when only a peer original exists (no marker)" {
    cd "$TEST_DIR"
    touch movie.mkv
    touch movie.mp4

    run bash -c "
        export CLEANUP_TEST_MODE=1
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        cd '$TEST_DIR'
        has_processed_counterpart './movie.mkv' && echo 'found' || echo 'not_found'
    "
    assert_success
    assert_output "not_found"
}

# ============================================================================
# End-to-end: main() with mocked move_to_trash
# ============================================================================

@test "main: trashes original with counterpart, skips original without, when user confirms" {
    cd "$TEST_DIR"
    touch movie.mkv
    touch movie.fmpg.8.00.Mbps.mp4  # counterpart for movie.mkv
    touch other.mkv                  # no counterpart

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        echo 'y' | main
    "
    assert_success
    assert_line --partial "trashed:movie.mkv"
    refute_line --partial "trashed:other.mkv"
    assert_line --partial "1 file(s) skipped (no counterpart)"
}

@test "main: trashes nothing when user declines confirmation" {
    cd "$TEST_DIR"
    touch movie.mkv
    touch movie.fmpg.8.00.Mbps.mp4

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        echo 'n' | main
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
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        main
    "
    assert_success
    assert_line --partial "Nothing to trash"
}

@test "main: reports originals without counterparts in warn list" {
    cd "$TEST_DIR"
    touch orphan.mkv   # no counterpart

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        cd '$TEST_DIR'
        main
    "
    assert_success
    assert_line --partial "will NOT be trashed"
    assert_line --partial "orphan.mkv"
}

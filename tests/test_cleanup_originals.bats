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

@test "has_processed_counterpart: returns true when filename contains brackets" {
    cd "$TEST_DIR"
    touch "[belize] vacation footage (07.10.15).mp4"
    touch "[belize] vacation footage (07.10.15).fmpg.8.03.Mbps.mp4"

    run bash -c "
        export CLEANUP_TEST_MODE=1
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        cd '$TEST_DIR'
        has_processed_counterpart './[belize] vacation footage (07.10.15).mp4' && echo 'found' || echo 'not_found'
    "
    assert_success
    assert_output "found"
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
        CLEANUP_CONFIRM=y main
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
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        main
    "
    assert_success
    assert_line --partial "Nothing to trash"
}

@test "main: cancels gracefully when stdin is closed and no CLEANUP_CONFIRM set" {
    # Verifies the script doesn't crash (set -e) when read gets EOF from a dead stdin.
    # This is the best available automated coverage for the interactive prompt path.
    cd "$TEST_DIR"
    touch movie.mkv
    touch movie.fmpg.8.00.Mbps.mp4

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
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
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        cd '$TEST_DIR'
        main
    "
    assert_success
    assert_line --partial "will NOT be trashed"
    assert_line --partial "orphan.mkv"
}

# ============================================================================
# has_transcoding_marker() unit tests
# ============================================================================

@test "has_transcoding_marker: returns true for .fmpg. marker" {
    run bash -c "
        export CLEANUP_TEST_MODE=1
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        has_transcoding_marker 'movie.fmpg.8.00.Mbps.mp4' && echo 'marked' || echo 'original'
    "
    assert_success
    assert_output "marked"
}

@test "has_transcoding_marker: returns true for .orig. marker" {
    run bash -c "
        export CLEANUP_TEST_MODE=1
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        has_transcoding_marker 'movie.orig.7.50.Mbps.mp4' && echo 'marked' || echo 'original'
    "
    assert_success
    assert_output "marked"
}

@test "has_transcoding_marker: returns true for .hbrk. marker" {
    run bash -c "
        export CLEANUP_TEST_MODE=1
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        has_transcoding_marker 'movie.hbrk.9.00.Mbps.mp4' && echo 'marked' || echo 'original'
    "
    assert_success
    assert_output "marked"
}

@test "has_transcoding_marker: returns false for plain video file" {
    run bash -c "
        export CLEANUP_TEST_MODE=1
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        has_transcoding_marker 'movie.mkv' && echo 'marked' || echo 'original'
    "
    assert_success
    assert_output "original"
}

# ============================================================================
# parse_arguments() tests
# ============================================================================

@test "parse_arguments: -L sets GLOBAL_MAX_DEPTH" {
    run bash -c "
        export CLEANUP_TEST_MODE=1
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        parse_arguments -L 3
        echo \"\$GLOBAL_MAX_DEPTH\"
    "
    assert_success
    assert_output "3"
}

@test "parse_arguments: --max-depth sets GLOBAL_MAX_DEPTH" {
    run bash -c "
        export CLEANUP_TEST_MODE=1
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        parse_arguments --max-depth 5
        echo \"\$GLOBAL_MAX_DEPTH\"
    "
    assert_success
    assert_output "5"
}

@test "parse_arguments: -L 0 sets GLOBAL_MAX_DEPTH to 0 (unlimited)" {
    run bash -c "
        export CLEANUP_TEST_MODE=1
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        parse_arguments -L 0
        echo \"\$GLOBAL_MAX_DEPTH\"
    "
    assert_success
    assert_output "0"
}

@test "parse_arguments: -h exits 0" {
    run bash -c "
        export CLEANUP_TEST_MODE=1
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        parse_arguments -h
    "
    assert_success
}

@test "parse_arguments: --help exits 0" {
    run bash -c "
        export CLEANUP_TEST_MODE=1
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        parse_arguments --help
    "
    assert_success
}

@test "parse_arguments: missing value after -L exits 1" {
    run bash -c "
        export CLEANUP_TEST_MODE=1
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        parse_arguments -L
    "
    assert_failure
}

@test "parse_arguments: invalid depth value exits 1" {
    run bash -c "
        export CLEANUP_TEST_MODE=1
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        parse_arguments -L abc
    "
    assert_failure
}

@test "parse_arguments: unknown flag exits 1" {
    run bash -c "
        export CLEANUP_TEST_MODE=1
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        parse_arguments --unknown
    "
    assert_failure
}

# ============================================================================
# validate_depth() tests
# ============================================================================

@test "validate_depth: accepts valid depth values" {
    run bash -c "
        export CLEANUP_TEST_MODE=1
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        validate_depth 0 && echo 'ok0'
        validate_depth 1 && echo 'ok1'
        validate_depth 5 && echo 'ok5'
        validate_depth 100 && echo 'ok100'
    "
    assert_success
    assert_line "ok0"
    assert_line "ok1"
    assert_line "ok5"
    assert_line "ok100"
}

@test "validate_depth: rejects invalid depth values" {
    run bash -c "
        export CLEANUP_TEST_MODE=1
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        validate_depth '' && echo 'empty_ok' || echo 'empty_rejected'
        validate_depth '-1' && echo 'neg_ok' || echo 'neg_rejected'
        validate_depth '2.5' && echo 'dec_ok' || echo 'dec_rejected'
        validate_depth 'abc' && echo 'str_ok' || echo 'str_rejected'
    "
    assert_line "empty_rejected"
    assert_line "neg_rejected"
    assert_line "dec_rejected"
    assert_line "str_rejected"
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
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
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
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
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
        source '$PROJECT_ROOT/cleanup-originals.sh' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        CLEANUP_CONFIRM=y main
    "
    assert_success
    assert_line --partial "trashed:movie.mkv"
    assert_line --partial "trashed:deep.mkv"
}

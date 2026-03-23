#!/usr/bin/env bats
# Tests for remux-only.sh file discovery, argument parsing, and output path logic

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
# find_remux_files() with configurable depth tests
# ============================================================================

@test "find_remux_files: depth 1 finds only current directory files" {
    cd "$TEST_DIR"
    mkdir -p level1/level2/level3
    touch video0.mkv
    touch level1/video1.avi
    touch level1/level2/video2.webm
    touch level1/level2/level3/video3.mkv

    run bash -c "
        export REMUX_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        cd '$TEST_DIR'
        find_remux_files
    "
    assert_success
    assert_output "./video0.mkv"
}

@test "find_remux_files: depth 2 finds current + one subdirectory level (default)" {
    cd "$TEST_DIR"
    mkdir -p level1/level2/level3
    touch video0.mkv
    touch level1/video1.avi
    touch level1/level2/video2.webm
    touch level1/level2/level3/video3.mkv

    run bash -c "
        export REMUX_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=2
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        cd '$TEST_DIR'
        find_remux_files
    "
    assert_success
    assert_line "./video0.mkv"
    assert_line "./level1/video1.avi"
    refute_line "./level1/level2/video2.webm"
}

@test "find_remux_files: depth 3 finds current + two subdirectory levels" {
    cd "$TEST_DIR"
    mkdir -p level1/level2/level3
    touch video0.mkv
    touch level1/video1.avi
    touch level1/level2/video2.webm
    touch level1/level2/level3/video3.mkv

    run bash -c "
        export REMUX_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=3
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        cd '$TEST_DIR'
        find_remux_files
    "
    assert_success
    assert_line "./video0.mkv"
    assert_line "./level1/video1.avi"
    assert_line "./level1/level2/video2.webm"
    refute_line "./level1/level2/level3/video3.mkv"
}

@test "find_remux_files: depth 0 (unlimited) finds all files recursively" {
    cd "$TEST_DIR"
    mkdir -p level1/level2/level3
    touch video0.mkv
    touch level1/video1.avi
    touch level1/level2/video2.webm
    touch level1/level2/level3/video3.mkv

    run bash -c "
        export REMUX_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=0
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        cd '$TEST_DIR'
        find_remux_files
    "
    assert_success
    assert_line "./video0.mkv"
    assert_line "./level1/video1.avi"
    assert_line "./level1/level2/video2.webm"
    assert_line "./level1/level2/level3/video3.mkv"
}

@test "find_remux_files: default depth (2) when GLOBAL_MAX_DEPTH not set" {
    cd "$TEST_DIR"
    mkdir -p level1/level2
    touch video0.mkv
    touch level1/video1.avi
    touch level1/level2/video2.webm

    run bash -c "
        export REMUX_TEST_MODE=1
        unset GLOBAL_MAX_DEPTH
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        cd '$TEST_DIR'
        find_remux_files
    "
    assert_success
    assert_line "./video0.mkv"
    assert_line "./level1/video1.avi"
    refute_line "./level1/level2/video2.webm"
}

# ============================================================================
# Argument parsing tests
# ============================================================================

@test "parse_arguments: -L sets GLOBAL_MAX_DEPTH" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        parse_arguments -L 3
        echo \"\$GLOBAL_MAX_DEPTH\"
    "
    assert_success
    assert_output "3"
}

@test "parse_arguments: --max-depth sets GLOBAL_MAX_DEPTH" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        parse_arguments --max-depth 5
        echo \"\$GLOBAL_MAX_DEPTH\"
    "
    assert_success
    assert_output "5"
}

@test "parse_arguments: --preserve-name sets GLOBAL_PRESERVE_NAME" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        parse_arguments --preserve-name
        echo \"\$GLOBAL_PRESERVE_NAME\"
    "
    assert_success
    assert_output "1"
}

# ============================================================================
# validate_depth tests (catch divergence from boiler.sh)
# ============================================================================

@test "validate_depth: accepts valid depth values" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
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
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
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
# Output path tests
# ============================================================================

@test "generate_output_filename: default naming preserves source directory" {
    run bash -c "
        export REMUX_TEST_MODE=1
        export GLOBAL_PRESERVE_NAME=0
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        generate_output_filename 'level1/subdir' 'video' '5.50'
    "
    assert_success
    assert_output "level1/subdir/video.orig.5.50.Mbps.mp4"
}

@test "generate_output_filename: preserve-name outputs {base}.mp4" {
    run bash -c "
        export REMUX_TEST_MODE=1
        export GLOBAL_PRESERVE_NAME=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        generate_output_filename '.' 'movie' '8.00'
    "
    assert_success
    assert_output "movie.mp4"
}

@test "generate_output_filename: preserve-name falls back to {base}.remux.mp4 when {base}.mp4 exists" {
    cd "$TEST_DIR"
    touch movie.mp4

    run bash -c "
        export REMUX_TEST_MODE=1
        export GLOBAL_PRESERVE_NAME=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        cd '$TEST_DIR'
        generate_output_filename '.' 'movie' '8.00'
    "
    assert_success
    assert_output "movie.remux.mp4"
}

# ============================================================================
# Integration tests: flags affect end-to-end behavior
# ============================================================================

@test "parse_arguments -L 3: GLOBAL_MAX_DEPTH is 3 after direct call (not subshell)" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        parse_arguments -L 3
        echo \"\$GLOBAL_MAX_DEPTH\"
    "
    assert_success
    assert_output "3"
}

@test "parse_arguments -p: GLOBAL_PRESERVE_NAME is 1 after direct call (not subshell)" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        parse_arguments -p
        echo \"\$GLOBAL_PRESERVE_NAME\"
    "
    assert_success
    assert_output "1"
}

# ============================================================================
# Extension coverage test
# ============================================================================

@test "find_remux_files: discovers all supported non-QuickLook extensions" {
    cd "$TEST_DIR"
    touch video.mkv video.wmv video.avi video.webm video.flv video.mpg video.mpeg video.ts

    run bash -c "
        export REMUX_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        cd '$TEST_DIR'
        find_remux_files
    "
    assert_success
    assert_line "./video.mkv"
    assert_line "./video.wmv"
    assert_line "./video.avi"
    assert_line "./video.webm"
    assert_line "./video.flv"
    assert_line "./video.mpg"
    assert_line "./video.mpeg"
    assert_line "./video.ts"
}

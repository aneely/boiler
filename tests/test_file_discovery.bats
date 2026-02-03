#!/usr/bin/env bats
# Tests for file discovery and skipping functions
# Ported from test_boiler.sh

load 'helpers/setup'

# These tests need to use the real boiler.sh functions (not mocks) for file discovery
# So we source boiler.sh fresh in each test that needs it

setup() {
    common_setup
    # Create a fresh temporary directory for each test
    TEST_DIR=$(mktemp -d)
}

teardown() {
    common_teardown
    # Clean up temp directory
    if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}

# Helper to run boiler.sh functions in isolation (uses real implementation, not mocks)
run_boiler_func() {
    local func_name="$1"
    shift
    bash -c "
        export BOILER_TEST_MODE=1
        source '$PROJECT_ROOT/boiler.sh' 2>/dev/null
        $func_name \"\$@\"
    " -- "$@"
}

# ============================================================================
# should_skip_file() tests
# ============================================================================

@test "should_skip_file: skips files with .hbrk. marker" {
    run should_skip_file "test.hbrk.10.25.Mbps.mp4"
    assert_success
}

@test "should_skip_file: skips files with .fmpg. marker" {
    run should_skip_file "test.fmpg.10.25.Mbps.mp4"
    assert_success
}

@test "should_skip_file: skips files with .orig. marker" {
    run should_skip_file "test.orig.2.90.Mbps.mp4"
    assert_success
}

@test "should_skip_file: processes normal files" {
    run should_skip_file "normal_video.mp4"
    assert_failure
}

@test "should_skip_file: skips original when encoded version exists" {
    cd "$TEST_DIR"
    touch video.mp4 video.fmpg.10.25.Mbps.mp4
    
    run run_boiler_func should_skip_file "video.mp4"
    assert_success
}

@test "should_skip_file: processes original when no encoded version exists" {
    cd "$TEST_DIR"
    touch video.mp4
    
    run run_boiler_func should_skip_file "video.mp4"
    assert_failure
}

# ============================================================================
# find_all_video_files() tests
# ============================================================================

@test "find_all_video_files: finds all non-skipped files" {
    cd "$TEST_DIR"
    touch video1.mp4 video2.mp4 video3.mp4
    touch skip.hbrk.mp4 skip.fmpg.mp4 skip.orig.mp4
    
    run run_boiler_func find_all_video_files
    assert_success
    assert_line "./video1.mp4"
    assert_line "./video2.mp4"
    assert_line "./video3.mp4"
    refute_line "./skip.hbrk.mp4"
    refute_line "./skip.fmpg.mp4"
    refute_line "./skip.orig.mp4"
}

@test "find_all_video_files: returns empty when no files" {
    cd "$TEST_DIR"
    
    run run_boiler_func find_all_video_files
    assert_success
    assert_output ""
}

@test "find_all_video_files: finds files in subdirectories (one level deep)" {
    cd "$TEST_DIR"
    mkdir -p subdir1 subdir2
    touch subdir1/video1.mp4 subdir1/video2.mp4
    touch subdir2/video3.mp4
    touch video4.mp4
    touch subdir1/skip.fmpg.mp4
    mkdir -p subdir1/nested
    touch subdir1/nested/video5.mp4  # Should NOT be found (too deep with default depth)
    
    run run_boiler_func find_all_video_files
    assert_success
    assert_line "./subdir1/video1.mp4"
    assert_line "./subdir1/video2.mp4"
    assert_line "./subdir2/video3.mp4"
    assert_line "./video4.mp4"
    refute_line "./subdir1/skip.fmpg.mp4"
    refute_line "./subdir1/nested/video5.mp4"
}

@test "find_all_video_files: skips both original and encoded when both exist" {
    cd "$TEST_DIR"
    touch video.mp4 video.fmpg.10.25.Mbps.mp4 another.mkv
    
    run run_boiler_func find_all_video_files
    assert_success
    assert_output "./another.mkv"
}

@test "find_all_video_files: returns files in sorted (alphabetical) order" {
    cd "$TEST_DIR"
    touch c.mp4 a.mp4 b.mp4
    
    run run_boiler_func find_all_video_files
    assert_success
    # Check order - first line should be a.mp4
    assert_line --index 0 "./a.mp4"
    assert_line --index 1 "./b.mp4"
    assert_line --index 2 "./c.mp4"
}

# ============================================================================
# find_all_video_files() with configurable depth tests
# ============================================================================

@test "find_all_video_files: depth 1 finds only current directory" {
    cd "$TEST_DIR"
    mkdir -p level1/level2/level3
    touch video0.mp4
    touch level1/video1.mp4
    touch level1/level2/video2.mp4
    touch level1/level2/level3/video3.mp4
    
    run bash -c "
        export BOILER_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/boiler.sh' 2>/dev/null
        cd '$TEST_DIR'
        find_all_video_files
    "
    assert_success
    assert_output "./video0.mp4"
}

@test "find_all_video_files: depth 2 finds current + one subdirectory level (default)" {
    cd "$TEST_DIR"
    mkdir -p level1/level2/level3
    touch video0.mp4
    touch level1/video1.mp4
    touch level1/level2/video2.mp4
    touch level1/level2/level3/video3.mp4
    
    run bash -c "
        export BOILER_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=2
        source '$PROJECT_ROOT/boiler.sh' 2>/dev/null
        cd '$TEST_DIR'
        find_all_video_files
    "
    assert_success
    assert_line "./level1/video1.mp4"
    assert_line "./video0.mp4"
    refute_line "./level1/level2/video2.mp4"
}

@test "find_all_video_files: depth 3 finds current + two subdirectory levels" {
    cd "$TEST_DIR"
    mkdir -p level1/level2/level3
    touch video0.mp4
    touch level1/video1.mp4
    touch level1/level2/video2.mp4
    touch level1/level2/level3/video3.mp4
    
    run bash -c "
        export BOILER_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=3
        source '$PROJECT_ROOT/boiler.sh' 2>/dev/null
        cd '$TEST_DIR'
        find_all_video_files
    "
    assert_success
    assert_line "./level1/video1.mp4"
    assert_line "./level1/level2/video2.mp4"
    assert_line "./video0.mp4"
    refute_line "./level1/level2/level3/video3.mp4"
}

@test "find_all_video_files: depth 0 (unlimited) finds all files recursively" {
    cd "$TEST_DIR"
    mkdir -p level1/level2/level3
    touch video0.mp4
    touch level1/video1.mp4
    touch level1/level2/video2.mp4
    touch level1/level2/level3/video3.mp4
    
    run bash -c "
        export BOILER_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=0
        source '$PROJECT_ROOT/boiler.sh' 2>/dev/null
        cd '$TEST_DIR'
        find_all_video_files
    "
    assert_success
    assert_line "./level1/video1.mp4"
    assert_line "./level1/level2/video2.mp4"
    assert_line "./level1/level2/level3/video3.mp4"
    assert_line "./video0.mp4"
}

@test "find_all_video_files: default depth (2) when GLOBAL_MAX_DEPTH not set" {
    cd "$TEST_DIR"
    mkdir -p level1/level2
    touch video0.mp4
    touch level1/video1.mp4
    touch level1/level2/video2.mp4
    
    run bash -c "
        export BOILER_TEST_MODE=1
        unset GLOBAL_MAX_DEPTH
        source '$PROJECT_ROOT/boiler.sh' 2>/dev/null
        cd '$TEST_DIR'
        find_all_video_files
    "
    assert_success
    assert_line "./level1/video1.mp4"
    assert_line "./video0.mp4"
    refute_line "./level1/level2/video2.mp4"
}

# ============================================================================
# find_skipped_video_files() tests
# ============================================================================

@test "find_skipped_video_files: finds files with .fmpg. marker" {
    cd "$TEST_DIR"
    touch "regular.mp4" "video.fmpg.10.25.Mbps.mp4"
    
    run bash -c "
        export BOILER_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/boiler.sh' 2>/dev/null
        cd '$TEST_DIR'
        find_skipped_video_files
    "
    assert_success
    assert_line "./video.fmpg.10.25.Mbps.mp4"
    refute_line "./regular.mp4"
}

@test "find_skipped_video_files: finds files with .orig. marker" {
    cd "$TEST_DIR"
    touch "regular.mp4" "video.orig.5.00.Mbps.mp4"
    
    run bash -c "
        export BOILER_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/boiler.sh' 2>/dev/null
        cd '$TEST_DIR'
        find_skipped_video_files
    "
    assert_success
    assert_line "./video.orig.5.00.Mbps.mp4"
    refute_line "./regular.mp4"
}

@test "find_skipped_video_files: finds files with .hbrk. marker" {
    cd "$TEST_DIR"
    touch "regular.mp4" "video.hbrk.something.mp4"
    
    run bash -c "
        export BOILER_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/boiler.sh' 2>/dev/null
        cd '$TEST_DIR'
        find_skipped_video_files
    "
    assert_success
    assert_line "./video.hbrk.something.mp4"
    refute_line "./regular.mp4"
}

@test "find_skipped_video_files: excludes regular files without markers" {
    cd "$TEST_DIR"
    touch "video.fmpg.10.00.Mbps.mp4" "regular.mp4" "another.mkv"
    
    run bash -c "
        export BOILER_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/boiler.sh' 2>/dev/null
        cd '$TEST_DIR'
        find_skipped_video_files
    "
    assert_success
    assert_line "./video.fmpg.10.00.Mbps.mp4"
    refute_line "./regular.mp4"
    refute_line "./another.mkv"
}

@test "find_skipped_video_files: returns sorted output" {
    cd "$TEST_DIR"
    touch "z_video.fmpg.10.00.Mbps.mp4" "a_video.orig.5.00.Mbps.mp4" "m_video.hbrk.foo.mp4"
    
    run bash -c "
        export BOILER_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/boiler.sh' 2>/dev/null
        cd '$TEST_DIR'
        find_skipped_video_files
    "
    assert_success
    # Check that first file is a_video (sorted alphabetically)
    assert_line --index 0 "./a_video.orig.5.00.Mbps.mp4"
    assert_line --index 1 "./m_video.hbrk.foo.mp4"
    assert_line --index 2 "./z_video.fmpg.10.00.Mbps.mp4"
}

@test "find_skipped_video_files: returns empty when no skipped files" {
    cd "$TEST_DIR"
    touch "regular1.mp4" "regular2.mkv"
    
    run bash -c "
        export BOILER_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/boiler.sh' 2>/dev/null
        cd '$TEST_DIR'
        find_skipped_video_files
    "
    assert_success
    assert_output ""
}

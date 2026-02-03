#!/usr/bin/env bats
# Tests for extract_original_filename() and related matching functions
# Ported from test_boiler.sh

load 'helpers/setup'

setup() {
    common_setup
    TEST_DIR=$(mktemp -d)
}

teardown() {
    common_teardown
    if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}

# Helper to run boiler.sh functions in isolation
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
# extract_original_filename() tests
# ============================================================================

@test "extract_original_filename: extracts from .fmpg. pattern" {
    run run_boiler_func extract_original_filename "video.fmpg.10.25.Mbps.mp4"
    assert_success
    assert_output "video.mp4"
}

@test "extract_original_filename: extracts from .orig. pattern" {
    run run_boiler_func extract_original_filename "video.orig.2.90.Mbps.mp4"
    assert_success
    assert_output "video.mp4"
}

@test "extract_original_filename: extracts from .hbrk. pattern" {
    run run_boiler_func extract_original_filename "video.hbrk.10.25.Mbps.mp4"
    assert_success
    assert_output "video.mp4"
}

# ============================================================================
# has_original_file() tests
# ============================================================================

@test "has_original_file: detects original when it exists" {
    cd "$TEST_DIR"
    touch video.mp4 video.fmpg.10.25.Mbps.mp4
    
    run run_boiler_func has_original_file "video.fmpg.10.25.Mbps.mp4"
    assert_success
}

@test "has_original_file: detects missing original" {
    cd "$TEST_DIR"
    touch video.fmpg.10.25.Mbps.mp4
    # No video.mp4 exists
    
    run run_boiler_func has_original_file "video.fmpg.10.25.Mbps.mp4"
    assert_failure
}

# ============================================================================
# has_encoded_version() tests
# ============================================================================

@test "has_encoded_version: detects encoded version when it exists" {
    cd "$TEST_DIR"
    touch video.mp4 video.fmpg.10.25.Mbps.mp4
    
    run run_boiler_func has_encoded_version "video.mp4"
    assert_success
}

@test "has_encoded_version: detects when no encoded version exists" {
    cd "$TEST_DIR"
    touch video.mp4
    # No encoded version exists
    
    run run_boiler_func has_encoded_version "video.mp4"
    assert_failure
}

@test "has_encoded_version: detects .orig. encoded version" {
    cd "$TEST_DIR"
    touch video.mp4 video.orig.5.00.Mbps.mp4
    
    run run_boiler_func has_encoded_version "video.mp4"
    assert_success
}

@test "has_encoded_version: detects .hbrk. encoded version" {
    cd "$TEST_DIR"
    touch video.mp4 video.hbrk.8.00.Mbps.mp4
    
    run run_boiler_func has_encoded_version "video.mp4"
    assert_success
}

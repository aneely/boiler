#!/usr/bin/env bats
# Tests for parse_arguments() function
# Ported from test_boiler.sh

load 'helpers/setup'

setup() {
    common_setup
    # Reset global variables to known state
    GLOBAL_TARGET_BITRATE_MBPS=""
    GLOBAL_MAX_DEPTH=2
}

teardown() {
    common_teardown
    # Clean up global state
    GLOBAL_TARGET_BITRATE_MBPS=""
    GLOBAL_MAX_DEPTH=2
}

# ============================================================================
# parse_arguments() tests - Target Bitrate
# ============================================================================

@test "parse_arguments: --target-bitrate sets GLOBAL_TARGET_BITRATE_MBPS" {
    parse_arguments --target-bitrate 9.5
    assert_equal "$GLOBAL_TARGET_BITRATE_MBPS" "9.5"
}

@test "parse_arguments: -t sets GLOBAL_TARGET_BITRATE_MBPS" {
    parse_arguments -t 6.0
    assert_equal "$GLOBAL_TARGET_BITRATE_MBPS" "6.0"
}

@test "parse_arguments: handles decimal values for bitrate" {
    parse_arguments --target-bitrate 9.75
    assert_equal "$GLOBAL_TARGET_BITRATE_MBPS" "9.75"
}

# ============================================================================
# parse_arguments() tests - Max Depth
# ============================================================================

@test "parse_arguments: --max-depth sets GLOBAL_MAX_DEPTH" {
    parse_arguments --max-depth 3
    assert_equal "$GLOBAL_MAX_DEPTH" "3"
}

@test "parse_arguments: -L sets GLOBAL_MAX_DEPTH" {
    parse_arguments -L 1
    assert_equal "$GLOBAL_MAX_DEPTH" "1"
}

@test "parse_arguments: sets GLOBAL_MAX_DEPTH to 0 (unlimited)" {
    parse_arguments --max-depth 0
    assert_equal "$GLOBAL_MAX_DEPTH" "0"
}

# ============================================================================
# parse_arguments() tests - No Arguments
# ============================================================================

@test "parse_arguments: leaves GLOBAL_TARGET_BITRATE_MBPS empty with no args" {
    parse_arguments
    assert_equal "$GLOBAL_TARGET_BITRATE_MBPS" ""
}

@test "parse_arguments: leaves GLOBAL_MAX_DEPTH at default (2) with no args" {
    parse_arguments
    assert_equal "$GLOBAL_MAX_DEPTH" "2"
}

# ============================================================================
# parse_arguments() tests - Multiple Flags
# ============================================================================

@test "parse_arguments: last bitrate flag wins when multiple provided" {
    parse_arguments -t 5.0 --target-bitrate 9.5
    assert_equal "$GLOBAL_TARGET_BITRATE_MBPS" "9.5"
}

@test "parse_arguments: last depth flag wins when multiple provided" {
    parse_arguments -L 1 --max-depth 3
    assert_equal "$GLOBAL_MAX_DEPTH" "3"
}

@test "parse_arguments: sets both bitrate and depth when both flags provided" {
    parse_arguments --target-bitrate 9.5 --max-depth 3
    assert_equal "$GLOBAL_TARGET_BITRATE_MBPS" "9.5"
    assert_equal "$GLOBAL_MAX_DEPTH" "3"
}

# ============================================================================
# parse_arguments() tests - Error Cases
# ============================================================================

@test "parse_arguments: exits 1 when value missing after --target-bitrate" {
    run parse_arguments --target-bitrate
    assert_failure
}

@test "parse_arguments: exits 1 when value missing after --max-depth" {
    run parse_arguments --max-depth
    assert_failure
}

@test "parse_arguments: exits 1 when bitrate value is invalid (>100)" {
    run parse_arguments --target-bitrate 101
    assert_failure
}

@test "parse_arguments: exits 1 when depth value is invalid (negative)" {
    run parse_arguments --max-depth -1
    assert_failure
}

@test "parse_arguments: exits 1 when depth value is invalid (decimal)" {
    run parse_arguments --max-depth 2.5
    assert_failure
}

@test "parse_arguments: exits 1 when unknown flag provided" {
    run parse_arguments --unknown-flag
    assert_failure
}

@test "parse_arguments: exits 0 when --help provided" {
    run parse_arguments --help
    assert_success
}

@test "parse_arguments: exits 0 when -h provided" {
    run parse_arguments -h
    assert_success
}

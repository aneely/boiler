#!/usr/bin/env bats
# Tests for is_within_tolerance() function
# Ported from test_boiler.sh

load 'helpers/setup'

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# ============================================================================
# is_within_tolerance() tests
# Function returns 0 (success) if within tolerance, 1 (failure) if outside
# ============================================================================

@test "is_within_tolerance: returns success at lower bound" {
    run is_within_tolerance "7600000" "7600000" "8400000"
    assert_success
}

@test "is_within_tolerance: returns success at upper bound" {
    run is_within_tolerance "8400000" "7600000" "8400000"
    assert_success
}

@test "is_within_tolerance: returns success in middle of range" {
    run is_within_tolerance "8000000" "7600000" "8400000"
    assert_success
}

@test "is_within_tolerance: returns failure below lower bound" {
    run is_within_tolerance "7500000" "7600000" "8400000"
    assert_failure
}

@test "is_within_tolerance: returns failure above upper bound" {
    run is_within_tolerance "8500000" "7600000" "8400000"
    assert_failure
}

@test "is_within_tolerance: handles sanitized inputs with newlines/carriage returns" {
    local val lower upper
    val=$(printf "8000000\n")
    lower=$(printf "7600000\r")
    upper="8400000  "
    
    run is_within_tolerance "$val" "$lower" "$upper"
    assert_success
}
